import Foundation
import OMEMOCrypto
import OMEMOProtocol
import HrafnStore
import XMPPCore
import XMPPIM
import XMPPXML

/// Stores inbound one-to-one messages, decrypting OMEMO ones first. Shared by
/// the live session, archive catch-up and the notification service
/// extension, so a message is handled the same whichever way it came.
struct InboundStore: Sendable {
    let database: HrafnDatabase
    let accountID: String
    let omemo: OMEMOEngine?

    struct Stored: Sendable {
        /// The message as its sender wrote it (decrypted, when it was).
        var inbound: InboundMessage
        var events: [MessageEvent]
        /// A session this message started, whose device should be answered
        /// (`OMEMOEngine.keyTransport`).
        var acknowledge: SessionAddress?
    }

    static var undecryptableBody: String {
        String(localized: "This message is encrypted and can’t be read on this device.", bundle: .module)
    }

    func store(_ received: InboundMessage, alreadyRead: Bool = false) async throws -> Stored {
        let inbound = AccountSession.conversation(of: received, database: database, accountID: accountID)
        // Private messages through a room are not OMEMO's (phase 6 is rooms).
        guard let encrypted = inbound.message.omemoEncrypted, inbound.message.type != .groupchat,
              !inbound.peer.isFull else {
            let events = inbound.events(accountID: accountID, alreadyRead: alreadyRead)
            if !events.isEmpty { try database.ingest(events) }
            return Stored(inbound: inbound, events: events)
        }

        if let omemo, let sender = inbound.message.from {
            let result = Result()
            let database = database, accountID = accountID
            do {
                // An OMEMO 2 envelope must name this chat: us, or the contact
                // for a copy of what we sent.
                let decrypted = try await omemo.decrypt(encrypted, from: sender.bare,
                                                        conversations: [omemo.account, inbound.peer]) { decrypted in
                    // Stored before the session moves on (OMEMOEngine.decrypt).
                    let plain = inbound.replacing(inbound.message.decrypted(content: decrypted.content))
                    let events = plain.events(accountID: accountID, alreadyRead: alreadyRead)
                        .map { $0.encrypted(decrypted.senderTrust.isTrusted ? .omemo : .untrustedSender) }
                    if !events.isEmpty { try database.ingest(events) }
                    result.set(Stored(inbound: plain, events: events))
                }
                if var stored = result.value {
                    if decrypted.shouldAcknowledge { stored.acknowledge = decrypted.session }
                    return stored
                }
            } catch {
                // Not for this device, a copy of one already read (its keys
                // are gone), or a broken session: fall through.
            }
        }

        // A key transport message that was not for us is nothing to show.
        guard encrypted.hasPayload else { return Stored(inbound: inbound, events: []) }
        // A placeholder. For a copy of a message already stored, the store's
        // deduplication drops it; a later successful copy replaces it.
        let placeholder = inbound.replacing(inbound.message.decrypted(body: Self.undecryptableBody))
        let events = placeholder.events(accountID: accountID, alreadyRead: alreadyRead)
            .filter { if case .correction = $0.content { false } else { true } }
            .map { $0.encrypted(.undecryptable) }
        if !events.isEmpty { try database.ingest(events) }
        return Stored(inbound: placeholder, events: events)
    }

    /// A group chat message, decrypted first when it is encrypted. `sender`
    /// is the author's real bare JID when known; without it an encrypted
    /// message cannot be decrypted and is stored as a placeholder. Our own
    /// messages from this device are not encrypted for it: their placeholder
    /// only confirms the row already stored (the reflection is the delivery).
    func store(room received: RoomMessage, sender: JID?, me: RoomSelf,
               alreadyRead: Bool = false) async throws -> Stored {
        let inbound = InboundMessage(message: received.message, source: received.source == .live ? .live : .archive,
                                     isOutgoing: received.isOwn(me), peer: received.room,
                                     timestamp: received.timestamp, archiveID: received.archiveID,
                                     counterpart: received.room)
        guard let encrypted = received.message.omemoEncrypted else {
            let events = received.events(accountID: accountID, me: me, alreadyRead: alreadyRead)
            if !events.isEmpty { try database.ingest(events) }
            return Stored(inbound: inbound, events: events)
        }

        if let omemo, let sender {
            let result = Result()
            let database = database, accountID = accountID
            do {
                let decrypted = try await omemo.decrypt(encrypted, from: sender.bare,
                                                        conversations: [received.room]) { decrypted in
                    let plain = received.replacing(received.message.decrypted(content: decrypted.content))
                    let events = plain.events(accountID: accountID, me: me, alreadyRead: alreadyRead)
                        .map { $0.encrypted(decrypted.senderTrust.isTrusted ? .omemo : .untrustedSender) }
                    if !events.isEmpty { try database.ingest(events) }
                    result.set(Stored(inbound: inbound.replacing(plain.message), events: events))
                }
                if var stored = result.value {
                    if decrypted.shouldAcknowledge { stored.acknowledge = decrypted.session }
                    return stored
                }
            } catch {
                // Not for this device (our own reflection), already read, or
                // a broken session: fall through.
            }
        }

        guard encrypted.hasPayload else { return Stored(inbound: inbound, events: []) }
        let placeholder = received.replacing(received.message.decrypted(body: Self.undecryptableBody))
        let events = placeholder.events(accountID: accountID, me: me, alreadyRead: alreadyRead)
            .filter { if case .correction = $0.content { false } else { true } }
            .map { $0.encrypted(.undecryptable) }
        if !events.isEmpty { try database.ingest(events) }
        return Stored(inbound: inbound.replacing(placeholder.message), events: events)
    }

    /// An archive page, in order. Returns the sessions to acknowledge.
    func store(page messages: [InboundMessage], alreadyRead: Bool) async throws -> [SessionAddress] {
        var plain: [MessageEvent] = []
        var acknowledge: [SessionAddress] = []
        for message in messages {
            if message.message.omemoEncrypted == nil || omemo == nil {
                let inbound = AccountSession.conversation(of: message, database: database, accountID: accountID)
                if inbound.message.omemoEncrypted == nil {
                    plain += inbound.events(accountID: accountID, alreadyRead: alreadyRead)
                    continue
                }
            }
            // Keep order: what came before is stored first.
            if !plain.isEmpty { try database.ingest(plain) }
            plain.removeAll()
            if let device = try await store(message, alreadyRead: alreadyRead).acknowledge,
               !acknowledge.contains(device) {
                acknowledge.append(device)
            }
        }
        if !plain.isEmpty { try database.ingest(plain) }
        return acknowledge
    }

    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Stored?
        var value: Stored? { lock.withLock { stored } }
        func set(_ value: Stored) { lock.withLock { stored = value } }
    }
}

extension InboundMessage {
    /// The same delivery, with `message` in place of the one received.
    func replacing(_ message: Message) -> InboundMessage {
        InboundMessage(message: message, source: source, isOutgoing: isOutgoing, peer: peer, timestamp: timestamp,
                       archiveID: archiveID, counterpart: counterpart)
    }
}

extension MessageEvent {
    /// The message's content is marked; receipts and markers stay as they are.
    func encrypted(_ encryption: MessageEncryption) -> MessageEvent {
        var event = self
        switch content {
        case .body, .correction: event.encryption = encryption
        default: break
        }
        return event
    }
}

// MARK: - Session

extension AccountSession {

    /// Whether messages to `peer` go out encrypted now. Throws when that
    /// cannot be decided yet (the contact's device list could not be
    /// fetched): the message waits in the outbox rather than go out in the
    /// clear.
    func encrypts(to peer: String) async throws -> Bool {
        guard let jid = try? JID(peer), jid.isBare else { return false }
        if isRoom(peer) { return try await encryptsInRoom(peer) }
        switch try database.conversationEncryption(accountID: account.id, peer: peer) {
        case .omemo: return true
        case .off: return false
        case nil:
            guard let omemo else { return false }
            return try await !omemo.deviceIDs(of: jid).isEmpty
        }
    }

    /// A room is encrypted only as a private group (members only, real JIDs
    /// visible): OMEMO needs to know who the members are. Automatic means
    /// every member has devices.
    private func encryptsInRoom(_ key: String) async throws -> Bool {
        let choice = try database.conversationEncryption(accountID: account.id, peer: key)
        if choice == .off { return false }
        let stored = try database.fetchRoom(accountID: account.id, jid: key)
        let isPrivateGroup = rooms[key]?.info?.isPrivateGroup ?? stored?.isPrivateGroup ?? false
        let members = roomMembers(key)
        if choice == .omemo {
            guard isPrivateGroup else { throw RoomEncryptionError.notPrivateGroup }
            return true
        }
        guard isPrivateGroup, let omemo, !members.isEmpty else { return false }
        for member in members {
            if try await omemo.deviceIDs(of: member).isEmpty { return false }
        }
        return true
    }

    /// Everyone to encrypt a room message for, other than us.
    func roomMembers(_ key: String) -> [JID] {
        Array(rooms[key]?.members ?? []).filter { $0 != jid }.sorted { $0.description < $1.description }
    }

    /// `message` as it goes to `peer`: its body encrypted when the
    /// conversation is. A message without a body (a retraction, a reaction)
    /// goes as it is. In a room it is encrypted for every member, and the
    /// XEP-0372 mentions are left out: they would name in the clear whom an
    /// encrypted message is about.
    func sealed(_ message: Message, to peer: String) async throws -> (message: Message, encrypted: Bool) {
        guard let body = message.body, try await encrypts(to: peer) else { return (message, false) }
        guard let omemo, let jid = try? JID(peer) else { throw OMEMOProtocolError.notSetUp }
        if isRoom(peer) {
            let members = roomMembers(peer)
            guard !members.isEmpty else { throw RoomEncryptionError.noMembers }
            let result = try await omemo.encrypt(body, to: members, conversation: jid)
            var plain = message
            plain.element.removeChildren(name: "reference", namespaceURI: Namespaces.references)
            return (plain.encrypted(with: result.message), true)
        }
        let result = try await omemo.encrypt(body, to: [jid])
        return (message.encrypted(with: result.message), true)
    }

    /// Sends a stored chat message, encrypted if its conversation is.
    /// Returns whether it went out. A message that can never be encrypted
    /// (no usable devices) fails with a reason; one that cannot be encrypted
    /// yet stays pending.
    func transmit(_ message: Message, row: StoredMessage) async -> Bool {
        guard let id = row.id else { return false }
        let sealed: (message: Message, encrypted: Bool)
        do {
            sealed = try await self.sealed(message, to: row.peer)
        } catch let error as OMEMOProtocolError {
            switch error {
            case .noDevices, .noTrustedDevices, .notSetUp:
                try? database.setState(messageID: id, .failed, errorText: Self.describe(error, room: isRoom(row.peer)))
            default:
                break
            }
            return false
        } catch let error as RoomEncryptionError {
            try? database.setState(messageID: id, .failed, errorText: error.description)
            return false
        } catch {
            return false
        }
        guard (try? await client.send(sealed.message)) != nil else { return false }
        try? database.markSent(messageID: id)
        if sealed.encrypted { try? database.setEncryption(messageID: id, .omemo) }
        return true
    }

    /// Answers devices that started a session, so their next messages are
    /// ordinary ones (XEP-0384 0.3 §4.5 key transport, 0.8 §6.1 empty
    /// message), in the version the session speaks.
    func acknowledge(_ sessions: [SessionAddress]) async {
        guard let omemo else { return }
        for session in sessions {
            guard let encrypted = try? await omemo.keyTransport(to: session) else { continue }
            try? await client.send(Message(type: .chat, to: session.device.jid).encrypted(with: encrypted))
        }
    }

    /// Removes our other devices from the account's device list (see
    /// `OMEMOEngine.removeOwnDevices`).
    public func removeOwnDevices(_ deviceIDs: [UInt32]) async throws {
        guard let omemo, await client.jid != nil else { throw AccountError.notConnected }
        try await omemo.removeOwnDevices(Set(deviceIDs))
    }

    /// This device's id once OMEMO is set up and the device is in the
    /// account's published list.
    func publishedOwnDevice() async -> UInt32? {
        guard let omemo, let id = await omemo.deviceID,
              (try? await omemo.refreshDeviceIDs(of: jid))?.contains(id) == true else { return nil }
        return id
    }

    static func describe(_ error: OMEMOProtocolError, room: Bool = false) -> String {
        switch error {
        case .noDevices(let member) where room:
            String(localized: "\(member.description) has no devices that can receive encrypted messages", bundle: .module)
        case .noTrustedDevices(let member) where room:
            String(localized: "None of \(member.description)’s devices is trusted. Check their devices in the group’s details.",
                   bundle: .module)
        case .noDevices:
            String(localized: "This contact has no devices that can receive encrypted messages", bundle: .module)
        case .noTrustedDevices:
            String(localized: "None of this contact’s devices is trusted. Check their devices in the contact’s details.",
                   bundle: .module)
        default:
            String(localized: "Encryption isn’t available for this account", bundle: .module)
        }
    }
}

// MARK: - Rooms

extension AccountSession {

    /// Private groups: reads who the members are (members may read the lists
    /// in members-only rooms; what is refused is covered by the occupants),
    /// and refreshes their device lists, which are not pushed to us for
    /// people outside the roster.
    func loadMembers(_ key: String) async {
        guard let muc, let runtime = rooms[key], runtime.info?.isPrivateGroup == true else { return }
        var members = runtime.members
        for affiliation in [MUCAffiliation.owner, .admin, .member] {
            if let listed = try? await muc.list(affiliation, in: runtime.jid) { members.formUnion(listed.map(\.bare)) }
        }
        rooms[key]?.members.formUnion(members)
        guard let omemo else { return }
        let others = roomMembers(key)
        await withTaskGroup(of: Void.self) { group in
            for member in others { group.addTask { _ = try? await omemo.refreshDeviceIDs(of: member) } }
        }
    }

    /// Keeps the member list and the real JIDs in step with the room's
    /// presence.
    func noteMember(_ occupant: OccupantPresence, in key: String) {
        guard rooms[key] != nil, let real = occupant.realJID?.bare else { return }
        rooms[key]?.realJIDs["nick:" + occupant.nick] = real
        if let occupantID = occupant.occupantID, rooms[key]?.info?.supportsOccupantIDs == true {
            rooms[key]?.realJIDs["id:" + occupantID] = real
        }
        switch occupant.affiliation {
        case .owner, .admin, .member:
            rooms[key]?.members.insert(real)
        case .outcast:
            rooms[key]?.members.remove(real)
        case .none:
            // Membership revoked (§9.4), not merely a visitor leaving.
            if occupant.statusCodes.contains(321) || occupant.isAvailable { rooms[key]?.members.remove(real) }
        }
    }

    /// Who wrote a room message, as a real bare JID: us, the room's word
    /// (occupant id, the archive's `<item jid=''/>`), the device id among
    /// the members' devices, and last the nick's current holder.
    func realSender(of message: RoomMessage) async -> JID? {
        let key = message.room.description
        let runtime = rooms[key]
        if message.isOwn(RoomSelf(account: jid, nick: runtime?.nick, occupantID: runtime?.ownOccupantID)) { return jid }
        if let occupantID = message.occupantID, let real = runtime?.realJIDs["id:" + occupantID] { return real }
        if let real = message.realJID { return real.bare }
        if let omemo, let sid = message.message.omemoEncrypted?.senderDeviceID,
           let owner = await omemo.owner(ofDevice: sid, among: Array(runtime?.members ?? [])) {
            return owner
        }
        if let nick = message.nick { return runtime?.realJIDs["nick:" + nick] }
        return nil
    }
}

/// Why a room message cannot be encrypted.
enum RoomEncryptionError: Error, Sendable, CustomStringConvertible {
    /// Encryption is on, but the room is a channel: its members' addresses
    /// are hidden, so there is no one to encrypt for.
    case notPrivateGroup
    /// The member list could not be read yet.
    case noMembers

    var description: String {
        switch self {
        case .notPrivateGroup:
            String(localized: "Only private groups (members only, addresses visible) can be encrypted", bundle: .module)
        case .noMembers:
            String(localized: "The group’s members aren’t known yet", bundle: .module)
        }
    }
}
