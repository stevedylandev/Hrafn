import Foundation
import GRDB

/// One XMPP account on this device. The password lives in the keychain, not here.
public struct Account: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "account"

    public var id: String
    /// Bare JID.
    public var jid: String
    /// Manual connection settings; `nil` host means "use DNS SRV".
    public var host: String?
    public var port: Int?
    public var directTLS: Bool
    public var enabled: Bool
    /// RFC 6121 §2.6 roster version cached with the roster below.
    public var rosterVersion: String?
    /// SHA-256 of a server certificate the user chose to trust although the
    /// system does not (a self-signed or private-CA server), hex-encoded.
    public var trustedFingerprint: String?
    public var createdAt: Date
    /// What this account tells contacts about us: an RFC 6121 availability
    /// (`ContactAvailability` raw value; `nil` is online) and status message.
    public var availability: String?
    public var statusMessage: String?

    public init(id: String = UUID().uuidString, jid: String, host: String? = nil, port: Int? = nil,
                directTLS: Bool = true, enabled: Bool = true, rosterVersion: String? = nil,
                trustedFingerprint: String? = nil, createdAt: Date = Date(),
                availability: String? = nil, statusMessage: String? = nil) {
        self.id = id
        self.jid = jid
        self.host = host
        self.port = port
        self.directTLS = directTLS
        self.enabled = enabled
        self.rosterVersion = rosterVersion
        self.trustedFingerprint = trustedFingerprint
        self.createdAt = createdAt
        self.availability = availability
        self.statusMessage = statusMessage
    }
}

/// A roster entry, plus inbound subscription requests for JIDs not (yet) in it.
public struct Contact: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "contact"

    public enum Subscription: String, Codable, Sendable, Hashable {
        case none, to, from, both
    }

    public var accountID: String
    public var jid: String
    public var name: String?
    public var subscription: Subscription
    /// We asked to see their presence and they have not answered.
    public var pendingOut: Bool
    /// They asked to see ours and we have not answered.
    public var pendingIn: Bool
    /// In the server roster. `false` for a stranger's subscription request.
    public var inRoster: Bool
    public var groups: [String]

    public init(accountID: String, jid: String, name: String? = nil, subscription: Subscription = .none,
                pendingOut: Bool = false, pendingIn: Bool = false, inRoster: Bool = true, groups: [String] = []) {
        self.accountID = accountID
        self.jid = jid
        self.name = name
        self.subscription = subscription
        self.pendingOut = pendingOut
        self.pendingIn = pendingIn
        self.inRoster = inRoster
        self.groups = groups
    }

    public var displayName: String { name ?? jid }
}

public struct BlockedJID: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "blocked"
    public var accountID: String
    public var jid: String

    public init(accountID: String, jid: String) {
        self.accountID = accountID
        self.jid = jid
    }
}

public struct Conversation: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversation"

    public var accountID: String
    /// Bare JID of the other party.
    public var peer: String
    public var lastActivity: Date
    /// Incoming messages not yet read, kept in step with the message table.
    public var unreadCount: Int
    public var draft: String?
    /// No notifications for this conversation.
    public var muted: Bool
    /// XEP-0490: the archive id of the last message displayed on any of our
    /// devices, as published or last seen in PEP.
    public var syncedDisplayedID: String?
    /// `syncedDisplayedID` names a message not stored here yet; it is marked
    /// read, with everything before it, when it arrives.
    public var syncedDisplayedPending: Bool
    /// End-to-end encryption: `nil` until decided (encrypted as soon as the
    /// contact has OMEMO devices), then the user's or the first encrypted
    /// message's choice.
    public var encryption: ConversationEncryption?

    public init(accountID: String, peer: String, lastActivity: Date = Date(), unreadCount: Int = 0, draft: String? = nil,
                muted: Bool = false, syncedDisplayedID: String? = nil, syncedDisplayedPending: Bool = false,
                encryption: ConversationEncryption? = nil) {
        self.accountID = accountID
        self.peer = peer
        self.lastActivity = lastActivity
        self.unreadCount = unreadCount
        self.draft = draft
        self.muted = muted
        self.syncedDisplayedID = syncedDisplayedID
        self.syncedDisplayedPending = syncedDisplayedPending
        self.encryption = encryption
    }
}

public enum ConversationEncryption: String, Codable, Sendable, Hashable {
    /// OMEMO: messages are never sent in the clear.
    case omemo
    /// The user turned encryption off for this conversation.
    case off
}

/// How a message travelled.
public enum MessageEncryption: String, Codable, Sendable, Hashable {
    /// OMEMO, decrypted (incoming) or encrypted when sent (outgoing).
    case omemo
    /// OMEMO, but not for this device or not decryptable: the body is a
    /// placeholder.
    case undecryptable
    /// OMEMO, decrypted, from a device the user has not trusted (new since
    /// they verified the contact, changed, or distrusted).
    case untrustedSender
}

public enum MessageState: String, Codable, Sendable, Hashable {
    // Outgoing
    /// Not yet handed to a connection; the outbox resends it.
    case pending
    /// Handed to the connection (and so to XEP-0198 for delivery to the server).
    case sent
    /// XEP-0184 receipt from the recipient.
    case delivered
    /// XEP-0333 displayed marker from the recipient.
    case displayed
    /// Bounced with a stanza error.
    case failed
    // Incoming
    case received
    /// Read here or on another of our devices.
    case read
}

public struct StoredMessage: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "message"

    public var id: Int64?
    public var accountID: String
    public var peer: String
    public var isOutgoing: Bool
    public var body: String
    /// Sort key: the server's timestamp when known, else when we saw it.
    public var timestamp: Date
    /// The sender's id for the message (XEP-0359 origin-id, else `id`) —
    /// what receipts, markers, corrections and retractions refer to.
    public var originID: String?
    /// The stanza `id` attribute, which bounces refer to.
    public var stanzaID: String?
    /// Id in the account's archive (XEP-0359 stanza-id / XEP-0313 result id).
    public var archiveID: String?
    public var state: MessageState
    /// XEP-0308: replaced at least once; `body` is the latest version.
    public var editedAt: Date?
    /// XEP-0424: retracted; `body` is emptied.
    public var isRetracted: Bool
    /// The sender asked for XEP-0333 markers.
    public var isMarkable: Bool
    public var errorText: String?
    /// Announced to the user, or never needed to be (outgoing, history,
    /// arrived while the app was on screen).
    public var notified: Bool
    /// Group chat: the sender's nickname in the room.
    public var senderNick: String?
    /// Group chat: the sender's XEP-0421 occupant id, when the room vouches
    /// for one. Stable across nick changes, so it decides who may edit.
    public var occupantID: String?
    /// Group chat: the sender's real bare JID, when the room reveals it.
    public var senderJID: String?
    /// Group chat: the body mentions our nickname.
    public var mentionsMe: Bool
    /// A shared file (XEP-0066/XEP-0363); the body is its URL once known.
    public var attachment: Attachment?
    /// XEP-0461: the id of the message this one answers (see `referenceID`).
    public var replyToID: String?
    /// XEP-0461: who wrote that message, as the sender named them.
    public var replyTo: String?
    /// The quoted text the sender put in front of the reply (its XEP-0428
    /// fallback, without the "> "), shown when the original is not stored.
    public var replyQuote: String?
    /// XEP-0393 §6: show the body without styling.
    public var isUnstyled: Bool
    /// XEP-0425: a room moderator removed it (also `isRetracted`). Their
    /// nickname, or empty when the room did not say.
    public var moderatedBy: String?
    public var moderationReason: String?
    /// End-to-end encryption; `nil` for a message sent in the clear.
    public var encryption: MessageEncryption?

    public init(id: Int64? = nil, accountID: String, peer: String, isOutgoing: Bool, body: String, timestamp: Date,
                originID: String? = nil, stanzaID: String? = nil, archiveID: String? = nil,
                state: MessageState, editedAt: Date? = nil, isRetracted: Bool = false, isMarkable: Bool = false,
                errorText: String? = nil, notified: Bool = true, senderNick: String? = nil, occupantID: String? = nil,
                senderJID: String? = nil, mentionsMe: Bool = false, attachment: Attachment? = nil,
                reply: ReplyReference? = nil, isUnstyled: Bool = false, encryption: MessageEncryption? = nil) {
        self.id = id
        self.accountID = accountID
        self.peer = peer
        self.isOutgoing = isOutgoing
        self.body = body
        self.timestamp = timestamp
        self.originID = originID
        self.stanzaID = stanzaID
        self.archiveID = archiveID
        self.state = state
        self.editedAt = editedAt
        self.isRetracted = isRetracted
        self.isMarkable = isMarkable
        self.errorText = errorText
        self.notified = notified
        self.senderNick = senderNick
        self.occupantID = occupantID
        self.senderJID = senderJID
        self.mentionsMe = mentionsMe
        self.attachment = attachment
        replyToID = reply?.id
        replyTo = reply?.to
        replyQuote = reply?.quote
        self.isUnstyled = isUnstyled
        self.encryption = encryption
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// The id others use to refer to this message in reactions and replies:
    /// the sender's id in a chat, the room's id in a group chat (XEP-0444
    /// §4, XEP-0461 §3).
    public func referenceID(inRoom: Bool) -> String? {
        inRoom ? archiveID : (originID ?? stanzaID)
    }

    public var reply: ReplyReference? {
        replyToID.map { ReplyReference(id: $0, to: replyTo, quote: replyQuote) }
    }

    /// What a retracted message shows in its place: who took it down if a
    /// moderator did (XEP-0425), and why.
    public var retractionNotice: String {
        guard let moderator = moderatedBy else { return String(localized: "Message retracted", bundle: .module) }
        let removed = moderator.isEmpty ? String(localized: "Removed by a moderator", bundle: .module)
                                        : String(localized: "Removed by \(moderator)", bundle: .module)
        guard let reason = moderationReason else { return removed }
        return "\(removed): \(reason)"
    }

    /// What a notification or the chat list shows for this message.
    public var preview: String {
        if moderatedBy != nil { return String(localized: "Removed by a moderator", bundle: .module) }
        if isRetracted { return String(localized: "Message retracted", bundle: .module) }
        guard let attachment else { return body }
        switch attachment.kind {
        case .image: return String(localized: "📷 Photo", bundle: .module)
        case .video: return String(localized: "🎥 Video", bundle: .module)
        case .audio: return attachment.isVoiceMessage ? String(localized: "🎤 Voice message", bundle: .module) : String(localized: "🎵 \(attachment.fileName)", bundle: .module)
        case .file: return String(localized: "📎 \(attachment.fileName)", bundle: .module)
        }
    }
}

/// XEP-0461: what a message answers.
public struct ReplyReference: Sendable, Hashable {
    /// The original's id: its sender's id in a chat, the room's in a group chat.
    public var id: String
    /// The original's author, as a JID (an occupant JID in a room).
    public var to: String?
    /// The quoted original, from the reply's fallback.
    public var quote: String?

    public init(id: String, to: String? = nil, quote: String? = nil) {
        self.id = id
        self.to = to
        self.quote = quote
    }
}

/// XEP-0444: one sender's current reactions to one message. An empty set is
/// kept, so an older set arriving later (from an archive) cannot bring back
/// reactions that were taken away.
public struct Reaction: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "reaction"

    public var accountID: String
    public var peer: String
    /// The message's `referenceID`.
    public var targetID: String
    /// Who reacted: "" for us; the contact's bare JID in a chat; the
    /// occupant id, else the nick, in a room.
    public var sender: String
    public var emojis: [String]
    /// When the sender last changed their set; older sets are ignored.
    public var timestamp: Date
    /// Group chat: the sender's nickname, for showing who reacted.
    public var senderNick: String?

    public init(accountID: String, peer: String, targetID: String, sender: String, emojis: [String],
                timestamp: Date, senderNick: String? = nil) {
        self.accountID = accountID
        self.peer = peer
        self.targetID = targetID
        self.sender = sender
        self.emojis = emojis
        self.timestamp = timestamp
        self.senderNick = senderNick
    }

    public var isOwn: Bool { sender.isEmpty }
}

/// One emoji under a message: how many reacted with it, and whether we did.
public struct ReactionCount: Sendable, Hashable, Identifiable {
    public var emoji: String
    public var count: Int
    public var includesMe: Bool
    /// Group chat: who, by nickname.
    public var senders: [String]

    public var id: String { emoji }

    /// Per message (by `targetID`): each emoji once, the most used first,
    /// then the earliest.
    public static func summaries(_ reactions: [Reaction]) -> [String: [ReactionCount]] {
        var result: [String: [ReactionCount]] = [:]
        for (target, group) in Dictionary(grouping: reactions, by: \.targetID) {
            var counts: [ReactionCount] = []
            for reaction in group.sorted(by: { $0.timestamp < $1.timestamp }) {
                for emoji in reaction.emojis {
                    if let index = counts.firstIndex(where: { $0.emoji == emoji }) {
                        counts[index].count += 1
                        counts[index].includesMe = counts[index].includesMe || reaction.isOwn
                        if let nick = reaction.senderNick { counts[index].senders.append(nick) }
                    } else {
                        counts.append(ReactionCount(emoji: emoji, count: 1, includesMe: reaction.isOwn,
                                                    senders: reaction.senderNick.map { [$0] } ?? []))
                    }
                }
            }
            guard !counts.isEmpty else { continue }
            // A stable sort keeps first-used order among equal counts.
            result[target] = counts.enumerated()
                .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count
                          : $0.offset < $1.offset }
                .map(\.element)
        }
        return result
    }
}

/// A correction or retraction, kept so it is applied once and so it can wait
/// for a target that has not arrived yet (archives are not always in order, and
/// ejabberd deletes a retracted message from the archive altogether).
public struct MessageEdit: Codable, Sendable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "messageEdit"

    /// `moderation` (XEP-0425) comes from the room, not the author: it
    /// applies to any occupant's message, `senderNick` names the moderator
    /// and `body` holds the reason.
    public enum Kind: String, Codable, Sendable { case correction, retraction, moderation }

    public var id: Int64?
    public var accountID: String
    public var peer: String
    public var isOutgoing: Bool
    public var kind: Kind
    /// The `originID` of the message it applies to.
    public var targetID: String
    public var body: String?
    public var timestamp: Date
    /// The edit's own ids, for deduplication.
    public var senderID: String?
    public var archiveID: String?
    public var applied: Bool
    /// Group chat: who sent the edit.
    public var senderNick: String?
    public var occupantID: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// How far catch-up has read an archive (the account's own, or a room's later).
public struct ArchiveCursor: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "archiveCursor"
    public var accountID: String
    public var archive: String
    public var lastID: String
    public var updatedAt: Date

    public init(accountID: String, archive: String, lastID: String, updatedAt: Date = Date()) {
        self.accountID = accountID
        self.archive = archive
        self.lastID = lastID
        self.updatedAt = updatedAt
    }
}

/// Which of a room's messages are announced.
public enum RoomNotify: String, Codable, Sendable, Hashable, CaseIterable {
    case always, mentions, never
}

/// A group chat: its bookmark (XEP-0402) as the server has it, plus what only
/// this device keeps — the subject, notification level and what the room
/// told us about itself.
public struct Room: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "room"

    public var accountID: String
    /// The room's bare JID.
    public var jid: String
    public var name: String?
    /// The nickname to join with; `nil` uses the account's localpart.
    public var nick: String?
    public var password: String?
    /// Join on every session (the bookmark's `autojoin`).
    public var autojoin: Bool
    /// In the account's Bookmarks 2 node.
    public var bookmarked: Bool
    /// Other clients' `<extensions/>` in the bookmark, as XML, published back
    /// unchanged.
    public var bookmarkExtensions: String?
    public var subject: String?
    /// `nil` follows the default for the kind of room.
    public var notify: RoomNotify?
    public var isMembersOnly: Bool
    public var isNonAnonymous: Bool
    /// Our XEP-0421 occupant id here: stable for our account, so it tells our
    /// own messages apart in the archive whatever nick we used.
    public var ownOccupantID: String?

    public init(accountID: String, jid: String, name: String? = nil, nick: String? = nil, password: String? = nil,
                autojoin: Bool = true, bookmarked: Bool = false, bookmarkExtensions: String? = nil,
                subject: String? = nil, notify: RoomNotify? = nil, isMembersOnly: Bool = false,
                isNonAnonymous: Bool = false, ownOccupantID: String? = nil) {
        self.accountID = accountID
        self.jid = jid
        self.name = name
        self.nick = nick
        self.password = password
        self.autojoin = autojoin
        self.bookmarked = bookmarked
        self.bookmarkExtensions = bookmarkExtensions
        self.subject = subject
        self.notify = notify
        self.isMembersOnly = isMembersOnly
        self.isNonAnonymous = isNonAnonymous
        self.ownOccupantID = ownOccupantID
    }

    public var displayName: String { name ?? jid.split(separator: "@").first.map(String.init) ?? jid }

    /// modernxmpp.org: a private group (members only, real JIDs visible) is
    /// like a one-to-one chat and announces everything; a channel only
    /// mentions.
    public var isPrivateGroup: Bool { isMembersOnly && isNonAnonymous }
    public var effectiveNotify: RoomNotify { notify ?? (isPrivateGroup ? .always : .mentions) }
}

/// An invitation to a room, waiting for the user to accept or decline.
public struct RoomInvitation: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "roomInvite"

    public var accountID: String
    public var room: String
    public var inviter: String?
    public var reason: String?
    public var password: String?
    public var receivedAt: Date

    public init(accountID: String, room: String, inviter: String?, reason: String?, password: String?,
                receivedAt: Date = Date()) {
        self.accountID = accountID
        self.room = room
        self.inviter = inviter
        self.reason = reason
        self.password = password
        self.receivedAt = receivedAt
    }

    public var id: String { accountID + "|" + room }
}

/// A private conversation with a room occupant (XEP-0045 §7.5) has the
/// occupant JID, `room@service/nick`, as its peer. Every other peer is a bare
/// JID, so a resource is what tells them apart.
public enum RoomPrivate {
    /// The room and nickname of a private conversation's peer, else `nil`.
    public static func split(_ peer: String) -> (room: String, nick: String)? {
        guard let slash = peer.firstIndex(of: "/") else { return nil }
        let nick = String(peer[peer.index(after: slash)...])
        return nick.isEmpty ? nil : (String(peer[..<slash]), nick)
    }

    /// "nick in Room", for titles.
    public static func title(nick: String, room: Room?, roomJID: String) -> String {
        let name = room?.displayName ?? roomJID.split(separator: "@").first.map(String.init) ?? roomJID
        return String(localized: "\(nick) in \(name)", bundle: .module)
    }
}

/// A conversation row for the list: the conversation, who (or which room) it
/// is with, and its newest message.
public struct ConversationSummary: Sendable, Hashable, Identifiable {
    public var conversation: Conversation
    public var contact: Contact?
    public var room: Room?
    public var lastMessage: StoredMessage?
    /// The peer's avatar and nickname, when known.
    public var profile: Profile?
    /// For a private conversation with an occupant, the room it goes through.
    public var viaRoom: Room?

    public init(conversation: Conversation, contact: Contact?, room: Room? = nil, lastMessage: StoredMessage?,
                profile: Profile? = nil, viaRoom: Room? = nil) {
        self.conversation = conversation
        self.contact = contact
        self.room = room
        self.lastMessage = lastMessage
        self.profile = profile
        self.viaRoom = viaRoom
    }

    public var id: String { conversation.accountID + "|" + conversation.peer }
    public var isRoom: Bool { room != nil }
    public var title: String {
        if let (roomJID, nick) = RoomPrivate.split(conversation.peer) {
            return RoomPrivate.title(nick: nick, room: viaRoom, roomJID: roomJID)
        }
        return room?.displayName ?? contact?.name ?? profile?.nickname ?? conversation.peer
    }
}
