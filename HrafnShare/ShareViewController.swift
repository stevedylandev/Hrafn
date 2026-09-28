import SwiftUI
import UIKit
import UniformTypeIdentifiers
import HrafnServices
import HrafnStore
import XMPPCore

/// "Share to Hrafn" from other apps: pick a conversation, and what was shared
/// is stored as outgoing messages in the shared database, then sent by a
/// quiet one-shot login (`ShareDelivery`). Whatever cannot go now waits in
/// the outbox for the app.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let model = ShareModel(providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

@MainActor
@Observable
final class ShareModel {
    struct Target: Identifiable, Hashable {
        var accountID: String
        var peer: String
        var title: String
        var isRoom: Bool
        var roomNick: String?
        var id: String { accountID + "|" + peer }
    }

    private(set) var targets: [Target] = []
    private(set) var problem: String?
    private(set) var isSending = false
    var selected: Target?
    var comment = ""

    let itemCount: Int
    private let providers: [NSItemProvider]
    private let done: () -> Void
    private let cancelled: () -> Void
    private let container = SharedContainer(appGroup: SharedContainer.hrafnAppGroup)
    private var database: HrafnDatabase?

    init(providers: [NSItemProvider], done: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.providers = providers
        self.itemCount = providers.count
        self.done = done
        self.cancelled = cancel
        load()
    }

    private func load() {
        guard container.isShared, let database = try? HrafnDatabase(url: container.databaseURL) else {
            problem = String(localized: "Open Hrafn once and sign in before sharing to it.")
            return
        }
        self.database = database
        let accounts = ((try? database.allAccounts()) ?? []).filter(\.enabled)
        let summaries = (try? database.fetchConversationSummaries()) ?? []
        targets = summaries.compactMap { summary in
            guard accounts.contains(where: { $0.id == summary.conversation.accountID }) else { return nil }
            let account = accounts.first { $0.id == summary.conversation.accountID }
            let nick = summary.room.map { $0.nick ?? account?.jid.split(separator: "@").first.map(String.init) ?? "me" }
            return Target(accountID: summary.conversation.accountID, peer: summary.conversation.peer,
                          title: summary.title, isRoom: summary.isRoom, roomNick: nick)
        }
        if targets.isEmpty { problem = String(localized: "Start a chat in Hrafn first.") }
    }

    func cancel() { cancelled() }

    func send() async {
        guard let target = selected, let database, !isSending else { return }
        isSending = true
        let media = container.media
        var ids: [Int64] = []
        for provider in providers {
            do {
                if let row = try await store(provider, to: target, database: database, media: media) { ids.append(row) }
            } catch {
                problem = String(describing: error)
            }
        }
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, let row = try? insertText(text, to: target, database: database) { ids.append(row) }

        if !target.isRoom, !ids.isEmpty {
            #if DEBUG
            let loopback = true
            #else
            let loopback = false
            #endif
            let delivery = ShareDelivery(database: database, credentials: KeychainCredentialStore(), media: media,
                                         lockDirectory: container.lockDirectory, loopbackHTTP: loopback,
                                         omemo: try? container.openOMEMODatabase())
            await delivery.deliver(messageIDs: ids, accountID: target.accountID, timeout: .seconds(20))
        }
        done()
    }

    /// One shared item as an outgoing message; returns its id.
    private func store(_ provider: NSItemProvider, to target: Target, database: HrafnDatabase,
                       media: MediaStore) async throws -> Int64? {
        let file: OutgoingFile
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            let url = try await Self.copy(provider, type: .movie)
            defer { try? FileManager.default.removeItem(at: url) }
            file = try await MediaPreparation.video(url, media: media, fileName: provider.suggestedName)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let data = try await Self.data(provider, type: .image)
            file = try MediaPreparation.image(data, media: media, fileName: provider.suggestedName)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                    || (provider.hasItemConformingToTypeIdentifier(UTType.data.identifier)
                        && !provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                        && !provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)) {
            let url = try await Self.copy(provider, type: .data)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            file = try MediaPreparation.file(url, media: media)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                  let url = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
            return try insertText(url.absoluteString, to: target, database: database)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                  let text = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
            return try insertText(text, to: target, database: database)
        } else {
            return nil
        }
        let url = media.url(for: file.localPath)
        let attachment = Attachment(fileName: file.fileName, mimeType: file.mimeType, size: MediaStore.fileSize(of: url),
                                    localPath: file.localPath, width: file.width, height: file.height,
                                    duration: file.duration, autoDownloadConsidered: true)
        return try database.insertOutgoing(accountID: target.accountID, peer: target.peer, attachment: attachment,
                                           id: StanzaID.make(), nick: target.isRoom ? target.roomNick : nil).id
    }

    private func insertText(_ text: String, to target: Target, database: HrafnDatabase) throws -> Int64? {
        if target.isRoom {
            return try database.insertOutgoing(accountID: target.accountID, room: target.peer, nick: target.roomNick,
                                               body: text, id: StanzaID.make()).id
        }
        return try database.insertOutgoing(accountID: target.accountID, peer: target.peer, body: text,
                                           id: StanzaID.make()).id
    }

    private static func data(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, error in
                if let data { continuation.resume(returning: data) } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    /// The provider's file, copied somewhere that outlives the callback.
    private static func copy(_ provider: NSItemProvider, type: UTType) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                let copy = directory.appending(path: url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                if let problem = model.problem {
                    Section { Text(problem).foregroundStyle(.secondary) }
                }
                if !model.targets.isEmpty {
                    Section {
                        TextField("Add a message", text: $model.comment, axis: .vertical)
                            .lineLimit(1...4)
                    } footer: {
                        Text("\(model.itemCount) items")
                    }
                    Section("Send to") {
                        ForEach(model.targets) { target in
                            Button {
                                model.selected = target
                            } label: {
                                HStack {
                                    Image(systemName: target.isRoom ? "person.3.fill" : "person.crop.circle.fill")
                                        .foregroundStyle(.secondary)
                                    Text(target.title).foregroundStyle(.primary)
                                    Spacer()
                                    if model.selected == target { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Hrafn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSending {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await model.send() } }
                            .disabled(model.selected == nil)
                    }
                }
            }
            .disabled(model.isSending)
        }
    }
}
