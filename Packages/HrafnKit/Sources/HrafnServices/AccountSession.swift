import CryptoKit
import Foundation
import OMEMOProtocol
import HrafnStore
import XMPPClient
import XMPPCore
import XMPPIM
import XMPPStream
import XMPPTransport
import XMPPXML

public enum AccountError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidJID(String)
    case missingPassword
    case notConnected
    case notFound
    /// The server's certificate is not trusted by the system. The user may
    /// choose to trust this fingerprint (hex SHA-256).
    case untrustedCertificate(fingerprint: String)
    case authenticationFailed(String)
    case connectionFailed(String)
    /// A room could not be joined, created or changed; the text says why.
    case room(String)
    /// A message could not be encrypted, or cannot be sent encrypted.
    case encryption(String)

    public var description: String {
        switch self {
        case .invalidJID(let jid): "“\(jid)” is not a valid address"
        case .missingPassword: "no password stored for this account"
        case .notConnected: "not connected"
        case .notFound: "not found"
        case .untrustedCertificate(let fingerprint): "untrusted certificate \(fingerprint)"
        case .authenticationFailed(let reason): "authentication failed: \(reason)"
        case .connectionFailed(let reason): reason
        case .room(let reason): reason
        case .encryption(let reason): reason
        }
    }
}

/// How this installation describes itself to peers.
public let hrafnIdentity = ClientIdentity(name: "Hrafn", type: "phone", node: "https://hrafn.stevedylandev.dev")

/// One account's live session: connects, keeps the database in step with the
/// server, and carries out the user's actions.
///
/// Everything the server says is written to the database first; the UI
/// observes the database. Only what does not outlive the session — presence,
/// typing, connection state — goes to `status` instead.
public actor AccountSession {

    public nonisolated let account: Account
    public nonisolated let jid: JID
    public nonisolated let status: AccountStatus
    let database: HrafnDatabase
    nonisolated let client: XMPPClient
    private let roster: Roster
    private let blocking: Blocking
    var archive: MessageArchive?
    /// OMEMO, when the session has storage for it (and holds the account's
    /// lock, so no other process moves the same ratchets).
    let omemo: OMEMOEngine?
    var inbound: InboundStore { InboundStore(database: database, accountID: account.id, omemo: omemo) }
    private var presence = PresenceBook()
    private var eventTask: Task<Void, Never>?
    /// The conversation on screen: its messages are read as they arrive.
    var visiblePeer: String?
    /// Peers that sent us chat states this session, so they understand ours
    /// (XEP-0085 §5.1).
    private var chatStatePeers: Set<String> = []
    /// Live archive ids may move the cursor only after this session's
    /// catch-up, or a gap could be skipped.
    private var caughtUp = false
    private let rejected: RejectedCertificate
    /// XEP-0357 registration, re-sent on every fresh session.
    private var push: PushRegistration?
    /// What we last said about ourselves, re-sent when our avatar changes.
    private var ownAvailability: (ContactAvailability, String?) = (.online, nil)
    /// XEP-0490: conversations read here whose marker is to be published,
    /// gathered for `displayedSyncDelay` so reading a busy chat does not
    /// publish on every message.
    private var displayedSyncPeers: Set<String> = []
    private var displayedSyncTask: Task<Void, Never>?
    var displayedSyncDelay: Duration = .seconds(1)

    // Group chats (AccountSession+Rooms.swift).
    var muc: MultiUserChat?
    /// Rooms joined or being joined this session, by bare JID.
    var rooms: [String: RoomRuntime] = [:]
    var roomPingTask: Task<Void, Never>?
    /// How long a room may stay silent before XEP-0410 self-ping checks we
    /// are still in it.
    var roomPingInterval: Duration = .seconds(15 * 60)

    // Files and profiles (AccountSession+Media.swift).
    let media: MediaStore
    let transfer: HTTPTransfer
    var mediaPolicy = MediaPolicy()
    /// Found once per session.
    var uploadService: HTTPUpload.Service?
    var uploading: Set<Int64> = []
    var downloading: Set<Int64> = []
    var processingAttachments = false
    var vcardFetches: Set<String> = []

    /// Pages of 100; catch-up stops after this many and leaves the rest to the
    /// next session rather than holding the event loop for minutes.
    static let catchUpPageLimit = 20

    /// `loopbackHTTP` sends file transfers for `.test` hosts to 127.0.0.1
    /// (the Docker test servers; see `HTTPTransfer`).
    /// `credentials`, when given, keeps the account's XEP-0484 FAST token.
    public init(account: Account, password: String, database: HrafnDatabase, status: AccountStatus,
                media: MediaStore = .temporary(), resilience: ResilienceOptions = ResilienceOptions(),
                console: (any XMLConsole)? = nil, loopbackHTTP: Bool = false,
                credentials: (any CredentialStore)? = nil, omemo omemoDatabase: OMEMODatabase? = nil) throws {
        guard let jid = try? JID(account.jid), jid.localpart != nil else { throw AccountError.invalidJID(account.jid) }
        self.account = account
        self.jid = jid.bare
        self.database = database
        self.status = status
        let rejected = RejectedCertificate()
        self.rejected = rejected
        let configuration = try Self.configuration(for: account, jid: jid, password: password, credentials: credentials,
                                                   recording: rejected, console: console)
        client = XMPPClient(configuration: configuration, identity: hrafnIdentity, resilience: resilience)
        roster = Roster(client: client)
        blocking = Blocking(client: client)
        if let omemoDatabase, let credentials {
            omemo = OMEMOEngine(account: jid, store: DatabaseOMEMOStore(accountID: account.id, database: omemoDatabase,
                                                                        credentials: credentials),
                                directory: PEPDirectory(client: client))
        } else {
            omemo = nil
        }
        self.media = media
        transfer = HTTPTransfer(pinnedFingerprint: account.trustedFingerprint, loopback: loopbackHTTP)
        ownAvailability = (account.availability.flatMap(ContactAvailability.init(rawValue:)) ?? .online,
                           account.statusMessage)
    }

    /// When others' files are downloaded without asking.
    public func setMediaPolicy(_ policy: MediaPolicy) {
        mediaPolicy = policy
    }

    /// How every Hrafn connection logs in, in the app and in both extensions:
    /// SASL2 with Bind 2 where offered, and a FAST token (XEP-0484) kept with
    /// the password when `credentials` is given. The user agent id comes from
    /// the account's id, which the app and its extensions share, so a token
    /// one of them obtained serves them all.
    static func configuration(for account: Account, jid: JID, password: String, credentials: (any CredentialStore)?,
                              recording rejected: RejectedCertificate,
                              console: (any XMLConsole)?) throws -> SessionConfiguration {
        var configuration = SessionConfiguration(
            credentials: try Credentials(jid: jid, password: password),
            tlsPolicy: tlsPolicy(for: account, recording: rejected),
            endpoints: endpoints(for: account, jid: jid),
            console: console)
        configuration.userAgent = UserAgent(id: userAgentID(for: account), software: "Hrafn")
        configuration.fastTokens = credentials.map { AccountFASTTokens(credentials: $0, accountID: account.id) }
        return configuration
    }

    /// The account id when it is a UUID (as every account Hrafn creates);
    /// otherwise a UUID derived from it, the same every time.
    static func userAgentID(for account: Account) -> UUID {
        if let id = UUID(uuidString: account.id) { return id }
        var bytes = Array(SHA256.hash(data: Data(account.id.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40   // version 4 layout
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func endpoints(for account: Account, jid: JID) -> [Endpoint]? {
        guard let host = account.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
        let security: TransportSecurity = account.directTLS ? .directTLS : .startTLS
        let port = account.port.flatMap(UInt16.init(exactly:)) ?? (account.directTLS ? 5223 : 5222)
        return [Endpoint(host: host, port: port, security: security, domain: jid.domainpart)]
    }

    /// System trust, then the account's pinned fingerprint. Remembers what it
    /// refused so the user can be asked.
    static func tlsPolicy(for account: Account, recording rejected: RejectedCertificate) -> TLSPolicy {
        let pinned = account.trustedFingerprint?.uppercased()
        let standard = TLSPolicy.standard()
        return TLSPolicy { challenge in
            if standard.evaluate(challenge) { return true }
            let fingerprint = challenge.leafFingerprint.map { $0.map { String(format: "%02X", $0) }.joined() }
            if let fingerprint, fingerprint == pinned { return true }
            rejected.value = fingerprint
            return false
        }
    }

    // MARK: - Lifecycle

    /// Starts connecting (retrying in the background) and processing events.
    public func start() async {
        guard eventTask == nil else { return }
        await installHandlers()
        let events = client.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
        for feature in IMFeatures.all + Self.roomFeatures + Self.mediaFeatures + [DisplayedSync.notifyFeature] {
            await client.addFeature(feature)
        }
        if omemo != nil {
            await client.addFeature(LegacyOMEMONodes.deviceListNotify)
            await client.addFeature(OMEMO2Nodes.devicesNotify)
        }
        await client.start()
    }

    /// Closes the session politely.
    public func stop() async {
        roomPingTask?.cancel()
        roomPingTask = nil
        await client.disconnect()
        eventTask?.cancel()
        eventTask = nil
        await MainActor.run { status.connection = .offline }
    }

    /// Tie to the scene phase (XEP-0352).
    public func setActive(_ active: Bool) async {
        await client.setClientState(active ? .active : .inactive)
        if active { checkRooms(force: false) }
    }

    /// One login attempt and a clean logout: proves the settings work before
    /// an account is saved.
    public static func verify(account: Account, password: String) async throws {
        let rejected = RejectedCertificate()
        guard let jid = try? JID(account.jid), jid.localpart != nil else { throw AccountError.invalidJID(account.jid) }
        let configuration = SessionConfiguration(
            credentials: try Credentials(jid: jid, password: password),
            tlsPolicy: tlsPolicy(for: account, recording: rejected),
            endpoints: endpoints(for: account, jid: jid))
        let client = XMPPClient(configuration: configuration, identity: hrafnIdentity, resilience: .oneShot)
        do {
            try await client.connect()
        } catch {
            throw describe(error, rejected: rejected.value)
        }
        await client.disconnect()
    }

    static func describe(_ error: any Error, rejected: String?) -> AccountError {
        if let rejected { return .untrustedCertificate(fingerprint: rejected) }
        switch error {
        case let error as SessionError:
            if case .authenticationFailed(let condition, let text) = error {
                return .authenticationFailed(text ?? condition)
            }
            return .connectionFailed(error.description)
        case let error as AccountError:
            return error
        default:
            return .connectionFailed(String(describing: error))
        }
    }

    // MARK: - Events

    private func installHandlers() async {
        let database = self.database
        let accountID = account.id
        await roster.handlePushes { push in
            try? database.applyRosterPush(accountID: accountID, entry: push.item.entry,
                                          removed: push.item.subscription == .remove, version: push.version)
        }
        await blocking.handlePushes { push in
            switch push {
            case .blocked(let jids): try? database.setBlocked(accountID: accountID, jids: jids.map(\.description), true)
            case .unblocked(let jids): try? database.setBlocked(accountID: accountID, jids: jids.map(\.description), false)
            case .unblockedAll: try? database.replaceBlocklist(accountID: accountID, jids: [])
            }
        }
        archive = await MessageArchive(client: client)
        muc = await MultiUserChat(client: client)
    }

    private func handle(_ event: XMPPClient.Event) async {
        switch event {
        case .stateChanged(let state):
            let connection: ConnectionStatus? = switch state {
            case .disconnected: nil
            case .connecting: .connecting
            case .connected: .online
            case .reconnecting(let attempt): .reconnecting(attempt: attempt)
            case .waitingForNetwork: .waitingForNetwork
            }
            if let connection { await MainActor.run { status.connection = connection } }
        case .established(let full, let resumed):
            rejected.value = nil
            await MainActor.run {
                status.boundJID = full.description
                status.rejectedCertificate = nil
            }
            await sessionEstablished(resumed: resumed)
        case .message(let message):
            await received(message)
        case .presence(let presence):
            await received(presence)
        case .interrupted:
            caughtUp = false
            roomsInterrupted()
        case .disconnected(let error):
            caughtUp = false
            roomsInterrupted()
            let rejected = self.rejected.value
            await MainActor.run {
                if let error {
                    let described = Self.describe(error, rejected: rejected)
                    status.connection = .failed(described.description)
                    if case .untrustedCertificate(let fingerprint) = described { status.rejectedCertificate = fingerprint }
                } else {
                    status.connection = .offline
                }
            }
        }
    }

    private func sessionEstablished(resumed: Bool) async {
        if !resumed {
            // A fresh session starts presence over, and the server needs our
            // interest again (RFC 6121 §1.3): roster, then presence.
            presence.reset()
            chatStatePeers.removeAll()
            await MainActor.run {
                status.presence.removeAll()
                status.statusMessages.removeAll()
                status.typing.removeAll()
            }
            await attempt("roster") { try await self.syncRoster() }
            await attempt("blocklist") {
                let jids = try await self.blocking.blocklist()
                try self.database.replaceBlocklist(accountID: self.account.id, jids: jids.map(\.description))
            }
            await attempt("carbons") { try await Carbons.enable(on: self.client) }
            await attempt("presence") {
                try await self.client.send(Presence.available(self.ownAvailability.0.protocolValue,
                                                              status: self.ownAvailability.1,
                                                              caps: await self.client.capsElement))
            }
            // Before history: archived messages may be for this device.
            await attempt("omemo") { try await self.omemo?.setUp() }
            await attempt("history") { try await self.catchUp() }
            await attempt("displayed sync") { try await self.syncDisplayed() }
            await enablePush()
            uploadService = nil
        }
        caughtUp = true
        await flushOutbox()
        await roomsSessionEstablished(resumed: resumed)
        if !resumed {
            Task {
                await self.processNewAttachments()
                await self.refreshProfiles()
            }
        }
    }

    func attempt(_ what: String, _ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            let text = "\(what): \(error)"
            await MainActor.run { status.lastError = text }
        }
    }

    private func syncRoster() async throws {
        let cached = try database.account(id: account.id)?.rosterVersion
        switch try await roster.fetch(version: cached) {
        case .unchanged:
            break
        case .full(let items, let version):
            try database.replaceRoster(accountID: account.id, entries: items.map(\.entry), version: version)
        }
    }

    private func received(_ presence: Presence) async {
        guard let from = presence.from else { return }
        let bare = from.bare.description
        if isRoom(bare) {
            await receivedRoomPresence(presence)
            return
        }
        if presence.type == .available, from.bare == jid || (try? isContact(bare)) == true {
            let advertised = VCardAvatars.advertised(in: presence)
            if advertised != .unknown { Task { await self.receivedPhotoHash(advertised, from: from) } }
        }
        switch presence.type {
        case .subscribe:
            try? database.setPendingIn(accountID: account.id, jid: bare, true)
        case .available, .unavailable, .error:
            guard self.presence.update(presence) else { return }
            let summary = self.presence.summary(for: from)
            await MainActor.run {
                status.presence[bare] = summary.map { ContactAvailability($0.availability) }
                status.statusMessages[bare] = summary?.status
                if summary == nil { status.typing[bare] = nil }
            }
        default:
            break
        }
    }

    private func received(_ message: Message) async {
        if let changes = Bookmarks.changes(in: message, account: jid) {
            await applyBookmarkChanges(changes)
            return
        }
        if let change = Avatars.change(in: message, account: jid) {
            await applyAvatar(change.avatar, of: change.jid)
            return
        }
        if let change = Nicknames.change(in: message, account: jid) {
            applyNickname(change)
            return
        }
        if let markers = DisplayedSync.changes(in: message, account: jid) {
            applyDisplayed(markers)
            return
        }
        if let change = PEPDirectory.deviceListChange(in: message, account: jid) {
            await attempt("omemo devices") { try await self.omemo?.deviceListChanged(change.deviceIDs, of: change.jid,
                                                                                    version: change.version) }
            return
        }
        if let invite = RoomInvite(message) {
            await received(invite)
            return
        }
        if let from = message.from, isRoom(from.bare.description) || message.type == .groupchat,
           !isPrivateThroughRoom(message, from: from) {
            await receivedRoomMessage(message)
            return
        }
        guard let parsed = InboundMessage(live: message, account: jid) else { return }
        let stored: InboundStore.Stored
        do {
            stored = try await inbound.store(parsed)
        } catch {
            await MainActor.run { status.lastError = "store: \(error)" }
            return
        }
        let inbound = stored.inbound
        let peer = inbound.peer.description
        if let device = stored.acknowledge { Task { await self.acknowledge([device]) } }

        if !inbound.isOutgoing, let state = message.chatState {
            chatStatePeers.insert(peer)
            await MainActor.run { status.typing[peer] = TypingState(state) }
        }

        let events = stored.events
        guard !events.isEmpty else { return }
        if caughtUp, inbound.source != .archive, let archiveID = inbound.archiveID {
            try? database.setArchiveCursor(ArchiveCursor(accountID: account.id, archive: jid.description, lastID: archiveID))
        }

        // XEP-0184 §5.4: answer receipt requests on messages sent to us, and
        // only to contacts allowed to see our presence (§8).
        if inbound.source == .live, !inbound.isOutgoing, message.requestsReceipt, message.type != .error,
           let id = inbound.senderID, let from = message.from, (try? isAuthorized(peer)) == true {
            try? await client.send(Message.receipt(for: id, to: from))
        }
        if visiblePeer == peer, !inbound.isOutgoing, message.body != nil {
            await markRead(peer: peer)
        }
        if events.contains(where: { $0.attachment != nil }) { await processNewAttachments() }
    }

    private func isContact(_ peer: String) throws -> Bool {
        try database.fetchContacts(accountID: account.id).contains { $0.jid == peer && $0.inRoster }
    }

    private func isAuthorized(_ peer: String) throws -> Bool {
        try database.fetchContacts(accountID: account.id).contains {
            $0.jid == peer && ($0.subscription == .from || $0.subscription == .both)
        }
    }

    // MARK: - Push

    /// Sets (or clears) the push registration. Registers with the server now
    /// if connected, else on the next fresh session. Clearing does not
    /// unregister: use `disablePush()` for that.
    public func setPush(_ registration: PushRegistration?) async {
        guard registration != push else { return }
        push = registration
        if await client.jid != nil { await enablePush() }
    }

    private func enablePush() async {
        guard let push else {
            await MainActor.run { status.push = .unavailable }
            return
        }
        let module = PushNotifications(client: client)
        let result: PushStatus
        do {
            if try await module.isSupported() {
                try await module.enable(service: push.settings.service, node: push.node,
                                        publishOptions: push.settings.publishOptions)
                result = .enabled
            } else {
                result = .unsupported
            }
        } catch {
            result = .failed(String(describing: error))
        }
        await MainActor.run { status.push = result }
    }

    /// Unregisters this device, when the account is removed or disabled.
    public func disablePush() async {
        guard let push, await client.jid != nil else { return }
        try? await PushNotifications(client: client).disable(service: push.settings.service, node: push.node)
    }

    // MARK: - History

    private func catchUp() async throws {
        guard let archive else { return }
        let acknowledge = try await Self.catchUp(archive: archive, inbound: inbound, archiveKey: jid.description)
        await self.acknowledge(acknowledge)
    }

    /// Reads the account's archive from where the last session stopped. On
    /// the first login, only the newest page, stored as already read. Shared
    /// with the notification service extension's `BackgroundFetch`. Returns
    /// the OMEMO devices that started sessions, to be answered.
    static func catchUp(archive: MessageArchive, inbound: InboundStore,
                        archiveKey key: String) async throws -> [SessionAddress] {
        let database = inbound.database, accountID = inbound.accountID
        guard let cursor = try database.archiveCursor(accountID: accountID, archive: key) else {
            let page = try await archive.query(.init(page: .before(nil), max: 100))
            let acknowledge = try await inbound.store(page: page.messages, alreadyRead: true)
            if let last = page.last {
                try database.setArchiveCursor(ArchiveCursor(accountID: accountID, archive: key, lastID: last))
            }
            return acknowledge
        }

        var acknowledge: [SessionAddress] = []
        var after = cursor.lastID
        var start: Date?
        for _ in 0..<catchUpPageLimit {
            let page: MessageArchive.Result
            do {
                page = try await archive.query(.init(start: start, page: .after(start == nil ? after : nil), max: 100))
            } catch let error as StanzaError where error.condition == .itemNotFound && start == nil {
                // The cursor has expired from the archive: fall back to time.
                start = cursor.updatedAt.addingTimeInterval(-60)
                continue
            }
            for device in try await inbound.store(page: page.messages, alreadyRead: false)
            where !acknowledge.contains(device) {
                acknowledge.append(device)
            }
            if let last = page.last {
                after = last
                start = nil
                try database.setArchiveCursor(ArchiveCursor(accountID: accountID, archive: key, lastID: last))
            }
            if page.complete || page.messages.isEmpty { break }
        }
        return acknowledge
    }

    /// Fetches the page of a conversation before the oldest message stored.
    /// Returns whether the start of the archive was reached.
    @discardableResult
    public func loadOlder(peer: String, pageSize: Int = 50) async throws -> Bool {
        guard let archive, await client.jid != nil else { throw AccountError.notConnected }
        guard let with = try? JID(peer) else { throw AccountError.invalidJID(peer) }
        if isRoom(peer) { return try await loadOlderInRoom(with, archive: archive, pageSize: pageSize) }
        let before = try database.oldestArchiveID(accountID: account.id, peer: peer)
        let page = try await archive.query(.init(with: with, page: .before(before), max: pageSize))
        _ = try await inbound.store(page: page.messages, alreadyRead: true)
        return page.complete || page.messages.isEmpty
    }

    // MARK: - Sending

    /// Stores the message, then sends it, or leaves it in the outbox until
    /// the next session.
    /// `replyingTo` makes it a XEP-0461 reply to that stored message.
    @discardableResult
    public func send(_ text: String, to peer: String, replyingTo original: Int64? = nil) async throws -> StoredMessage {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let to = try? JID(peer), !body.isEmpty else { throw AccountError.invalidJID(peer) }
        let reply = try original.map { try replyReference(to: $0, in: peer) }
        if isRoom(peer) { return try await sendToRoom(body, room: to, reply: reply) }
        let id = StanzaID.make()
        let address = conversationAddress(to)
        var row = try database.insertOutgoing(accountID: account.id, peer: address.description, body: body, id: id,
                                              reply: reply)
        let message = addressed(Message.chat(to: address, body: body, id: id).replying(to: reply), to: row.peer)
        if await transmit(message, row: row), let sent = try database.message(id: row.id!) {
            row = sent
        }
        try? database.setDraft(accountID: account.id, peer: peer, nil)
        return row
    }

    private func flushOutbox() async {
        guard let pending = try? database.outbox(accountID: account.id) else { return }
        for row in pending where !isRoom(row.peer) {
            if row.attachment != nil {
                // Uploads are slow; don't hold the text messages behind them.
                Task { await self.deliverFile(row) }
                continue
            }
            guard let to = try? JID(row.peer), let id = row.originID else { continue }
            let message = addressed(Message.chat(to: to, body: row.body, id: id).replying(to: row.reply), to: row.peer)
            guard await transmit(message, row: row) else {
                // Not connected: the rest waits too. A message that failed
                // (cannot be encrypted) does not hold up the others.
                if await client.jid == nil { return }
                continue
            }
        }
    }

    /// XEP-0308: replaces the text of one of our messages.
    public func correct(messageID: Int64, with text: String) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let row = try database.message(id: messageID), row.isOutgoing, !row.isRetracted,
              let target = row.originID, let to = try? JID(row.peer) else { throw AccountError.notFound }
        if isRoom(row.peer) { return try await correctInRoom(row, target: target, room: to, body: body) }
        let id = StanzaID.make()
        do {
            // The reply goes with the new version, or clients that replace
            // the whole message would lose it.
            let correction = addressed(Message.correction(of: target, to: to, body: body, id: id)
                .replying(to: row.reply), to: row.peer)
            try await client.send(try await sealed(correction, to: row.peer).message)
        } catch let error as OMEMOProtocolError {
            throw AccountError.encryption(Self.describe(error))
        } catch {
            throw AccountError.notConnected
        }
        try database.ingest(MessageEvent(accountID: account.id, peer: row.peer, isOutgoing: true,
                                         content: .correction(of: target, body: body), senderID: id, stanzaID: id))
    }

    /// XEP-0424: asks everyone to forget one of our messages.
    public func retract(messageID: Int64) async throws {
        guard let row = try database.message(id: messageID), row.isOutgoing, !row.isRetracted,
              let target = row.originID, let to = try? JID(row.peer) else { throw AccountError.notFound }
        if isRoom(row.peer), row.state != .pending { return try await retractInRoom(row, room: to) }
        if row.state == .pending {
            // Never left the device: just drop it.
            try database.ingest(MessageEvent(accountID: account.id, peer: row.peer, isOutgoing: true,
                                             content: .retraction(of: target), senderID: StanzaID.make()))
            return
        }
        let id = StanzaID.make()
        do {
            try await client.send(addressed(Message.retraction(of: target, to: to, id: id), to: row.peer))
        } catch {
            throw AccountError.notConnected
        }
        try database.ingest(MessageEvent(accountID: account.id, peer: row.peer, isOutgoing: true,
                                         content: .retraction(of: target), senderID: id, stanzaID: id))
    }

    /// The conversation the user is looking at, or `nil`. Its incoming
    /// messages are marked read, and displayed markers are sent.
    public func setVisibleConversation(_ peer: String?) async {
        if let old = visiblePeer, old != peer { await sendChatState(.inactive, to: old) }
        visiblePeer = peer
        if let peer { await markRead(peer: peer) }
    }

    /// Marks the conversation read: a XEP-0333 displayed marker to a contact,
    /// and (shortly) the XEP-0490 marker for our other devices.
    public func markRead(peer: String) async {
        if let id = try? database.markConversationRead(accountID: account.id, peer: peer),
           let to = try? JID(peer), !isRoom(peer) {
            try? await client.send(Message.displayed(id, to: to))
        }
        scheduleDisplayedSync(peer)
    }

    /// XEP-0085, only to peers that have shown they understand chat states.
    public func sendChatState(_ state: TypingState, to peer: String) async {
        guard chatStatePeers.contains(peer), let to = try? JID(peer) else { return }
        try? await client.send(addressed(Message.chatState(state.protocolValue, to: to), to: peer))
    }

    // MARK: - Reactions and replies

    /// The XEP-0461 reference to a stored message: the id others know it by,
    /// who wrote it, and its text to quote for clients without replies.
    func replyReference(to messageID: Int64, in peer: String) throws -> ReplyReference {
        let room = isRoom(peer)
        guard let row = try database.message(id: messageID), row.peer == peer else { throw AccountError.notFound }
        guard let id = row.referenceID(inRoom: room) else {
            throw AccountError.room(String(localized: "The room has not confirmed this message yet", bundle: .module))
        }
        let author: String?
        if room {
            let nick = row.isOutgoing ? rooms[peer]?.nick ?? row.senderNick : row.senderNick
            author = nick.flatMap { try? JID(peer).withResource($0) }?.description
        } else {
            author = row.isOutgoing ? jid.description : peer
        }
        let quote = row.isRetracted ? nil : row.attachment == nil ? row.body : row.preview
        return ReplyReference(id: id, to: author, quote: quote)
    }

    /// XEP-0444: adds `emoji` to our reactions to a message, or takes it away
    /// if it is there. Sends our whole new set, as the XEP asks.
    public func toggleReaction(_ emoji: String, on messageID: Int64) async throws {
        guard let row = try database.message(id: messageID), let to = try? JID(row.peer) else {
            throw AccountError.notFound
        }
        let room = isRoom(row.peer)
        guard let target = row.referenceID(inRoom: room) else {
            throw AccountError.room(String(localized: "The room has not confirmed this message yet", bundle: .module))
        }
        if room, rooms[row.peer]?.isJoined != true { throw AccountError.notConnected }
        var emojis = try database.ownReactions(accountID: account.id, peer: row.peer, targetID: target)
        if let index = emojis.firstIndex(of: emoji) { emojis.remove(at: index) } else { emojis.append(emoji) }
        let id = StanzaID.make()
        do {
            try await client.send(addressed(Message.reactions(emojis, to: target, peer: to, type: room ? .groupchat : .chat,
                                                              id: id), to: row.peer))
        } catch {
            throw AccountError.notConnected
        }
        try database.ingest(MessageEvent(accountID: account.id, peer: row.peer, isOutgoing: true,
                                         content: .reactions(to: target, emojis), senderID: id, stanzaID: id,
                                         sender: room ? .init(nick: rooms[row.peer]?.nick) : nil))
    }

    // MARK: - Displayed synchronization

    /// XEP-0490: every conversation's marker, on a fresh session.
    private func syncDisplayed() async throws {
        applyDisplayed(try await DisplayedSync(client: client).fetch())
    }

    private func applyDisplayed(_ markers: [DisplayedSync.Marker]) {
        for marker in markers {
            let peer = marker.conversation.description
            // Our archive's ids for a chat, the room's for a room.
            guard marker.by == (isRoom(peer) ? marker.conversation : jid) else { continue }
            _ = try? database.applyDisplayedSync(accountID: account.id, peer: peer, archiveID: marker.stanzaID)
        }
    }

    private func scheduleDisplayedSync(_ peer: String) {
        // XEP-0490 keeps markers per bare JID: a private conversation through
        // a room has no place there.
        guard !isRoomPrivate(peer) else { return }
        displayedSyncPeers.insert(peer)
        guard displayedSyncTask == nil else { return }
        let delay = displayedSyncDelay
        displayedSyncTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.publishDisplayedSync()
        }
    }

    /// Publishes the markers of the conversations read here since the last
    /// time. Offline, they wait for the next time the conversation is read.
    func publishDisplayedSync() async {
        displayedSyncTask = nil
        let peers = displayedSyncPeers
        displayedSyncPeers.removeAll()
        guard await client.jid != nil else { return }
        let module = DisplayedSync(client: client)
        for peer in peers {
            guard let conversation = try? JID(peer),
                  let id = try? database.displayedSyncCandidate(accountID: account.id, peer: peer) else { continue }
            let marker = DisplayedSync.Marker(conversation: conversation, stanzaID: id,
                                              by: isRoom(peer) ? conversation : jid)
            guard (try? await module.publish(marker)) != nil else { continue }
            try? database.recordDisplayedSync(accountID: account.id, peer: peer, archiveID: id)
        }
    }

    // MARK: - Contacts

    /// Adds a contact and asks to see their presence, pre-approving theirs
    /// (RFC 6121 §3.4) so they need not ask.
    public func addContact(_ address: String, name: String?) async throws {
        guard let jid = try? JID(address.trimmingCharacters(in: .whitespaces)), jid.localpart != nil || jid.isDomainOnly
        else { throw AccountError.invalidJID(address) }
        let name = name?.trimmingCharacters(in: .whitespaces)
        do {
            try await roster.set(RosterItem(jid: jid.bare, name: name?.isEmpty == false ? name : nil))
            try await Subscriptions(client: client).request(jid)
            try await Subscriptions(client: client).approve(jid)
        } catch let error as ClientError where error == .notConnected {
            throw AccountError.notConnected
        }
        try? database.setPendingIn(accountID: account.id, jid: jid.bare.description, false)
    }

    public func renameContact(_ jid: String, to name: String?) async throws {
        guard let contact = try database.fetchContacts(accountID: account.id).first(where: { $0.jid == jid }),
              let address = try? JID(jid) else { throw AccountError.notFound }
        try await roster.set(RosterItem(jid: address, name: name?.isEmpty == false ? name : nil,
                                        groups: contact.groups))
    }

    public func removeContact(_ jid: String) async throws {
        guard let address = try? JID(jid) else { throw AccountError.invalidJID(jid) }
        try await roster.remove(address)
    }

    /// Answers a subscription request. Approving also asks for theirs, so the
    /// relationship is mutual, which is what people expect of a contact.
    public func answerSubscription(from jid: String, approve: Bool) async throws {
        guard let address = try? JID(jid) else { throw AccountError.invalidJID(jid) }
        let subscriptions = Subscriptions(client: client)
        if approve {
            try await subscriptions.approve(address)
            let contact = try database.fetchContacts(accountID: account.id).first { $0.jid == jid }
            if contact?.subscription != .to, contact?.subscription != .both, contact?.pendingOut != true {
                try await subscriptions.request(address)
            }
        } else {
            try await subscriptions.deny(address)
        }
        try database.setPendingIn(accountID: account.id, jid: jid, false)
    }

    public func setBlocked(_ jid: String, _ blocked: Bool) async throws {
        guard let address = try? JID(jid) else { throw AccountError.invalidJID(jid) }
        if blocked {
            try await blocking.block([address])
        } else {
            try await blocking.unblock([address])
        }
        try database.setBlocked(accountID: account.id, jids: [jid], blocked)
    }

    /// Own presence: availability and status message.
    public func setPresence(_ availability: ContactAvailability, status text: String?) async throws {
        ownAvailability = (availability, text)
        let presence = Presence.available(availability.protocolValue, status: text, caps: await client.capsElement)
        try await client.send(presence)
        // XEP-0045 §7.7: rooms only see presence sent to them.
        for runtime in rooms.values where runtime.isJoined {
            guard let nick = runtime.nick, let to = try? runtime.jid.withResource(nick) else { continue }
            var directed = presence
            directed.to = to
            try? await client.send(directed)
        }
    }

    /// Presence again, unchanged: servers add the XEP-0153 photo hash to it,
    /// which is how older clients learn our avatar changed.
    func resendPresence() async {
        try? await setPresence(ownAvailability.0, status: ownAvailability.1)
    }
}

/// The fingerprint of the last certificate the policy refused.
final class RejectedCertificate: @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprint: String?
    var value: String? {
        get { lock.withLock { fingerprint } }
        set { lock.withLock { fingerprint = newValue } }
    }
}

extension RosterItem {
    var entry: RosterEntry {
        RosterEntry(jid: jid.description, name: name,
                    subscription: Contact.Subscription(rawValue: subscription.rawValue) ?? .none,
                    pendingOut: isPendingOut, groups: groups)
    }
}

extension Message {
    /// Makes this a XEP-0461 reply, quoting the original as the fallback.
    func replying(to reply: ReplyReference?) -> Message {
        guard let reply else { return self }
        var message = self
        message.setReply(MessageReply(id: reply.id, to: reply.to.flatMap { try? JID($0) }), quoting: reply.quote)
        return message
    }
}
