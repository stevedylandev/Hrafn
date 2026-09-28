import Foundation
import UIKit
import Observation
import HrafnServices
import HrafnStore
import XMPPCore
import XMPPIM
import XMPPXML

enum AppConfig {
    /// Shared with the notification service extension (docs/SETUP.md): the
    /// database and the per-account locks live in its container.
    static let appGroup = SharedContainer.hrafnAppGroup

    /// The XEP-0357 app server (fpush, docker/fpush). Debug builds register
    /// with the Docker one and fpush's sandbox module; release builds with the
    /// production deployment.
    static var push: PushSettings {
        #if DEBUG
        PushSettings(service: try! JID("push.alpha.test"), publishOptions: ["pushModule": "sandbox"])
        #else
        PushSettings(service: try! JID("push.hrafn.stevedylandev.dev"), publishOptions: ["pushModule": "production"])
        #endif
    }

    /// How long the app stays connected after leaving the screen before it
    /// logs out and leaves new messages to push.
    static let backgroundGrace: Duration = .seconds(20)
}

/// A conversation to open, optionally at one of its messages.
struct ChatRoute: Hashable {
    let accountID: String
    let peer: String
    var focus: Int64? = nil
}

/// A room address from an `xmpp:` link.
struct RoomLink: Hashable, Identifiable {
    let room: String
    var id: String { room }
}

enum AppTab: Hashable {
    case chats, contacts, settings
}

/// The app's one shared object: the account manager, and where the user is.
@MainActor
@Observable
final class AppModel {
    let manager: AccountManager
    /// Every session's XML, credentials redacted. Debug builds only.
    let console: XMLConsoleLog?
    /// Set when the database could not be opened from disk and an in-memory
    /// one stands in.
    let storageError: String?

    var tab: AppTab = .chats
    var chatPath: [ChatRoute] = []
    /// An `xmpp:` link waiting to become an "add contact" sheet.
    var pendingContact: XMPPURI?
    /// An `xmpp:…?join` link waiting to become a "join group chat" sheet.
    var pendingJoin: RoomLink?
    private var started = false

    init() {
        let container = SharedContainer(appGroup: AppConfig.appGroup)
        let database: HrafnDatabase
        var storageError: String?
        #if DEBUG
        // UI tests start from a fresh install's state.
        if ProcessInfo.processInfo.arguments.contains("--reset-data") {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: container.databaseURL.path + suffix))
            }
            try? FileManager.default.removeItem(at: container.omemoDirectory)
        }
        #endif
        do {
            database = try container.openDatabase()
        } catch {
            storageError = String(describing: error)
            database = try! HrafnDatabase()
        }
        // OMEMO is optional until it is wired in: a failure here must not
        // stop the app.
        let omemo = try? container.openOMEMODatabase()
        self.storageError = storageError
        #if DEBUG
        let console = XMLConsoleLog()
        self.console = console
        let sink: (any XMLConsole)? = RedactingXMLConsole(console)
        #else
        self.console = nil
        let sink: (any XMLConsole)? = nil
        #endif
        #if DEBUG
        // File transfers to the Docker test servers' `.test` hosts go to
        // this machine (docs/SETUP.md). Other hosts are unaffected.
        let loopback = true
        #else
        let loopback = false
        #endif
        manager = AccountManager(database: database, credentials: KeychainCredentialStore(), omemo: omemo,
                                 media: container.media,
                                 console: sink, lockDirectory: container.lockDirectory, notifier: SystemNotifier(),
                                 loopbackHTTP: loopback)
        mediaPolicy = Self.loadMediaPolicy()
        appearance = Self.defaults.data(forKey: "appearance")
            .flatMap { try? JSONDecoder().decode(Appearance.self, from: $0) } ?? Appearance()
    }

    // MARK: - Appearance

    var appearance: Appearance {
        didSet {
            if let data = try? JSONEncoder().encode(appearance) { Self.defaults.set(data, forKey: "appearance") }
        }
    }

    // MARK: - Media

    /// When others' files download by themselves; kept in the App Group's
    /// defaults.
    var mediaPolicy: MediaPolicy {
        didSet {
            let policy = mediaPolicy
            if let data = try? JSONEncoder().encode(policy) { Self.defaults.set(data, forKey: "mediaPolicy") }
            Task { await manager.setMediaPolicy(policy) }
        }
    }

    private static var defaults: UserDefaults { UserDefaults(suiteName: AppConfig.appGroup) ?? .standard }

    private static func loadMediaPolicy() -> MediaPolicy {
        defaults.data(forKey: "mediaPolicy").flatMap { try? JSONDecoder().decode(MediaPolicy.self, from: $0) }
            ?? MediaPolicy()
    }

    var media: MediaStore { manager.media }

    /// The image file for a profile's avatar, once it is on the device.
    func avatarURL(_ profile: Profile?) -> URL? {
        guard let hash = profile?.avatarHash, media.hasAvatar(hash: hash) else { return nil }
        return media.avatarURL(hash: hash)
    }

    var database: HrafnDatabase { manager.database }

    func start() async {
        guard !started else { return }
        started = true
        await manager.setPushSettings(AppConfig.push)
        await manager.setMediaPolicy(mediaPolicy)
        await manager.start()
    }

    // MARK: - Background

    @ObservationIgnored private var backgroundTask: Task<Void, Never>?

    /// Left the screen: XEP-0352 inactive now; after a grace period (or when
    /// iOS is about to suspend us, whichever is first) log out, so push takes
    /// over and no lock on the shared container is held while suspended.
    func enterBackground() {
        backgroundTask?.cancel()
        let manager = self.manager
        let assertion = BackgroundAssertion()
        backgroundTask = Task {
            await manager.setActive(false)
            assertion.begin {
                // Out of time: suspend at once.
                Task { @MainActor in
                    await manager.suspend()
                    HrafnDatabase.suspend()
                    assertion.end()
                }
            }
            try? await Task.sleep(for: AppConfig.backgroundGrace)
            guard !Task.isCancelled else { assertion.end(); return }
            await manager.suspend()
            HrafnDatabase.suspend()
            assertion.end()
        }
    }

    /// A notification action (reply, mark read) while the app is not on
    /// screen: log in long enough to carry it out, then back to sleep.
    func handleInBackground(_ work: @escaping @MainActor (AccountManager) async -> Void) async {
        let assertion = BackgroundAssertion()
        assertion.begin { assertion.end() }
        defer { assertion.end() }
        let wasSuspended = manager.isSuspended
        if wasSuspended {
            HrafnDatabase.resume()
            await manager.resume()
            // Give the sessions a moment to connect, so markers go out too;
            // a reply is safe in the outbox either way.
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline,
                  manager.accounts.contains(where: { $0.enabled && manager.status(for: $0.id).connection != .online }) {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        await work(manager)
        if wasSuspended, UIApplication.shared.applicationState != .active { enterBackground() }
    }

    func enterForeground() {
        backgroundTask?.cancel()
        backgroundTask = nil
        HrafnDatabase.resume()
        let manager = self.manager
        Task {
            await manager.resume()
            await manager.setActive(true)
        }
    }

    func openChat(accountID: String, peer: String) {
        try? database.openConversation(accountID: accountID, peer: peer)
        tab = .chats
        chatPath = [ChatRoute(accountID: accountID, peer: peer)]
    }

    /// `xmpp:` links from other apps and QR codes.
    func handle(_ url: URL) {
        guard let uri = XMPPURI(url.absoluteString), let account = manager.accounts.first else { return }
        switch uri.action {
        case .roster, .subscribe:
            pendingContact = uri
            tab = .contacts
        case .message(let body):
            openChat(accountID: account.id, peer: uri.jid.bare.description)
            if let body { try? database.setDraft(accountID: account.id, peer: uri.jid.bare.description, body) }
        case .join:
            let room = uri.jid.bare.description
            if (try? database.fetchRoom(accountID: account.id, jid: room))??.bookmarked == true {
                openChat(accountID: account.id, peer: room)
            } else {
                tab = .chats
                pendingJoin = RoomLink(room: room)
            }
        case nil:
            openChat(accountID: account.id, peer: uri.jid.bare.description)
        }
    }

    /// A conversation with the account's own address: notes to self, and
    /// what other devices of this account sent there.
    func isSelf(accountID: String, peer: String) -> Bool {
        guard let jid = manager.accounts.first(where: { $0.id == accountID })?.jid else { return false }
        return jid.caseInsensitiveCompare(peer) == .orderedSame
    }

    func accountLabel(_ accountID: String) -> String? {
        guard manager.accounts.count > 1 else { return nil }
        return manager.accounts.first { $0.id == accountID }?.jid
    }
}
