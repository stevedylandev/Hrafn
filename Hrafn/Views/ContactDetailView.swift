import SwiftUI
import HrafnServices
import HrafnStore
import XMPPCore
import XMPPIM

struct ContactDetailView: View {
    let accountID: String
    let jid: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var contact: Contact?
    @State private var profile: Profile?
    @State private var blocked: [String] = []
    @State private var name = ""
    @State private var confirmingRemove = false
    @State private var showingQR = false
    @State private var errorMessage: String?

    private var session: AccountSession? { app.manager.session(for: accountID) }
    private var isBlocked: Bool { blocked.contains(jid) }
    private var shareURI: XMPPURI? {
        (try? JID(jid)).map { XMPPURI(jid: $0, action: .roster(name: contact?.name)) }
    }

    var body: some View {
        let status = app.manager.status(for: accountID)
        Form {
            Section {
                VStack(spacing: 8) {
                    let title = contact?.name ?? profile?.nickname ?? jid
                    Avatar(name: title, size: 80, availability: status.availability(of: jid),
                           image: app.avatarURL(profile), colorKey: jid)
                    Text(title).font(.title2.bold())
                    if let nick = profile?.nickname, contact?.name != nil, nick != contact?.name {
                        Text("Calls themselves “\(nick)”").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(status.availability(of: jid).label).foregroundStyle(.secondary)
                    if let message = status.statusMessages[jid] {
                        Text(message).font(.callout).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                Button { app.openChat(accountID: accountID, peer: jid) } label: {
                    Label("Message", systemImage: "bubble.left")
                }
                if shareURI != nil {
                    Button { showingQR = true } label: { Label("Share Contact", systemImage: "qrcode") }
                }
            }

            Section("Details") {
                LabeledContent("Address") {
                    Text(jid).textSelection(.enabled)
                }
                if let contact, contact.inRoster {
                    TextField("Name", text: $name)
                        .onSubmit { Task { await rename() } }
                    LabeledContent("Status sharing", value: contact.subscription.summary)
                    if contact.pendingOut {
                        LabeledContent("Request") { Text("Waiting for them to accept") }
                    }
                    if !contact.groups.isEmpty {
                        LabeledContent("Groups", value: contact.groups.joined(separator: ", "))
                    }
                }
            }

            EncryptionDevicesSection(accountID: accountID, jid: jid, title: "Encryption")

            Section {
                if contact?.inRoster == true {
                    Button("Remove Contact", role: .destructive) { confirmingRemove = true }
                } else {
                    Button("Add to Contacts") {
                        Task { await run { try await $0.addContact(jid, name: nil) } }
                    }
                }
                Button(isBlocked ? "Unblock" : "Block", role: isBlocked ? nil : .destructive) {
                    let block = !isBlocked
                    Task { await run { try await $0.setBlocked(jid, block) } }
                }
            } footer: {
                Text(isBlocked ? "You won't receive messages or status from this contact."
                               : "Blocking stops their messages and hides your status from them.")
            }
        }
        .themed()
        .navigationTitle(contact?.displayName ?? jid)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove \(contact?.displayName ?? jid)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove Contact", role: .destructive) {
                Task { await run { try await $0.removeContact(jid) } }
            }
        } message: {
            Text("You will stop sharing status with each other. Your conversation stays.")
        }
        .sheet(isPresented: $showingQR) {
            if let shareURI { QRCodeSheet(title: contact?.displayName ?? jid, uri: shareURI) }
        }
        .alert("Couldn't Complete", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .observing({ app.database.contact(accountID: accountID, jid: jid) }, id: jid, into: $contact)
        .observing({ app.database.blocked(accountID: accountID) }, id: accountID, into: $blocked)
        .observing({ app.database.profileStream(accountID: accountID, jid: jid) }, id: jid, into: $profile)
        .onChange(of: contact?.name) { _, new in name = new ?? "" }
    }

    private func rename() async {
        await run { try await $0.renameContact(jid, to: name.trimmingCharacters(in: .whitespaces)) }
    }

    private func run(_ action: (AccountSession) async throws -> Void) async {
        guard let session else {
            errorMessage = String(localized: "The account is not connected.")
            return
        }
        do { try await action(session) } catch { errorMessage = String(describing: error) }
    }
}
