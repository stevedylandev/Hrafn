import Foundation
import XMPPClient
import XMPPCore
import XMPPXML

extension Namespaces {
    /// XEP-0045.
    public static let muc = "http://jabber.org/protocol/muc"
    public static let mucUser = "http://jabber.org/protocol/muc#user"
    public static let mucAdmin = "http://jabber.org/protocol/muc#admin"
    public static let mucOwner = "http://jabber.org/protocol/muc#owner"
    /// XEP-0045 §15.5.3: the `FORM_TYPE` of a room's configuration form.
    public static let mucRoomConfig = "http://jabber.org/protocol/muc#roomconfig"
    /// XEP-0045 §15.5.4: the `FORM_TYPE` of a room's disco#info extension.
    public static let mucRoomInfo = "http://jabber.org/protocol/muc#roominfo"
    /// XEP-0249.
    public static let directInvite = "jabber:x:conference"
    /// XEP-0421.
    public static let occupantID = "urn:xmpp:occupant-id:0"
}

/// XEP-0045 §5.1 roles, most to least privileged.
public enum MUCRole: String, Sendable, Hashable, Comparable, CaseIterable {
    case moderator, participant, visitor, none

    public static func < (lhs: MUCRole, rhs: MUCRole) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// XEP-0045 §5.2 affiliations, most to least privileged.
public enum MUCAffiliation: String, Sendable, Hashable, Comparable, CaseIterable {
    case owner, admin, member, none, outcast

    public static func < (lhs: MUCAffiliation, rhs: MUCAffiliation) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// XEP-0045 §15.6 status codes that change what the client does.
public enum MUCStatus {
    public static let nonAnonymous = 100
    public static let configurationChanged = 104
    public static let selfPresence = 110
    public static let created = 201
    /// The service changed the nickname asked for.
    public static let nickAssigned = 210
    public static let banned = 301
    public static let nickChanged = 303
    public static let kicked = 307
    public static let removedByAffiliationChange = 321
    public static let removedMembersOnly = 322
    public static let shutdown = 332
    /// XEP-0045 §9.3 / XEP-0410: removed because of a technical problem.
    public static let technicalError = 333
}

// MARK: - Presence

/// A presence from a room occupant (XEP-0045 §7.2.3): who, with which role
/// and affiliation, and the status codes that say what happened.
public struct OccupantPresence: Sendable, Hashable {
    public let presence: Presence
    /// The room's bare JID.
    public let room: JID
    public let nick: String
    public let role: MUCRole
    public let affiliation: MUCAffiliation
    /// Only in non-anonymous rooms, or to moderators.
    public let realJID: JID?
    /// XEP-0421. Only meaningful when the room advertises it; otherwise
    /// anyone could set it.
    public let occupantID: String?
    public let statusCodes: Set<Int>
    /// §7.6.3: the new nickname, on the unavailable presence of a rename.
    public let newNick: String?
    /// §9.1.1 / §9.2: why a moderator removed the occupant.
    public let reason: String?

    public init?(_ presence: Presence) {
        guard presence.type == .available || presence.type == .unavailable,
              let from = presence.from, from.localpart != nil, let nick = from.resourcepart,
              let x = presence.element.firstChild(name: "x", namespaceURI: Namespaces.mucUser) else { return nil }
        self.presence = presence
        room = from.bare
        self.nick = nick
        let item = x.firstChild(name: "item", namespaceURI: Namespaces.mucUser)
        role = item?["role"].flatMap(MUCRole.init(rawValue:)) ?? (presence.type == .unavailable ? .none : .participant)
        affiliation = item?["affiliation"].flatMap(MUCAffiliation.init(rawValue:)) ?? .none
        realJID = item?["jid"].flatMap { try? JID($0) }
        newNick = item?["nick"]
        reason = item?.firstChild(name: "reason", namespaceURI: Namespaces.mucUser)?.text
        statusCodes = Set(x.childElements(name: "status", namespaceURI: Namespaces.mucUser).compactMap { $0["code"].flatMap { Int($0) } })
        occupantID = presence.element.firstChild(name: "occupant-id", namespaceURI: Namespaces.occupantID)?["id"]
    }

    public var isAvailable: Bool { presence.type == .available }
    /// §7.2.3: this presence is about us.
    public var isSelf: Bool { statusCodes.contains(MUCStatus.selfPresence) }
}

/// The occupants of one room as the presence stream describes them. A value
/// type, like `PresenceBook`: the owner feeds it and reads it back.
public struct RoomOccupants: Sendable, Equatable {

    public struct Occupant: Sendable, Hashable {
        public var nick: String
        public var role: MUCRole
        public var affiliation: MUCAffiliation
        public var realJID: JID?
        public var occupantID: String?
        public var availability: Availability
        public var status: String?
    }

    /// Why we are no longer in the room.
    public enum Exit: Sendable, Equatable {
        /// We left, or the room let us go without saying why.
        case left
        case kicked(reason: String?)
        case banned(reason: String?)
        /// No longer a member of a members-only room (§9.5, §10.6).
        case removed
        /// §10.9 room destroyed, or §15.6 332 service shutdown.
        case shutdown
        /// XEP-0045 §9.3 (333): a technical problem; rejoining should work.
        case technical
    }

    public enum Change: Sendable, Equatable {
        /// Our self-presence arrived: the join finished.
        case joined(Occupant)
        /// Our role, affiliation or nickname changed.
        case updatedSelf(Occupant)
        case exited(Exit)
        case occupants
        case none
    }

    public private(set) var occupants: [String: Occupant] = [:]
    /// Our nickname, once the room confirms it.
    public private(set) var ownNick: String?
    public private(set) var isJoined = false

    public init() {}

    public var own: Occupant? { ownNick.flatMap { occupants[$0] } }

    public mutating func apply(_ presence: OccupantPresence) -> Change {
        let occupant = Occupant(nick: presence.nick, role: presence.role, affiliation: presence.affiliation,
                                realJID: presence.realJID, occupantID: presence.occupantID,
                                availability: presence.presence.availability, status: presence.presence.status)
        if presence.isAvailable {
            occupants[presence.nick] = occupant
            guard presence.isSelf else { return .occupants }
            // After a rename the old nick's entry went with its unavailable presence.
            ownNick = presence.nick
            if isJoined { return .updatedSelf(occupant) }
            isJoined = true
            return .joined(occupant)
        }

        occupants[presence.nick] = nil
        // §10.9 does not require 110 on the destruction notice (ejabberd
        // leaves it out), so our own nick with <destroy/> counts too.
        let isSelf = presence.isSelf || (presence.nick == ownNick && Self.isDestroyed(presence.presence))
        guard isSelf else { return .occupants }
        if presence.statusCodes.contains(MUCStatus.nickChanged), let newNick = presence.newNick {
            // §7.6.3: the available presence under the new nick follows.
            ownNick = newNick
            return .none
        }
        reset()
        let codes = presence.statusCodes
        if codes.contains(MUCStatus.banned) { return .exited(.banned(reason: presence.reason)) }
        if codes.contains(MUCStatus.kicked) { return .exited(.kicked(reason: presence.reason)) }
        if codes.contains(MUCStatus.removedByAffiliationChange) || codes.contains(MUCStatus.removedMembersOnly) {
            return .exited(.removed)
        }
        if codes.contains(MUCStatus.shutdown) || Self.isDestroyed(presence.presence) { return .exited(.shutdown) }
        if codes.contains(MUCStatus.technicalError) { return .exited(.technical) }
        return .exited(.left)
    }

    /// §10.9: a destroyed room sends our unavailable presence with a
    /// `<destroy/>`, and no status code to say so.
    public static func isDestroyed(_ presence: Presence) -> Bool {
        presence.element.firstChild(name: "x", namespaceURI: Namespaces.mucUser)?
            .firstChild(name: "destroy", namespaceURI: Namespaces.mucUser) != nil
    }

    /// Forgets everyone: we are out of the room (or the session is new).
    public mutating func reset() {
        occupants.removeAll()
        isJoined = false
    }
}

// MARK: - Room information

/// A room's disco#info (XEP-0045 §6.4): its features and the `muc#roominfo`
/// extension form.
public struct RoomInfo: Sendable, Hashable {
    public var name: String?
    public var description: String?
    public var subject: String?
    public var occupantCount: Int?
    public var features: Set<String>

    /// `nil` when the entity is not a text conference room.
    public init?(_ info: DiscoInfo) {
        guard info.identities.contains(where: { $0.category == "conference" }),
              info.supports(Namespaces.muc) else { return nil }
        features = Set(info.features)
        let form = info.forms.first { $0.formType == Namespaces.mucRoomInfo }
        let name = info.identities.first { $0.category == "conference" }?.name
        self.name = name?.isEmpty == false ? name : nil
        description = form?["muc#roominfo_description"]?.first.flatMap { $0.isEmpty ? nil : $0 }
        subject = form?["muc#roominfo_subject"]?.first.flatMap { $0.isEmpty ? nil : $0 }
        occupantCount = form?["muc#roominfo_occupants"]?.first.flatMap { Int($0) }
    }

    public init(features: Set<String>, name: String? = nil) {
        self.features = features
        self.name = name
    }

    public var isMembersOnly: Bool { features.contains("muc_membersonly") }
    /// Everyone may see everyone's real JID.
    public var isNonAnonymous: Bool { features.contains("muc_nonanonymous") }
    public var isPasswordProtected: Bool { features.contains("muc_passwordprotected") }
    public var isPersistent: Bool { features.contains("muc_persistent") }
    public var isPublic: Bool { features.contains("muc_public") }
    public var isModerated: Bool { features.contains("muc_moderated") }
    /// XEP-0313 on the room: history comes from its archive, not from the
    /// join's discussion history.
    public var supportsArchive: Bool { features.contains(Namespaces.mam) }
    /// XEP-0359: the room adds `stanza-id`s and strips forged ones, so they can
    /// be trusted.
    public var supportsStableIDs: Bool { features.contains(Namespaces.stableIDs) }
    /// XEP-0421: likewise for `occupant-id`.
    public var supportsOccupantIDs: Bool { features.contains(Namespaces.occupantID) }

    /// modernxmpp.org's "private group": members only and non-anonymous,
    /// where every message matters. Anything else is a "channel".
    public var isPrivateGroup: Bool { isMembersOnly && isNonAnonymous }
}

// MARK: - Messages

/// A groupchat message, from a room or its archive, with the sender worked
/// out and the ids the room vouches for.
public struct RoomMessage: Sendable, Hashable {

    public enum Source: Sendable, Hashable { case live, archive }

    public let message: Message
    public let source: Source
    /// The room's bare JID.
    public let room: JID
    /// The sender's nickname; `nil` for the room itself (subjects set by the
    /// service, notices).
    public let nick: String?
    /// XEP-0421, only when the room vouches for it.
    public let occupantID: String?
    /// Real JID of the sender, when the archive records it.
    public let realJID: JID?
    public let timestamp: Date?
    /// The room's XEP-0359 `stanza-id` (when it vouches for them) or its
    /// XEP-0313 result id: the deduplication key within the room.
    public let archiveID: String?

    /// A groupchat (or bounced) message from `info`'s room.
    public init?(live message: Message, info: RoomInfo?) {
        guard message.type == .groupchat || message.type == .error, let from = message.from,
              from.localpart != nil else { return nil }
        let room = from.bare
        self.init(message: message, source: .live, room: room, nick: from.resourcepart,
                  occupantID: info?.supportsOccupantIDs == true ? message.occupantID : nil,
                  realJID: message.mucRealJID,
                  timestamp: message.delayStamp,
                  archiveID: info?.supportsStableIDs == true ? message.stanzaID(by: room) : nil)
    }

    /// A result from a room's archive. The archive is the room, so its ids
    /// and occupant ids are its own.
    public init?(archived inbound: InboundMessage, room: JID, info: RoomInfo?) {
        let message = inbound.message
        guard message.type == .groupchat, let from = message.from, from.bare == room else { return nil }
        self.init(message: message, source: .archive, room: room, nick: from.resourcepart,
                  occupantID: info?.supportsOccupantIDs == false ? nil : message.occupantID,
                  realJID: message.mucRealJID, timestamp: inbound.timestamp, archiveID: inbound.archiveID)
    }

    init(message: Message, source: Source, room: JID, nick: String?, occupantID: String?, realJID: JID?,
         timestamp: Date?, archiveID: String?) {
        self.message = message
        self.source = source
        self.room = room
        self.nick = nick
        self.occupantID = occupantID
        self.realJID = realJID
        self.timestamp = timestamp
        self.archiveID = archiveID
    }

    /// The same delivery carrying `message` instead (a decrypted copy).
    public func replacing(_ message: Message) -> RoomMessage {
        RoomMessage(message: message, source: source, room: room, nick: nick, occupantID: occupantID,
                    realJID: realJID, timestamp: timestamp, archiveID: archiveID)
    }

    /// The sender's id: `origin-id`, else `id`.
    public var senderID: String? { message.originID ?? message.id }

    /// §8.1: a subject change (possibly to nothing), which carries no body.
    public var subject: String? {
        guard message.body == nil else { return nil }
        return message.element.firstChild(name: "subject", namespaceURI: Namespaces.client)?.text
    }
}

extension Message {
    /// XEP-0421 `<occupant-id/>`; trust it only from a room that advertises it.
    public var occupantID: String? {
        element.firstChild(name: "occupant-id", namespaceURI: Namespaces.occupantID)?["id"]
    }

    /// The real JID a room (or its archive) attached to a message (§7.2.15).
    var mucRealJID: JID? {
        element.firstChild(name: "x", namespaceURI: Namespaces.mucUser)?
            .firstChild(name: "item", namespaceURI: Namespaces.mucUser)?["jid"].flatMap { try? JID($0) }
    }

    /// A message sent to the room, as Hrafn sends it: `origin-id` equal to
    /// `id` so the reflection can be recognised. No receipt request (XEP-0184
    /// §5.3 rules them out in rooms).
    public static func groupchat(to room: JID, body: String, id: String = StanzaID.make()) -> Message {
        var message = Message(type: .groupchat, id: id, to: room.bare, body: body)
        message.element.addChild(Element(name: "origin-id", namespaceURI: Namespaces.stableIDs, attributes: ["id": id]))
        return message
    }

    /// XEP-0308 in a room: refers to the original's `id`.
    public static func groupchatCorrection(of originalID: String, to room: JID, body: String,
                                           id: String = StanzaID.make()) -> Message {
        var message = groupchat(to: room, body: body, id: id)
        message.element.addChild(Element(name: "replace", namespaceURI: Namespaces.correction,
                                         attributes: ["id": originalID]))
        return message
    }

    /// XEP-0424 §4 in a room: refers to the room's `stanza-id` of the message.
    public static func groupchatRetraction(of stanzaID: String, to room: JID, id: String = StanzaID.make()) -> Message {
        var message = retraction(of: stanzaID, to: room.bare, id: id)
        message.element["type"] = Message.Kind.groupchat.rawValue
        return message
    }

    /// §8.1: changes the room's subject.
    public static func subject(_ subject: String, room: JID) -> Message {
        var message = Message(type: .groupchat, id: StanzaID.make(), to: room.bare)
        message.element.addChild(Element(name: "subject", namespaceURI: Namespaces.client, text: subject))
        return message
    }

    /// XEP-0249 direct invitation.
    public static func directInvite(to contact: JID, room: JID, reason: String? = nil,
                                    password: String? = nil) -> Message {
        var message = Message(type: .normal, id: StanzaID.make(), to: contact)
        var x = Element(name: "x", namespaceURI: Namespaces.directInvite, attributes: ["jid": room.bare.description])
        x["reason"] = reason
        x["password"] = password
        message.element.addChild(x)
        return message
    }

    /// XEP-0045 §7.8.2 mediated invitation, sent through the room — which, in
    /// a members-only room, makes the invitee a member.
    public static func mediatedInvite(to contact: JID, room: JID, reason: String? = nil) -> Message {
        var message = Message(type: .normal, id: StanzaID.make(), to: room.bare)
        var invite = Element(name: "invite", namespaceURI: Namespaces.mucUser, attributes: ["to": contact.description])
        if let reason { invite.addChild(Element(name: "reason", namespaceURI: Namespaces.mucUser, text: reason)) }
        message.element.addChild(Element(name: "x", namespaceURI: Namespaces.mucUser).adding(invite))
        return message
    }
}

/// An invitation to a room, direct (XEP-0249) or mediated by the room
/// (XEP-0045 §7.8.2).
public struct RoomInvite: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case direct, mediated }

    public var room: JID
    /// Who invited us (bare JID), when known.
    public var inviter: JID?
    public var reason: String?
    public var password: String?
    public var kind: Kind

    public init?(_ message: Message) {
        guard message.type != .error, message.type != .groupchat, let from = message.from else { return nil }
        // Mediated first: rooms add a XEP-0249 element to their invitations
        // too, which would otherwise name the room as the inviter.
        if from.isBare, from.localpart != nil,
           let x = message.element.firstChild(name: "x", namespaceURI: Namespaces.mucUser),
           let invite = x.firstChild(name: "invite", namespaceURI: Namespaces.mucUser) {
            room = from
            inviter = invite["from"].flatMap { try? JID($0) }?.bare
            reason = invite.firstChild(name: "reason", namespaceURI: Namespaces.mucUser)?.text.nilIfEmpty
            password = x.firstChild(name: "password", namespaceURI: Namespaces.mucUser)?.text
            kind = .mediated
            return
        }
        guard let x = message.element.firstChild(name: "x", namespaceURI: Namespaces.directInvite),
              let room = x["jid"].flatMap({ try? JID($0) }), room.localpart != nil else { return nil }
        self.room = room.bare
        inviter = from.bare
        reason = x["reason"]?.nilIfEmpty
        password = x["password"]
        kind = .direct
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Joining and administration

/// XEP-0045 multi-user chat, the occupant's and the owner's side.
///
/// Presences and messages from rooms still arrive on the client's `events`;
/// this module only watches presences to finish joins and nickname changes.
public final class MultiUserChat: Sendable {

    /// §7.2.13 discussion history to ask for on joining.
    public enum History: Sendable, Equatable {
        /// None: the archive supplies it (XEP-0313 rooms).
        case none
        case maxStanzas(Int)
        case since(Date)
        /// Whatever the room sends by default.
        case roomDefault
    }

    /// XEP-0410 outcomes.
    public enum SelfPing: Sendable, Equatable {
        case joined
        /// Rejoin.
        case notJoined
        /// The room's server did not answer; try again later.
        case unreachable
    }

    public let client: XMPPClient
    private let waiters = Waiters()

    /// Installs the presence watcher; create one per client.
    public init(client: XMPPClient) async {
        self.client = client
        let waiters = self.waiters
        await client.addPresenceInterceptor { presence in
            waiters.observe(presence)
            return false
        }
    }

    /// Joins `room` as `nick` and waits for the self-presence (§7.2.3), which
    /// may carry a different nick (210) or say the room was just created (201,
    /// and locked until configured — see `createInstantRoom`). A refusal
    /// arrives as a presence error and is thrown as a `StanzaError`: `conflict`
    /// (nick taken), `not-authorized` (password), `registration-required`
    /// (members only), `forbidden` (banned), …
    @discardableResult
    public func join(_ room: JID, nick: String, password: String? = nil, history: History = .none,
                     timeout: Duration = .seconds(30)) async throws -> OccupantPresence {
        let occupantJID = try room.bare.withResource(nick)
        var presence = Presence(to: occupantJID)
        var x = Element(name: "x", namespaceURI: Namespaces.muc)
        switch history {
        case .none: x.addChild(Element(name: "history", namespaceURI: Namespaces.muc, attributes: ["maxstanzas": "0"]))
        case .maxStanzas(let count):
            x.addChild(Element(name: "history", namespaceURI: Namespaces.muc, attributes: ["maxstanzas": String(count)]))
        case .since(let date):
            x.addChild(Element(name: "history", namespaceURI: Namespaces.muc,
                               attributes: ["since": XMPPDateTime.string(from: date)]))
        case .roomDefault: break
        }
        if let password { x.addChild(Element(name: "password", namespaceURI: Namespaces.muc, text: password)) }
        presence.element.addChild(x)
        presence.element.addChild(await client.capsElement)
        return try await waitForSelf(in: room.bare, timeout: timeout) {
            try await self.client.send(presence)
        }
    }

    /// §7.6: a new nickname. Waits for the room's confirmation; a taken nick
    /// is thrown as `conflict`.
    @discardableResult
    public func changeNick(in room: JID, to nick: String, timeout: Duration = .seconds(30)) async throws -> OccupantPresence {
        let presence = Presence(to: try room.bare.withResource(nick))
        return try await waitForSelf(in: room.bare, timeout: timeout) {
            try await self.client.send(presence)
        }
    }

    /// §7.14. Does not wait: the room's answer arrives on `events`.
    public func leave(_ room: JID, nick: String, status: String? = nil) async throws {
        var presence = Presence(type: .unavailable, to: try room.bare.withResource(nick))
        if let status { presence.element.addChild(Element(name: "status", namespaceURI: Namespaces.client, text: status)) }
        try await client.send(presence)
    }

    private func waitForSelf(in room: JID, timeout: Duration,
                             send: () async throws -> Void) async throws -> OccupantPresence {
        let waiter = waiters.add(room)
        defer { waiters.remove(waiter) }
        try await send()
        return try await waiter.value(timeout: timeout)
    }

    /// XEP-0410: are we still in the room? Pings our own occupant JID.
    public func selfPing(_ room: JID, nick: String, timeout: Duration = .seconds(30)) async -> SelfPing {
        guard let occupant = try? room.bare.withResource(nick) else { return .notJoined }
        do {
            _ = try await client.send(IQ(type: .get, to: occupant, payload: Element(name: "ping", namespaceURI: Namespaces.ping)),
                                      timeout: timeout)
            return .joined
        } catch let error as StanzaError {
            switch error.condition {
            // Routed to a client of ours that does not answer pings, or our
            // nick was just changed elsewhere: joined either way (§3).
            case .serviceUnavailable, .featureNotImplemented, .itemNotFound: return .joined
            case .remoteServerNotFound, .remoteServerTimeout: return .unreachable
            default: return .notJoined
            }
        } catch {
            return .unreachable
        }
    }

    public func info(_ room: JID) async throws -> RoomInfo? {
        RoomInfo(try await client.discoInfo(room.bare))
    }

    /// The domain's MUC service, from its disco#items (§6.1).
    public func findService(on domain: JID) async throws -> JID? {
        for item in try await client.discoItems(domain.domain).items where item.node == nil {
            guard let info = try? await client.discoInfo(item.jid) else { continue }
            if info.supports(Namespaces.muc),
               info.identities.contains(where: { $0.category == "conference" && $0.type == "text" }) {
                return item.jid
            }
        }
        return nil
    }

    // MARK: Owner

    /// §10.1.2: accepts the default configuration of a room we just created.
    public func createInstantRoom(_ room: JID) async throws {
        _ = try await client.send(IQ(type: .set, to: room.bare, payload: Element(name: "query", namespaceURI: Namespaces.mucOwner)
            .adding(DataForm(type: .submit).element)))
    }

    /// §10.2: the room's configuration form.
    public func configurationForm(_ room: JID) async throws -> DataForm {
        let reply = try await client.send(IQ(type: .get, to: room.bare,
                                             payload: Element(name: "query", namespaceURI: Namespaces.mucOwner)))
        guard let form = reply.payload?.firstChild(name: "x", namespaceURI: Namespaces.dataForms).flatMap(DataForm.init(element:))
        else { throw StanzaError(.badRequest, text: "no configuration form") }
        return form
    }

    /// Submits a configuration form (from `configurationForm`, edited).
    public func configure(_ room: JID, form: DataForm) async throws {
        _ = try await client.send(IQ(type: .set, to: room.bare, payload: Element(name: "query", namespaceURI: Namespaces.mucOwner)
            .adding(form.submission().element)))
    }

    /// §10.9.
    public func destroy(_ room: JID, reason: String? = nil) async throws {
        var destroy = Element(name: "destroy", namespaceURI: Namespaces.mucOwner)
        if let reason { destroy.addChild(Element(name: "reason", namespaceURI: Namespaces.mucOwner, text: reason)) }
        _ = try await client.send(IQ(type: .set, to: room.bare, payload: Element(name: "query", namespaceURI: Namespaces.mucOwner)
            .adding(destroy)))
    }

    // MARK: Moderation and affiliations

    /// §8.2 kick (`.none`), §8.3/§8.4 voice, §9.6 moderator.
    public func setRole(_ role: MUCRole, nick: String, in room: JID, reason: String? = nil) async throws {
        var item = Element(name: "item", namespaceURI: Namespaces.mucAdmin, attributes: ["nick": nick, "role": role.rawValue])
        if let reason { item.addChild(Element(name: "reason", namespaceURI: Namespaces.mucAdmin, text: reason)) }
        _ = try await client.send(IQ(type: .set, to: room.bare,
                                     payload: Element(name: "query", namespaceURI: Namespaces.mucAdmin).adding(item)))
    }

    /// §9.1 ban (`.outcast`), §9.3 membership, §10.3 owners and admins.
    public func setAffiliation(_ affiliation: MUCAffiliation, of jid: JID, in room: JID, reason: String? = nil) async throws {
        var item = Element(name: "item", namespaceURI: Namespaces.mucAdmin,
                           attributes: ["jid": jid.bare.description, "affiliation": affiliation.rawValue])
        if let reason { item.addChild(Element(name: "reason", namespaceURI: Namespaces.mucAdmin, text: reason)) }
        _ = try await client.send(IQ(type: .set, to: room.bare,
                                     payload: Element(name: "query", namespaceURI: Namespaces.mucAdmin).adding(item)))
    }

    /// §9.5: the JIDs with `affiliation` (members, admins, owners, outcasts).
    public func list(_ affiliation: MUCAffiliation, in room: JID) async throws -> [JID] {
        let item = Element(name: "item", namespaceURI: Namespaces.mucAdmin, attributes: ["affiliation": affiliation.rawValue])
        let reply = try await client.send(IQ(type: .get, to: room.bare,
                                             payload: Element(name: "query", namespaceURI: Namespaces.mucAdmin).adding(item)))
        return reply.payload?.childElements(name: "item", namespaceURI: Namespaces.mucAdmin)
            .compactMap { $0["jid"].flatMap { try? JID($0) } } ?? []
    }

    /// Lock-protected join waiters, fed from the client actor.
    private final class Waiters: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [ObjectIdentifier: (room: JID, waiter: OneShot<OccupantPresence>)] = [:]

        func add(_ room: JID) -> OneShot<OccupantPresence> {
            let waiter = OneShot<OccupantPresence>()
            lock.withLock { entries[ObjectIdentifier(waiter)] = (room, waiter) }
            return waiter
        }

        func remove(_ waiter: OneShot<OccupantPresence>) {
            _ = lock.withLock { entries.removeValue(forKey: ObjectIdentifier(waiter)) }
        }

        func observe(_ presence: Presence) {
            guard let from = presence.from else { return }
            let room = from.bare
            let matching = lock.withLock { entries.values.filter { $0.room == room }.map(\.waiter) }
            guard !matching.isEmpty else { return }
            if presence.type == .error {
                let error = presence.error ?? StanzaError(.undefinedCondition)
                for waiter in matching { waiter.resolve(.failure(error)) }
            } else if let occupant = OccupantPresence(presence), occupant.isSelf, occupant.isAvailable {
                for waiter in matching { waiter.resolve(.success(occupant)) }
            }
        }
    }
}

/// A value that arrives once, awaited with a timeout.
final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?

    func resolve(_ result: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Value, any Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func value(timeout: Duration) async throws -> Value {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resolve(.failure(ClientError.timedOut))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<Value, any Error>? = lock.withLock {
                    if let result { return result }
                    self.continuation = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            self.resolve(.failure(CancellationError()))
        }
    }
}

// MARK: - Private messages (§7.5)

extension Message {
    /// Marks a message to an occupant JID as private to that occupant: the
    /// empty `<x xmlns='muc#user'/>` XEP-0045 §7.5 asks for, which also tells
    /// the recipient's other clients and archive where it came from.
    public func privateThroughRoom() -> Message {
        var copy = self
        copy.element.addChild(Element(name: "x", namespaceURI: Namespaces.mucUser))
        return copy
    }

    /// Carries the §7.5 marker, and is not an invitation (which uses the
    /// same element).
    public var isMarkedRoomPrivate: Bool {
        guard type != .groupchat,
              let x = element.firstChild(name: "x", namespaceURI: Namespaces.mucUser) else { return false }
        return x.firstChild(name: "invite", namespaceURI: Namespaces.mucUser) == nil
            && x.firstChild(name: "decline", namespaceURI: Namespaces.mucUser) == nil
    }
}
