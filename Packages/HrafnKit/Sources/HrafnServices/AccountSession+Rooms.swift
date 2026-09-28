import Foundation
import OMEMOProtocol
import HrafnStore
import XMPPClient
import XMPPCore
import XMPPIM
import XMPPXML

/// One room as this session knows it. Lives only as long as the session:
/// a fresh session is in no room until it joins again.
struct RoomRuntime: Sendable {
    enum State: Sendable, Equatable {
        case joining
        case joined
        /// Out of the room; the text says why.
        case left(String?)
    }

    let jid: JID
    var state: State = .joining
    /// The nickname asked for, then the one the room confirmed.
    var nick: String?
    var ownOccupantID: String?
    var info: RoomInfo?
    var occupants = RoomOccupants()
    /// Live archive ids may move the room's cursor only after the join's
    /// catch-up, or a gap could be skipped.
    var caughtUp = false
    /// When the room last sent us anything; self-ping only rooms that went quiet.
    var lastHeard = ContinuousClock.now
    /// Private groups: the members' real bare JIDs (owners, admins,
    /// members), from the affiliation lists and the occupants' presence.
    /// OMEMO encrypts for these.
    var members: Set<JID> = []
    /// Real bare JIDs by occupant id and by nick, to tell who sent an
    /// encrypted message.
    var realJIDs: [String: JID] = [:]

    var isJoined: Bool { state == .joined }
}

/// What kind of room `createRoom` makes (modernxmpp.org's two kinds).
public enum RoomKind: Sendable, Hashable {
    /// Members only, real JIDs visible, not listed: like a group of contacts.
    case privateGroup
    /// Open, listed, pseudonymous.
    case channel
}

extension AccountSession {

    static let roomFeatures = [Namespaces.muc, Namespaces.directInvite, Bookmarks.notifyFeature]

    /// The nick to join with when the bookmark has none.
    var defaultNick: String { jid.localpart ?? "me" }

    func isRoom(_ bare: String) -> Bool {
        rooms[bare] != nil || (try? database.isRoom(accountID: account.id, jid: bare)) == true
    }

    // MARK: - Private messages (XEP-0045 §7.5)

    /// Whether `peer` is a private conversation with a room occupant.
    func isRoomPrivate(_ peer: String) -> Bool { RoomPrivate.split(peer) != nil }

    /// Where a conversation with `address` lives: its bare JID, unless it is
    /// an occupant of a room we know.
    func conversationAddress(_ address: JID) -> JID {
        address.isFull && isRoom(address.bare.description) ? address : address.bare
    }

    /// `message` as it goes to `peer`: marked private when `peer` is an
    /// occupant, as §7.5 asks.
    func addressed(_ message: Message, to peer: String) -> Message {
        isRoomPrivate(peer) ? message.privateThroughRoom() : message
    }

    /// Whether a message from a room's occupant JID is private to us rather
    /// than for the room. An error goes to the private conversation only if
    /// there is one: the room's own errors stay with the room.
    func isPrivateThroughRoom(_ message: Message, from: JID) -> Bool {
        guard from.isFull, message.type != .groupchat else { return false }
        if message.type == .error {
            return (try? database.writer.read { db in
                try Conversation.exists(db, key: ["accountID": self.account.id, "peer": from.description])
            }) == true
        }
        return true
    }

    /// The conversation a chat message belongs to: the occupant's, for a
    /// private message through a room (carbons and archive copies too).
    static func conversation(of inbound: InboundMessage, database: HrafnDatabase,
                             accountID: String) -> InboundMessage {
        guard inbound.counterpart.isFull, inbound.message.type != .groupchat else { return inbound }
        let throughRoom = inbound.message.isMarkedRoomPrivate
            || (try? database.isRoom(accountID: accountID, jid: inbound.counterpart.bare.description)) == true
        return throughRoom ? inbound.throughRoom() ?? inbound : inbound
    }

    // MARK: - Session

    func roomsSessionEstablished(resumed: Bool) async {
        defer { startRoomPings() }
        if resumed {
            // The server kept us in our rooms, unless one restarted or
            // dropped us while we were away; ask each (XEP-0410).
            checkRooms(force: true)
            return
        }
        // A fresh session is in no room: the server took us out when the old
        // one ended. Rejoin what we were in and everything set to autojoin.
        let wereIn = Set(rooms.values.filter { $0.isJoined || $0.state == .joining }.map(\.jid.description))
        rooms.removeAll()
        await MainActor.run { status.rooms.removeAll() }
        await attempt("bookmarks") { try await self.syncBookmarks() }
        let toJoin = ((try? database.fetchRooms(accountID: account.id)) ?? [])
            .filter { $0.autojoin || wereIn.contains($0.jid) }
        guard !toJoin.isEmpty else { return }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for room in toJoin { group.addTask { await self.join(room) } }
            }
        }
    }

    func roomsInterrupted() {
        roomPingTask?.cancel()
        roomPingTask = nil
    }

    // MARK: - Joining

    /// Joins a stored room, catches up with its archive and sends what waited
    /// in its outbox. Failures end up in the room's status.
    func join(_ room: Room) async {
        guard let muc, let roomJID = try? JID(room.jid) else { return }
        let key = room.jid
        if let existing = rooms[key], existing.state == .joining || existing.isJoined { return }
        // In place before the presence goes out, so the room's answer (on
        // `events`) finds it.
        rooms[key] = RoomRuntime(jid: roomJID, nick: room.nick ?? defaultNick, ownOccupantID: room.ownOccupantID)
        await publishRoomStatus(key)
        do {
            let info: RoomInfo?
            do {
                info = try await muc.info(roomJID)
            } catch let error as StanzaError where error.condition == .itemNotFound {
                // Destroyed while we were away. Joining would create it anew.
                await forget(bookmarkOf: roomJID)
                rooms[key]?.state = .left(String(localized: "The room no longer exists", bundle: .module))
                await publishRoomStatus(key)
                return
            } catch {
                info = nil
            }
            if let info { await roomInfoChanged(key, info) }
            let history: MultiUserChat.History
            if info?.supportsArchive == true {
                history = .none
            } else if let since = try? database.newestMessageDate(accountID: account.id, peer: key) {
                history = .since(since)
            } else {
                history = .maxStanzas(20)
            }
            let nick = room.nick ?? defaultNick
            let own: OccupantPresence
            do {
                own = try await muc.join(roomJID, nick: nick, password: room.password, history: history)
            } catch let error as StanzaError where error.condition == .conflict {
                // Taken — often by a ghost of our own previous session.
                own = try await muc.join(roomJID, nick: nick + "_", password: room.password, history: history)
            }
            if own.statusCodes.contains(MUCStatus.created) {
                // The room had gone (destroyed while we were away), and our
                // join created a new, locked one. Undo that and stop joining.
                try? await muc.destroy(roomJID)
                await forget(bookmarkOf: roomJID)
                rooms[key]?.state = .left(String(localized: "The room no longer exists", bundle: .module))
                await publishRoomStatus(key)
                return
            }
            guard rooms[key] != nil else { return }
            rooms[key]?.state = .joined
            rooms[key]?.nick = own.nick
            rooms[key]?.lastHeard = .now
            if info == nil, let fetched = try? await muc.info(roomJID) { await roomInfoChanged(key, fetched) }
            if rooms[key]?.info?.supportsOccupantIDs == true, let occupantID = own.occupantID {
                rooms[key]?.ownOccupantID = occupantID
                _ = try? database.updateRoom(accountID: account.id, jid: key) { $0.ownOccupantID = occupantID }
            }
            await publishRoomStatus(key)
            await loadMembers(key)
            if rooms[key]?.info?.supportsArchive == true {
                await attempt("history of \(key)") { try await self.catchUpRoom(roomJID) }
            }
            rooms[key]?.caughtUp = true
            await flushRoomOutbox(key)
        } catch {
            guard rooms[key] != nil else { return }
            rooms[key]?.state = .left(Self.describeJoinError(error))
            await publishRoomStatus(key)
        }
    }

    private func roomInfoChanged(_ key: String, _ info: RoomInfo) async {
        rooms[key]?.info = info
        _ = try? database.updateRoom(accountID: account.id, jid: key) { room in
            room.isMembersOnly = info.isMembersOnly
            room.isNonAnonymous = info.isNonAnonymous
            if room.name == nil { room.name = info.name }
        }
        await publishRoomStatus(key)
    }

    static func describeJoinError(_ error: any Error) -> String {
        guard let error = error as? StanzaError else {
            if let error = error as? ClientError, error == .timedOut { return String(localized: "The room did not answer", bundle: .module) }
            return String(describing: error)
        }
        switch error.condition {
        case .notAuthorized: return String(localized: "A password is required", bundle: .module)
        case .registrationRequired: return String(localized: "Only members may join", bundle: .module)
        case .forbidden: return String(localized: "You are banned from this room", bundle: .module)
        case .itemNotFound: return String(localized: "The room does not exist", bundle: .module)
        case .notAllowed: return String(localized: "You may not create rooms on this service", bundle: .module)
        case .serviceUnavailable: return String(localized: "The room is full", bundle: .module)
        case .conflict: return String(localized: "Your nickname is in use", bundle: .module)
        case .remoteServerNotFound, .remoteServerTimeout: return String(localized: "The room's server cannot be reached", bundle: .module)
        default: return error.text ?? error.condition.rawValue
        }
    }

    private static func describe(_ exit: RoomOccupants.Exit, destroyed: Bool) -> String? {
        if destroyed { return String(localized: "The room was destroyed", bundle: .module) }
        switch exit {
        case .left: return nil
        case .kicked(let reason): return reason.map { "Kicked: \($0)" } ?? "Kicked"
        case .banned(let reason): return reason.map { "Banned: \($0)" } ?? "Banned"
        case .removed: return String(localized: "No longer a member", bundle: .module)
        case .shutdown: return String(localized: "The service shut down", bundle: .module)
        case .technical: return String(localized: "Removed by a technical problem", bundle: .module)
        }
    }

    // MARK: - Inbound

    func receivedRoomPresence(_ presence: Presence) async {
        guard let from = presence.from else { return }
        let key = from.bare.description
        guard rooms[key] != nil else { return }
        rooms[key]?.lastHeard = .now
        // Errors belong to a join or nick change, which report them.
        guard presence.type != .error, let occupant = OccupantPresence(presence) else { return }
        if occupant.isAvailable {
            let advertised = VCardAvatars.advertised(in: presence)
            if advertised != .unknown { Task { await self.receivedOccupantPhotoHash(advertised, from: from) } }
        }
        noteMember(occupant, in: key)
        switch rooms[key]!.occupants.apply(occupant) {
        case .joined(let own), .updatedSelf(let own):
            rooms[key]?.state = .joined
            rooms[key]?.nick = own.nick
        case .exited(let exit):
            let destroyed = RoomOccupants.isDestroyed(presence)
            rooms[key]?.state = .left(Self.describe(exit, destroyed: destroyed))
            rooms[key]?.caughtUp = false
            if destroyed { await forget(bookmarkOf: from.bare) }
            switch exit {
            case .shutdown where !destroyed, .technical:
                let jid = from.bare
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    await self.rejoin(jid.description)
                }
            default:
                break
            }
        case .occupants, .none:
            break
        }
        await publishRoomStatus(key)
    }

    func receivedRoomMessage(_ message: Message) async {
        guard let from = message.from else { return }
        let key = from.bare.description
        // Not in that room this session (a stale occupant's echo), or a
        // private message through the room, which Hrafn does not support yet.
        guard let runtime = rooms[key], message.type == .groupchat || message.type == .error,
              let roomMessage = RoomMessage(live: message, info: runtime.info) else { return }
        rooms[key]?.lastHeard = .now

        if message.type == .error, message.error?.condition == .notAcceptable {
            // §7.4: we sent to a room that no longer counts us as an occupant.
            Task { await self.selfPing(runtime.jid) }
        }
        if let subject = roomMessage.subject {
            _ = try? database.updateRoom(accountID: account.id, jid: key) { $0.subject = subject.isEmpty ? nil : subject }
            return
        }
        let stored: InboundStore.Stored
        do {
            stored = try await inbound.store(room: roomMessage, sender: realSender(of: roomMessage),
                                             me: roomSelf(key))
        } catch {
            await MainActor.run { status.lastError = "store: \(error)" }
            return
        }
        if let device = stored.acknowledge { Task { await self.acknowledge([device]) } }
        let events = stored.events
        guard !events.isEmpty else { return }
        if runtime.caughtUp, let archiveID = roomMessage.archiveID {
            try? database.setArchiveCursor(ArchiveCursor(accountID: account.id, archive: key, lastID: archiveID))
        }
        if visiblePeer == key, message.body != nil {
            await markRead(peer: key)
        }
        if events.contains(where: { $0.attachment != nil }) { await processNewAttachments() }
    }

    private func roomSelf(_ key: String) -> RoomSelf {
        RoomSelf(account: jid, nick: rooms[key]?.nick, occupantID: rooms[key]?.ownOccupantID)
    }

    func received(_ invite: RoomInvite) async {
        let key = invite.room.description
        if let inviter = invite.inviter,
           (try? database.isBlocked(accountID: account.id, jid: inviter.description)) == true { return }
        if rooms[key]?.isJoined == true { return }
        try? database.saveInvitation(RoomInvitation(accountID: account.id, room: key,
                                                    inviter: invite.inviter?.description, reason: invite.reason,
                                                    password: invite.password))
    }

    // MARK: - History

    /// Reads a room's archive from where the last session stopped; on the
    /// first join, only the newest page, stored as read.
    func catchUpRoom(_ room: JID) async throws {
        guard let archive else { return }
        let key = room.description
        guard let cursor = try database.archiveCursor(accountID: account.id, archive: key) else {
            let page = try await archive.query(.init(page: .before(nil), max: 50), archive: room)
            try await ingestRoomPage(page, room: room, alreadyRead: true)
            // An empty archive still needs a cursor, or the next catch-up
            // would take what arrives meanwhile for old history: "" means
            // "from `updatedAt`".
            try database.setArchiveCursor(ArchiveCursor(accountID: account.id, archive: key, lastID: page.last ?? ""))
            return
        }
        var after = cursor.lastID
        // A little slack for clock skew; duplicates are harmless.
        var start: Date? = cursor.lastID.isEmpty ? cursor.updatedAt.addingTimeInterval(-60) : nil
        for _ in 0..<Self.catchUpPageLimit {
            let page: MessageArchive.Result
            do {
                page = try await archive.query(.init(start: start, page: .after(start == nil ? after : nil), max: 100),
                                               archive: room)
            } catch let error as StanzaError where error.condition == .itemNotFound && start == nil {
                // The cursor has expired from the room's archive: fall back to time.
                start = cursor.updatedAt.addingTimeInterval(-60)
                continue
            }
            try await ingestRoomPage(page, room: room, alreadyRead: false)
            if let last = page.last {
                after = last
                start = nil
                try database.setArchiveCursor(ArchiveCursor(accountID: account.id, archive: key, lastID: last))
            }
            if page.complete || page.messages.isEmpty { break }
        }
    }

    private func ingestRoomPage(_ page: MessageArchive.Result, room: JID, alreadyRead: Bool) async throws {
        let key = room.description
        let info = rooms[key]?.info
        let me = roomSelf(key)
        let messages = page.messages.compactMap { RoomMessage(archived: $0, room: room, info: info) }
        var plain: [MessageEvent] = []
        var acknowledge: [SessionAddress] = []
        for message in messages {
            guard message.message.omemoEncrypted != nil else {
                plain += message.events(accountID: account.id, me: me, alreadyRead: alreadyRead)
                continue
            }
            // Keep order: what came before is stored first.
            if !plain.isEmpty { try database.ingest(plain) }
            plain.removeAll()
            let stored = try await inbound.store(room: message, sender: realSender(of: message), me: me,
                                                 alreadyRead: alreadyRead)
            if let device = stored.acknowledge, !acknowledge.contains(device) { acknowledge.append(device) }
        }
        if !plain.isEmpty { try database.ingest(plain) }
        if !acknowledge.isEmpty { Task { await self.acknowledge(acknowledge) } }
    }

    func loadOlderInRoom(_ room: JID, archive: MessageArchive, pageSize: Int) async throws -> Bool {
        let before = try database.oldestArchiveID(accountID: account.id, peer: room.description)
        let page = try await archive.query(.init(page: .before(before), max: pageSize), archive: room)
        try await ingestRoomPage(page, room: room, alreadyRead: true)
        return page.complete || page.messages.isEmpty
    }

    // MARK: - Sending

    func sendToRoom(_ body: String, room: JID, reply: ReplyReference? = nil) async throws -> StoredMessage {
        let key = room.description
        let id = StanzaID.make()
        var row = try database.insertOutgoing(accountID: account.id, room: key, nick: rooms[key]?.nick,
                                              body: body, id: id, reply: reply)
        if rooms[key]?.isJoined == true,
           await transmit(Message.groupchat(to: room, body: body, id: id).replying(to: reply)
                .mentioningOccupants(otherNicks(key), in: room), row: row),
           let sent = try database.message(id: row.id!) {
            row = sent
        }
        try? database.setDraft(accountID: account.id, peer: key, nil)
        return row
    }

    /// Everyone else in the room, for XEP-0372 mentions.
    private func otherNicks(_ key: String) -> [String] {
        guard let runtime = rooms[key] else { return [] }
        return runtime.occupants.occupants.keys.filter { $0 != runtime.nick }
    }

    private func flushRoomOutbox(_ key: String) async {
        guard let runtime = rooms[key], runtime.isJoined,
              let pending = try? database.outbox(accountID: account.id, peer: key) else { return }
        for row in pending {
            if row.attachment != nil {
                guard await deliverFile(row) else { return }
                continue
            }
            guard let id = row.originID else { continue }
            let message = Message.groupchat(to: runtime.jid, body: row.body, id: id)
                .replying(to: row.reply).mentioningOccupants(otherNicks(key), in: runtime.jid)
            guard await transmit(message, row: row) else {
                // Not connected: the rest waits. One that cannot be
                // encrypted has failed and does not hold up the others.
                if await client.jid == nil || rooms[key]?.isJoined != true { return }
                continue
            }
        }
    }

    func correctInRoom(_ row: StoredMessage, target: String, room: JID, body: String) async throws {
        guard rooms[row.peer]?.isJoined == true else { throw AccountError.notConnected }
        let id = StanzaID.make()
        do {
            let correction = Message.groupchatCorrection(of: target, to: room, body: body, id: id)
                .replying(to: row.reply).mentioningOccupants(otherNicks(row.peer), in: room)
            try await client.send(try await sealed(correction, to: row.peer).message)
        } catch let error as OMEMOProtocolError {
            throw AccountError.encryption(Self.describe(error, room: true))
        } catch let error as RoomEncryptionError {
            throw AccountError.encryption(error.description)
        } catch {
            throw AccountError.notConnected
        }
        try database.ingest(MessageEvent(accountID: account.id, peer: row.peer, isOutgoing: true,
                                         content: .correction(of: target, body: body), senderID: id, stanzaID: id,
                                         sender: .init(nick: rooms[row.peer]?.nick)))
    }

    /// XEP-0424 in a room names the room's id for the message, which we learn
    /// from its reflection.
    func retractInRoom(_ row: StoredMessage, room: JID) async throws {
        guard let target = row.archiveID else { throw AccountError.room(String(localized: "The room has not confirmed this message yet", bundle: .module)) }
        guard rooms[row.peer]?.isJoined == true else { throw AccountError.notConnected }
        let id = StanzaID.make()
        do {
            try await client.send(Message.groupchatRetraction(of: target, to: room, id: id))
        } catch {
            throw AccountError.notConnected
        }
        try database.ingest(MessageEvent(accountID: account.id, peer: row.peer, isOutgoing: true,
                                         content: .retraction(of: target), senderID: id, stanzaID: id,
                                         sender: .init(nick: rooms[row.peer]?.nick)))
    }

    // MARK: - Self-ping

    /// XEP-0410 for joined rooms: all of them (`force`, after a resume or a
    /// return to the foreground), or those quiet for `roomPingInterval`.
    func checkRooms(force: Bool) {
        let due = rooms.values.filter {
            $0.isJoined && (force || $0.lastHeard.duration(to: .now) >= roomPingInterval)
        }
        for runtime in due { Task { await self.selfPing(runtime.jid) } }
    }

    func selfPing(_ room: JID) async {
        let key = room.description
        guard let muc, let nick = rooms[key]?.nick, rooms[key]?.isJoined == true else { return }
        switch await muc.selfPing(room, nick: nick) {
        case .joined:
            rooms[key]?.lastHeard = .now
        case .notJoined:
            await rejoin(key)
        case .unreachable:
            break
        }
    }

    private func startRoomPings() {
        roomPingTask?.cancel()
        let interval = roomPingInterval
        roomPingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval / 2)
                guard !Task.isCancelled else { return }
                await self?.checkRooms(force: false)
            }
        }
    }

    /// Joins again, from scratch.
    func rejoin(_ key: String) async {
        guard let room = try? database.fetchRoom(accountID: account.id, jid: key) else { return }
        rooms[key] = nil
        await join(room)
    }

    // MARK: - Bookmarks

    func syncBookmarks() async throws {
        let module = Bookmarks(client: client)
        var bookmarks = try await module.fetch()
        if bookmarks.isEmpty, (try? await module.isCompatible()) != true {
            // Only an older client's bookmarks, if any; read them, and publish
            // Bookmarks 2 when the user next changes one.
            bookmarks = (try? await module.fetchLegacy()) ?? []
        }
        try database.replaceBookmarks(accountID: account.id, bookmarks.map(\.entry))
    }

    func applyBookmarkChanges(_ changes: [Bookmarks.Change]) async {
        for change in changes {
            switch change {
            case .published(let bookmark):
                try? database.applyBookmark(accountID: account.id, bookmark.entry)
                let key = bookmark.room.description
                if bookmark.autojoin, rooms[key]?.isJoined != true, rooms[key]?.state != .joining,
                   let room = try? database.fetchRoom(accountID: account.id, jid: key) {
                    rooms[key] = nil
                    Task { await self.join(room) }
                }
            case .retracted(let room):
                // Left on another of our devices: leave here too.
                let key = room.description
                try? database.removeBookmark(accountID: account.id, jid: key)
                if let runtime = rooms.removeValue(forKey: key), runtime.isJoined, let nick = runtime.nick {
                    try? await muc?.leave(room, nick: nick)
                }
                await MainActor.run { _ = status.rooms.removeValue(forKey: key) }
            }
        }
    }

    /// A room that is gone: no device should try to join it again.
    private func forget(bookmarkOf room: JID) async {
        try? database.removeBookmark(accountID: account.id, jid: room.description)
        try? await Bookmarks(client: client).retract(room)
    }

    private func publishBookmark(_ room: Room) async throws {
        let bookmark = Bookmark(room: try JID(room.jid), name: room.name, autojoin: room.autojoin, nick: room.nick,
                                password: room.password,
                                extensions: room.bookmarkExtensions.flatMap { try? Element(xmlFragment: $0) })
        try await Bookmarks(client: client).publish(bookmark)
    }

    // MARK: - Status

    func publishRoomStatus(_ key: String) async {
        guard let runtime = rooms[key] else {
            await MainActor.run { _ = status.rooms.removeValue(forKey: key) }
            return
        }
        var room = RoomStatus(state: .joining, nick: runtime.nick)
        room.supportsModeration = runtime.info?.moderationNamespace != nil
        switch runtime.state {
        case .joining: room.state = .joining
        case .joined: room.state = .joined
        case .left(let reason): room.state = .notJoined(reason)
        }
        if let own = runtime.occupants.own {
            room.role = own.role
            room.affiliation = own.affiliation
        }
        room.occupants = runtime.occupants.occupants.values
            .map { RoomOccupantStatus(nick: $0.nick, role: $0.role, affiliation: $0.affiliation,
                                      jid: $0.realJID?.bare.description,
                                      availability: ContactAvailability($0.availability)) }
            .sorted { $0.role != $1.role ? $0.role < $1.role
                      : $0.nick.localizedCaseInsensitiveCompare($1.nick) == .orderedAscending }
        await MainActor.run { status.rooms[key] = room }
    }

    // MARK: - Actions

    private func roomJID(_ address: String) throws -> JID {
        guard let jid = try? JID(address.trimmingCharacters(in: .whitespaces)), jid.localpart != nil else {
            throw AccountError.invalidJID(address)
        }
        return jid.bare
    }

    private func requireConnection() async throws -> MultiUserChat {
        guard let muc, await client.jid != nil else { throw AccountError.notConnected }
        return muc
    }

    /// Joins an existing room and bookmarks it with autojoin, so every later
    /// session — and our other devices — join it too.
    public func joinRoom(_ address: String, nick: String? = nil, password: String? = nil) async throws {
        let muc = try await requireConnection()
        let room = try roomJID(address)
        let key = room.description
        do {
            guard try await muc.info(room) != nil else { throw AccountError.room(String(localized: "\(key) is not a group chat", bundle: .module)) }
        } catch let error as StanzaError {
            throw AccountError.room(Self.describeJoinError(error))
        }
        let nick = nick?.trimmingCharacters(in: .whitespaces)
        var stored = try database.updateRoom(accountID: account.id, jid: key) { room in
            if let nick, !nick.isEmpty { room.nick = nick }
            if let password { room.password = password }
        }
        rooms[key] = nil
        await join(stored)
        if case .left(let reason) = rooms[key]?.state { throw AccountError.room(reason ?? String(localized: "Could not join", bundle: .module)) }
        stored = try database.updateRoom(accountID: account.id, jid: key) { room in
            room.autojoin = true
            room.bookmarked = true
        }
        try? database.deleteInvitation(accountID: account.id, room: key)
        try database.openConversation(accountID: account.id, peer: key)
        await attempt("bookmark") { try await self.publishBookmark(stored) }
    }

    /// Creates a room on our server's MUC service, configured as `kind`, and
    /// joins it. Returns its JID.
    @discardableResult
    public func createRoom(name: String, kind: RoomKind, localpart: String? = nil) async throws -> String {
        let muc = try await requireConnection()
        guard let service = try await muc.findService(on: jid.domain) else {
            throw AccountError.room(String(localized: "This server has no group chat service", bundle: .module))
        }
        let local = localpart?.trimmingCharacters(in: .whitespaces).lowercased()
            ?? Self.slug(name) + "-" + StanzaID.make().prefix(4)
        guard let room = try? JID(localpart: local, domainpart: service.domainpart) else {
            throw AccountError.invalidJID(local)
        }
        let key = room.description
        if (try? await muc.info(room)) ?? nil != nil { throw AccountError.room(String(localized: "\(key) already exists", bundle: .module)) }

        rooms[key] = RoomRuntime(jid: room, nick: defaultNick)
        let own: OccupantPresence
        do {
            own = try await muc.join(room, nick: defaultNick)
        } catch {
            rooms[key] = nil
            throw AccountError.room(Self.describeJoinError(error))
        }
        guard own.statusCodes.contains(MUCStatus.created) else {
            try? await muc.leave(room, nick: own.nick)
            rooms[key] = nil
            throw AccountError.room(String(localized: "\(key) already exists", bundle: .module))
        }
        var form = try await muc.configurationForm(room)
        let privateGroup = kind == .privateGroup
        form.set("muc#roomconfig_roomname", [name])
        form.set("muc#roomconfig_persistentroom", ["1"])
        form.set("muc#roomconfig_membersonly", [privateGroup ? "1" : "0"])
        form.set("muc#roomconfig_whois", [privateGroup ? "anyone" : "moderators"])
        form.set("muc#roomconfig_publicroom", [privateGroup ? "0" : "1"])
        form.set("muc#roomconfig_allowinvites", [privateGroup ? "1" : "0"])
        form.set("{http://prosody.im/protocol/muc}roomconfig_allowmemberinvites", [privateGroup ? "1" : "0"])
        // Archiving: Prosody's field, then ejabberd's.
        form.set("muc#roomconfig_enablearchiving", ["1"])
        form.set("mam", ["1"])
        try await muc.configure(room, form: form)

        rooms[key]?.state = .joined
        rooms[key]?.nick = own.nick
        rooms[key]?.caughtUp = true
        if let info = try? await muc.info(room) { await roomInfoChanged(key, info) }
        if rooms[key]?.info?.supportsOccupantIDs == true { rooms[key]?.ownOccupantID = own.occupantID }
        let stored = try database.updateRoom(accountID: account.id, jid: key) { stored in
            stored.name = name
            stored.autojoin = true
            stored.bookmarked = true
            stored.isMembersOnly = privateGroup
            stored.isNonAnonymous = privateGroup
            if self.rooms[key]?.info?.supportsOccupantIDs == true { stored.ownOccupantID = own.occupantID }
        }
        try database.openConversation(accountID: account.id, peer: key)
        await publishRoomStatus(key)
        await attempt("bookmark") { try await self.publishBookmark(stored) }
        return key
    }

    /// "Verona Nights!" → "verona-nights"
    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let words = folded.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let slug = words.joined(separator: "-")
        return slug.isEmpty ? "room" : String(slug.prefix(32))
    }

    /// Leaves the room and removes its bookmark, so no device rejoins it.
    /// The conversation and its history stay until deleted.
    public func leaveRoom(_ address: String) async throws {
        let muc = try await requireConnection()
        let room = try roomJID(address)
        let key = room.description
        if let runtime = rooms.removeValue(forKey: key), runtime.isJoined, let nick = runtime.nick {
            try? await muc.leave(room, nick: nick)
        }
        await MainActor.run { _ = status.rooms.removeValue(forKey: key) }
        if try database.fetchRoom(accountID: account.id, jid: key)?.bookmarked == true {
            try await Bookmarks(client: client).retract(room)
        }
        try database.removeBookmark(accountID: account.id, jid: key)
    }

    /// Tries to join again after a failure, or after being kicked.
    public func rejoinRoom(_ address: String) async throws {
        _ = try await requireConnection()
        let key = try roomJID(address).description
        await rejoin(key)
        if case .left(let reason) = rooms[key]?.state { throw AccountError.room(reason ?? String(localized: "Could not join", bundle: .module)) }
    }

    public func changeNick(in address: String, to nick: String) async throws {
        let muc = try await requireConnection()
        let room = try roomJID(address)
        let nick = nick.trimmingCharacters(in: .whitespaces)
        guard !nick.isEmpty else { throw AccountError.room(String(localized: "Enter a nickname", bundle: .module)) }
        do {
            try await muc.changeNick(in: room, to: nick)
        } catch {
            throw AccountError.room(Self.describeJoinError(error))
        }
        let stored = try database.updateRoom(accountID: account.id, jid: room.description) { $0.nick = nick }
        if stored.bookmarked { await attempt("bookmark") { try await self.publishBookmark(stored) } }
    }

    public func setSubject(_ subject: String, in address: String) async throws {
        _ = try await requireConnection()
        try await client.send(Message.subject(subject, room: try roomJID(address)))
    }

    /// Invites a contact: through the room for members-only rooms, which
    /// makes them a member (XEP-0045 §7.8.2), directly otherwise (XEP-0249).
    public func invite(_ contact: String, to address: String, reason: String? = nil) async throws {
        _ = try await requireConnection()
        let room = try roomJID(address)
        guard let invitee = try? JID(contact.trimmingCharacters(in: .whitespaces)) else {
            throw AccountError.invalidJID(contact)
        }
        let stored = try database.fetchRoom(accountID: account.id, jid: room.description)
        let reason = reason?.isEmpty == false ? reason : nil
        if stored?.isMembersOnly == true || rooms[room.description]?.info?.isMembersOnly == true {
            try await client.send(Message.mediatedInvite(to: invitee.bare, room: room, reason: reason))
        } else {
            try await client.send(Message.directInvite(to: invitee.bare, room: room, reason: reason,
                                                       password: stored?.password))
        }
    }

    public func acceptInvitation(_ address: String, nick: String? = nil) async throws {
        let key = try roomJID(address).description
        let invitation = try database.invitation(accountID: account.id, room: key)
        try await joinRoom(key, nick: nick, password: invitation?.password)
    }

    public func declineInvitation(_ address: String) throws {
        try database.deleteInvitation(accountID: account.id, room: try roomJID(address).description)
    }

    /// The room's configuration form, for owners (§10.2).
    public func roomConfiguration(_ address: String) async throws -> DataForm {
        try await requireConnection().configurationForm(try roomJID(address))
    }

    public func configureRoom(_ address: String, form: DataForm) async throws {
        let muc = try await requireConnection()
        let room = try roomJID(address)
        try await muc.configure(room, form: form)
        if let info = try? await muc.info(room) {
            await roomInfoChanged(room.description, info)
            if let name = info.name {
                _ = try? database.updateRoom(accountID: account.id, jid: room.description) { $0.name = name }
            }
        }
    }

    /// Kick (`.none`), voice (`.participant`/`.visitor`), moderator.
    public func setRole(_ role: MUCRole, of nick: String, in address: String, reason: String? = nil) async throws {
        try await requireConnection().setRole(role, nick: nick, in: try roomJID(address), reason: reason)
    }

    /// Ban (`.outcast`), membership, admin, owner.
    public func setAffiliation(_ affiliation: MUCAffiliation, of jid: String, in address: String,
                               reason: String? = nil) async throws {
        guard let target = try? JID(jid) else { throw AccountError.invalidJID(jid) }
        try await requireConnection().setAffiliation(affiliation, of: target, in: try roomJID(address), reason: reason)
    }

    /// XEP-0425: as a moderator, takes down someone's message in a room.
    public func moderate(messageID: Int64, reason: String? = nil) async throws {
        guard let row = try database.message(id: messageID), let runtime = rooms[row.peer] else {
            throw AccountError.notFound
        }
        guard let target = row.archiveID else {
            throw AccountError.room(String(localized: "The room has not confirmed this message yet", bundle: .module))
        }
        let info = runtime.info ?? RoomInfo(features: [])
        guard info.moderationNamespace != nil else {
            throw AccountError.room(String(localized: "This room does not support removing messages", bundle: .module))
        }
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await requireConnection().moderate(target, in: runtime.jid, reason: reason?.isEmpty == false ? reason : nil,
                                               info: info)
    }

    /// Destroys the room for everyone (owners only) and forgets it here.
    public func destroyRoom(_ address: String, reason: String? = nil) async throws {
        let muc = try await requireConnection()
        let room = try roomJID(address)
        try await muc.destroy(room, reason: reason)
        rooms[room.description] = nil
        await MainActor.run { _ = status.rooms.removeValue(forKey: room.description) }
        try? await Bookmarks(client: client).retract(room)
        try database.deleteRoom(accountID: account.id, jid: room.description)
    }
}

extension Bookmark {
    var entry: BookmarkEntry {
        BookmarkEntry(jid: room.description, name: name, nick: nick, password: password, autojoin: autojoin,
                      extensions: extensions?.xmlString)
    }
}
