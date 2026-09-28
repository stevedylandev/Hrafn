import Foundation
import Observation
import HrafnStore
import XMPPClient
import XMPPCore
import XMPPXML

/// Where new messages are announced while the app is not on screen, and the
/// badge set. The app implements it with `UNUserNotificationCenter`.
public protocol Notifier: Sendable {
    func announce(_ notifications: [PendingNotification]) async
    /// Removes a conversation's delivered banners once it has been read.
    func withdraw(threadID: String) async
    /// Removes delivered banners for messages not in `unread`: read on
    /// another device, or retracted.
    func withdraw(keeping unread: Set<Int64>) async
    func setBadge(_ count: Int) async
}

/// Every account on the device and its session. The app creates one.
@MainActor
@Observable
public final class AccountManager {

    public let database: HrafnDatabase
    /// Shared files and avatars.
    public let media: MediaStore
    public private(set) var accounts: [Account] = []
    /// Keyed by account id; present for every account, enabled or not.
    public private(set) var statuses: [String: AccountStatus] = [:]
    /// Sessions are stopped while the app is in the background (`suspend()`),
    /// so the notification service extension can log in instead.
    public private(set) var isSuspended = false

    @ObservationIgnored private var sessions: [String: AccountSession] = [:]
    @ObservationIgnored private var locks: [String: AccountLock] = [:]
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored let omemo: OMEMODatabase?
    @ObservationIgnored private let resilience: ResilienceOptions
    @ObservationIgnored private let console: (any XMLConsole)?
    @ObservationIgnored private let lockDirectory: URL?
    @ObservationIgnored private let notifier: (any Notifier)?
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var pushSettings: PushSettings?
    @ObservationIgnored private var pushToken: Data?
    @ObservationIgnored private var visible: (accountID: String, peer: String)?
    @ObservationIgnored private var watchTasks: [Task<Void, Never>] = []
    @ObservationIgnored private let loopbackHTTP: Bool
    @ObservationIgnored private var mediaPolicy = MediaPolicy()

    /// `console` sees every session's XML (debug builds; wrap it in
    /// `RedactingXMLConsole`). `lockDirectory` holds the per-account locks
    /// shared with the notification service extension (`nil`: no locking).
    ///
    /// `loopbackHTTP`: file transfers to `.test` hosts go to 127.0.0.1, for
    /// the Docker test servers (debug builds only).
    public init(database: HrafnDatabase, credentials: any CredentialStore, omemo: OMEMODatabase? = nil,
                media: MediaStore = .temporary(), resilience: ResilienceOptions = ResilienceOptions(),
                console: (any XMLConsole)? = nil, lockDirectory: URL? = nil, notifier: (any Notifier)? = nil,
                loopbackHTTP: Bool = false) {
        self.database = database
        self.omemo = omemo
        self.media = media
        self.loopbackHTTP = loopbackHTTP
        self.credentials = credentials
        self.resilience = resilience
        self.console = console
        self.lockDirectory = lockDirectory
        self.notifier = notifier
        startWatching()
    }

    /// Loads the accounts and starts a session for each enabled one.
    public func start() async {
        accounts = (try? database.allAccounts()) ?? []
        for account in accounts {
            statuses[account.id] = statuses[account.id] ?? AccountStatus()
        }
        guard !isSuspended else { return }
        for account in accounts where account.enabled { await startSession(account) }
    }

    public func session(for accountID: String) -> AccountSession? {
        sessions[accountID]
    }

    public func status(for accountID: String) -> AccountStatus {
        if let status = statuses[accountID] { return status }
        let status = AccountStatus()
        statuses[accountID] = status
        return status
    }

    /// Logs in once to prove the settings, then saves the account and starts
    /// its session. `trustedFingerprint` is set after the user accepts an
    /// `untrustedCertificate` error.
    @discardableResult
    public func addAccount(jid address: String, password: String, host: String? = nil, port: Int? = nil,
                           directTLS: Bool = true, trustedFingerprint: String? = nil) async throws -> Account {
        guard let jid = try? JID(address.trimmingCharacters(in: .whitespaces)), jid.localpart != nil else {
            throw AccountError.invalidJID(address)
        }
        let bare = jid.bare.description
        guard !accounts.contains(where: { $0.jid == bare }) else { throw AccountError.invalidJID("\(bare) (already added)") }
        let host = host?.trimmingCharacters(in: .whitespaces)
        let account = Account(jid: bare, host: host?.isEmpty == false ? host : nil, port: port,
                              directTLS: directTLS, trustedFingerprint: trustedFingerprint)
        try await AccountSession.verify(account: account, password: password)

        try credentials.setPassword(password, for: account.id)
        try database.save(account)
        accounts.append(account)
        statuses[account.id] = AccountStatus()
        await startSession(account)
        return account
    }

    /// Unregisters push, logs out and deletes the account with all its local data.
    public func removeAccount(_ accountID: String) async {
        if let session = sessions[accountID] { await session.disablePush() }
        await stopSession(accountID)
        try? credentials.removePassword(for: accountID)
        try? omemo?.deleteAccount(accountID: accountID)
        let paths = (try? database.localAttachmentPaths(accountID: accountID)) ?? []
        try? database.deleteAccount(id: accountID)
        for path in paths { media.removeFile(path) }
        media.pruneAvatars(keeping: (try? database.avatarHashesInUse()) ?? [])
        accounts.removeAll { $0.id == accountID }
        statuses[accountID] = nil
    }

    public func setEnabled(_ accountID: String, _ enabled: Bool) async {
        guard var account = accounts.first(where: { $0.id == accountID }), account.enabled != enabled else { return }
        account.enabled = enabled
        try? database.save(account)
        replace(account)
        if enabled {
            await startSession(account)
        } else {
            // A disabled account should not wake the phone either.
            if let session = sessions[accountID] { await session.disablePush() }
            await stopSession(accountID)
        }
    }

    /// Trusts a certificate the system rejected and reconnects.
    public func trustCertificate(_ fingerprint: String, for accountID: String) async {
        guard var account = accounts.first(where: { $0.id == accountID }) else { return }
        account.trustedFingerprint = fingerprint
        try? database.save(account)
        replace(account)
        await restart(accountID)
    }

    /// Changes connection settings or the password, then reconnects.
    public func update(_ account: Account, password: String?) async throws {
        if let password, !password.isEmpty { try credentials.setPassword(password, for: account.id) }
        try database.save(account)
        replace(account)
        await restart(account.id)
    }

    public func restart(_ accountID: String) async {
        await stopSession(accountID)
        if let account = accounts.first(where: { $0.id == accountID }), account.enabled {
            await startSession(account)
        }
    }

    /// Tie to the scene phase: XEP-0352 inactive in the background, and a
    /// connection check on return.
    public func setActive(_ active: Bool) async {
        guard active != isActive else { return }
        isActive = active
        if active { await announcePending() }
        for session in sessions.values { await session.setActive(active) }
    }

    public func stopAll() async {
        for id in Array(sessions.keys) { await stopSession(id) }
    }

    // MARK: - Background

    /// Before the app is suspended: log out of every account (cleanly, so the
    /// server stores and pushes what arrives next) and release the locks, so
    /// the notification service extension can take over.
    public func suspend() async {
        guard !isSuspended else { return }
        isSuspended = true
        await stopAll()
    }

    /// Back in the foreground: log in again.
    public func resume() async {
        guard isSuspended else { return }
        isSuspended = false
        await announcePending()
        for account in accounts where account.enabled { await startSession(account) }
    }

    // MARK: - Push

    /// The app server to register with. `nil` turns push off for new sessions.
    public func setPushSettings(_ settings: PushSettings?) async {
        pushSettings = settings
        await updatePush()
    }

    /// The APNs device token, from `didRegisterForRemoteNotificationsWithDeviceToken`.
    /// A new token is registered with every connected account at once.
    public func setPushToken(_ token: Data?) async {
        guard token != pushToken else { return }
        pushToken = token
        await updatePush()
    }

    private var pushRegistration: PushRegistration? {
        guard let pushSettings, let pushToken else { return nil }
        return PushRegistration(settings: pushSettings, token: pushToken)
    }

    private func updatePush() async {
        let registration = pushRegistration
        for session in sessions.values { await session.setPush(registration) }
    }

    // MARK: - Media

    /// When others' files are downloaded without asking, for every account.
    public func setMediaPolicy(_ policy: MediaPolicy) async {
        mediaPolicy = policy
        for session in sessions.values { await session.setMediaPolicy(policy) }
    }

    /// Deletes a conversation's local history and the files in it.
    public func deleteConversation(accountID: String, peer: String) throws {
        let paths = try database.localAttachmentPaths(accountID: accountID, peer: peer)
        try database.deleteConversation(accountID: accountID, peer: peer)
        for path in paths { media.removeFile(path) }
    }

    // MARK: - Conversations

    /// The conversation on screen. Survives sessions being restarted
    /// (backgrounding, reconnects).
    public func setVisibleConversation(accountID: String, peer: String) async {
        visible = (accountID, peer)
        await notifier?.withdraw(threadID: PendingNotification.threadID(accountID: accountID, peer: peer))
        await sessions[accountID]?.setVisibleConversation(peer)
    }

    /// The conversation left the screen. Ignored if another has taken its
    /// place already (views appear before the old one disappears).
    public func clearVisibleConversation(accountID: String, peer: String) async {
        guard let visible, visible.accountID == accountID, visible.peer == peer else { return }
        self.visible = nil
        await sessions[accountID]?.setVisibleConversation(nil)
    }

    /// A reply typed into a notification. Stored first, so the outbox sends
    /// it later if there is no connection now.
    public func reply(accountID: String, peer: String, text: String) async throws {
        if let session = sessions[accountID] {
            try await session.send(text, to: peer)
            await session.markRead(peer: peer)
        } else {
            _ = try database.insertOutgoing(accountID: accountID, peer: peer, body: text, id: StanzaID.make())
            _ = try database.markConversationRead(accountID: accountID, peer: peer)
        }
        await notifier?.withdraw(threadID: PendingNotification.threadID(accountID: accountID, peer: peer))
    }

    /// "Mark as Read" on a notification. The displayed marker goes out only
    /// when a session is live.
    public func markRead(accountID: String, peer: String) async {
        if let session = sessions[accountID] {
            await session.markRead(peer: peer)
        } else {
            _ = try? database.markConversationRead(accountID: accountID, peer: peer)
        }
        await notifier?.withdraw(threadID: PendingNotification.threadID(accountID: accountID, peer: peer))
    }

    /// End-to-end encryption for a conversation: `.omemo`, `.off`, or `nil`
    /// to decide by whether the contact has OMEMO devices.
    public func setEncryption(accountID: String, peer: String, _ encryption: ConversationEncryption?) throws {
        try database.setConversationEncryption(accountID: accountID, peer: peer, encryption)
    }

    public func setMuted(accountID: String, peer: String, _ muted: Bool) throws {
        try database.setMuted(accountID: accountID, peer: peer, muted)
    }

    /// Which of a room's messages are announced; `nil` restores the default
    /// for its kind.
    public func setRoomNotify(accountID: String, room: String, _ level: RoomNotify?) throws {
        try database.updateRoom(accountID: accountID, jid: room) { $0.notify = level }
    }

    // MARK: - Private

    private func replace(_ account: Account) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = account }
    }

    private func startSession(_ account: Account) async {
        guard sessions[account.id] == nil, !isSuspended else { return }
        let status = self.status(for: account.id)
        do {
            guard let password = try credentials.password(for: account.id) else { throw AccountError.missingPassword }
            // OMEMO only with the lock (or without locks at all, in tests):
            // two processes must never move the same ratchets.
            var omemo = self.omemo
            if let lockDirectory {
                let lock = locks[account.id] ?? AccountLock(directory: lockDirectory, accountID: account.id)
                locks[account.id] = lock
                // The notification service extension finishes within its 30
                // seconds; past that, carry on rather than stay offline.
                if !(await lock.acquire(timeout: .seconds(30))) { omemo = nil }
                guard !isSuspended, sessions[account.id] == nil else {
                    lock.release()
                    return
                }
            }
            let session = try AccountSession(account: account, password: password, database: database,
                                             status: status, media: media, resilience: resilience, console: console,
                                             loopbackHTTP: loopbackHTTP, credentials: credentials, omemo: omemo)
            sessions[account.id] = session
            await session.setMediaPolicy(mediaPolicy)
            await session.setPush(pushRegistration)
            await session.start()
            if !isActive { await session.setActive(false) }
            if let visible, visible.accountID == account.id {
                await session.setVisibleConversation(visible.peer)
            }
        } catch {
            locks[account.id]?.release()
            status.connection = .failed(String(describing: error))
        }
    }

    private func stopSession(_ accountID: String) async {
        await sessions.removeValue(forKey: accountID)?.stop()
        locks[accountID]?.release()
    }

    /// Announces new messages while the app is in the background, and keeps
    /// the badge in step. In the foreground, new messages are marked announced
    /// without a banner.
    private func startWatching() {
        guard watchTasks.isEmpty else { return }
        let database = self.database
        watchTasks.append(Task { [weak self] in
            let pending = database.observe { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM message WHERE NOT notified AND NOT isOutgoing AND state = 'received'
                    """) ?? 0
            }
            do {
                for try await count in pending where count > 0 { await self?.announcePending() }
            } catch {}
        })
        guard let notifier else { return }
        watchTasks.append(Task {
            do {
                for try await count in database.totalUnread() { await notifier.setBadge(count) }
            } catch {}
        })
        watchTasks.append(Task {
            do {
                for try await unread in database.unreadMessageIDs() { await notifier.withdraw(keeping: unread) }
            } catch {}
        })
    }

    private func announcePending() async {
        // Suspended, the notification service extension announces instead.
        guard !isSuspended, let claimed = try? database.claimPendingNotifications(), !claimed.isEmpty else { return }
        guard !isActive, let notifier else { return }
        let shown = claimed.filter { !$0.muted }
        if !shown.isEmpty { await notifier.announce(shown) }
    }
}
