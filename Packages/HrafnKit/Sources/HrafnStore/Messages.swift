import Foundation
import GRDB

/// Something that happened in a conversation, from whichever path it arrived
/// by — live, as a carbon, or from the archive. The store deduplicates, so the
/// same event may be ingested any number of times.
public struct MessageEvent: Sendable, Hashable {

    /// Who sent a group chat message.
    public struct RoomSender: Sendable, Hashable {
        public var nick: String?
        /// XEP-0421, when the room vouches for it.
        public var occupantID: String?
        /// Real bare JID, when the room reveals it.
        public var realJID: String?

        public init(nick: String?, occupantID: String? = nil, realJID: String? = nil) {
            self.nick = nick
            self.occupantID = occupantID
            self.realJID = realJID
        }
    }

    public enum Content: Sendable, Hashable {
        case body(String, markable: Bool)
        /// XEP-0308: replaces the body of the message whose origin id is `of`.
        case correction(of: String, body: String)
        /// XEP-0424.
        case retraction(of: String)
        /// XEP-0425: the room took down the message with this room id, on a
        /// moderator's word. Applies whoever wrote it.
        case moderation(of: String, by: String?, reason: String?)
        /// XEP-0444: the sender's whole set of reactions to the message whose
        /// reference id is `to`, replacing their earlier set.
        case reactions(to: String, [String])
        /// XEP-0184, for the message with this origin or stanza id.
        case receipt(for: String)
        /// XEP-0333: everything up to and including this message was seen.
        case displayed(upTo: String)
        /// A bounce for the stanza with this id.
        case error(stanzaID: String, text: String?)
    }

    public var accountID: String
    public var peer: String
    /// Sent by this account (from this or another device).
    public var isOutgoing: Bool
    public var content: Content
    /// The sender's id for this message (origin-id, else id).
    public var senderID: String?
    /// The stanza `id` attribute.
    public var stanzaID: String?
    public var archiveID: String?
    public var timestamp: Date
    /// Store an incoming body as already read (history fetched on first login).
    public var alreadyRead: Bool
    /// Group chat: the sender in the room; `nil` in a one-to-one chat.
    public var sender: RoomSender?
    /// Group chat: the body mentions our nickname.
    public var mentionsMe: Bool
    /// The body shares a file at this URL.
    public var attachment: Attachment?
    /// XEP-0461: the body answers this message.
    public var reply: ReplyReference?
    /// XEP-0393 §6: not to be styled.
    public var unstyled: Bool
    /// End-to-end encryption of the message (not of receipts or markers).
    public var encryption: MessageEncryption?

    public init(accountID: String, peer: String, isOutgoing: Bool, content: Content, senderID: String? = nil,
                stanzaID: String? = nil, archiveID: String? = nil, timestamp: Date = Date(), alreadyRead: Bool = false,
                sender: RoomSender? = nil, mentionsMe: Bool = false, attachment: Attachment? = nil,
                reply: ReplyReference? = nil, unstyled: Bool = false, encryption: MessageEncryption? = nil) {
        self.accountID = accountID
        self.peer = peer
        self.isOutgoing = isOutgoing
        self.content = content
        self.senderID = senderID
        self.stanzaID = stanzaID
        self.archiveID = archiveID
        self.timestamp = timestamp
        self.alreadyRead = alreadyRead
        self.sender = sender
        self.mentionsMe = mentionsMe
        self.attachment = attachment
        self.reply = reply
        self.unstyled = unstyled
        self.encryption = encryption
    }
}

public enum IngestResult: Sendable, Equatable {
    /// A new message row.
    case inserted(Int64)
    /// Another copy of a message already stored; its ids were filled in.
    case merged(Int64)
    /// Already stored, nothing changed.
    case duplicate
    /// A correction or retraction applied to this row.
    case edited(Int64)
    /// A correction or retraction whose target is not here yet.
    case deferred
    /// Receipts, markers, bounces: this many rows changed state.
    case updated(Int)
}

extension HrafnDatabase {

    @discardableResult
    public func ingest(_ event: MessageEvent) throws -> IngestResult {
        try writer.write { db in try Self.ingest(event, db) }
    }

    /// Ingests a batch in one transaction — an archive page.
    @discardableResult
    public func ingest(_ events: [MessageEvent]) throws -> [IngestResult] {
        try writer.write { db in try events.map { try Self.ingest($0, db) } }
    }

    static func ingest(_ event: MessageEvent, _ db: Database) throws -> IngestResult {
        switch event.content {
        case .body(let body, let markable):
            return try ingestBody(event, body: body, markable: markable, db)
        case .correction(let target, let body):
            return try ingestEdit(event, kind: .correction, target: target, body: body, db)
        case .retraction(let target):
            return try ingestEdit(event, kind: .retraction, target: target, body: nil, db)
        case .moderation(let target, let moderator, let reason):
            return try ingestModeration(event, target: target, moderator: moderator, reason: reason, db)
        case .reactions(let target, let emojis):
            return try ingestReactions(event, target: target, emojis: emojis, db)
        case .receipt(let id):
            // A receipt we sent from another device says nothing about ours.
            guard !event.isOutgoing else { return .updated(0) }
            try db.execute(sql: """
                UPDATE message SET state = 'delivered'
                WHERE accountID = ? AND peer = ? AND isOutgoing AND state IN ('pending', 'sent')
                  AND (originID = ? OR stanzaID = ?)
                """, arguments: [event.accountID, event.peer, id, id])
            return .updated(db.changesCount)
        case .displayed(let id):
            if event.isOutgoing {
                // Our other device showed their messages: read here too.
                guard let target = try message(event.accountID, event.peer, isOutgoing: false, id: id, db) else {
                    return .updated(0)
                }
                let changed = try markRead(event.accountID, event.peer, upTo: target.timestamp, db)
                return .updated(changed)
            }
            guard let target = try message(event.accountID, event.peer, isOutgoing: true, id: id, db) else {
                return .updated(0)
            }
            try db.execute(sql: """
                UPDATE message SET state = 'displayed'
                WHERE accountID = ? AND peer = ? AND isOutgoing AND state IN ('sent', 'delivered') AND timestamp <= ?
                """, arguments: [event.accountID, event.peer, target.timestamp])
            return .updated(db.changesCount)
        case .error(let id, let text):
            try db.execute(sql: """
                UPDATE message SET state = 'failed', errorText = ?
                WHERE accountID = ? AND peer = ? AND isOutgoing AND (stanzaID = ? OR originID = ?)
                """, arguments: [text, event.accountID, event.peer, id, id])
            return .updated(db.changesCount)
        }
    }

    private static func ingestBody(_ event: MessageEvent, body: String, markable: Bool, _ db: Database) throws -> IngestResult {
        if let archiveID = event.archiveID,
           var existing = try StoredMessage.filter(Column("accountID") == event.accountID && Column("peer") == event.peer
                                                   && Column("archiveID") == archiveID).fetchOne(db) {
            // A placeholder for a message we could not decrypt, and now could.
            guard existing.encryption == .undecryptable, let encryption = event.encryption,
                  encryption != .undecryptable else { return .duplicate }
            existing.body = body
            existing.encryption = encryption
            try existing.update(db)
            return .merged(existing.id!)
        }
        if let senderID = event.senderID,
           var existing = try message(event.accountID, event.peer, isOutgoing: event.isOutgoing, id: senderID,
                                      sender: event.sender, db) {
            var changed = false
            if existing.encryption == .undecryptable, let encryption = event.encryption, encryption != .undecryptable {
                existing.body = body
                existing.encryption = encryption
                changed = true
            }
            if existing.attachment == nil, let attachment = event.attachment {
                existing.attachment = attachment
                changed = true
            }
            var gainedArchiveID = false
            if existing.archiveID == nil, let archiveID = event.archiveID {
                existing.archiveID = archiveID
                changed = true
                gainedArchiveID = true
            }
            if existing.replyToID == nil, let reply = event.reply {
                existing.replyToID = reply.id
                existing.replyTo = reply.to
                existing.replyQuote = reply.quote
                changed = true
            }
            if let sender = event.sender {
                // The room reflecting our message is its delivery.
                if existing.isOutgoing, existing.state == .pending || existing.state == .sent {
                    existing.state = .delivered
                    changed = true
                }
                if existing.occupantID == nil, let occupantID = sender.occupantID {
                    existing.occupantID = occupantID
                    changed = true
                }
            }
            guard changed else { return .duplicate }
            try existing.update(db)
            if gainedArchiveID { try applyPendingDisplayed(existing, db) }
            return .merged(existing.id!)
        }

        var row = StoredMessage(
            accountID: event.accountID, peer: event.peer, isOutgoing: event.isOutgoing, body: body,
            timestamp: event.timestamp, originID: event.senderID, stanzaID: event.stanzaID, archiveID: event.archiveID,
            state: event.isOutgoing ? (event.sender != nil ? .delivered : .sent) : (event.alreadyRead ? .read : .received),
            isMarkable: markable, notified: event.isOutgoing || event.alreadyRead,
            senderNick: event.sender?.nick, occupantID: event.sender?.occupantID, senderJID: event.sender?.realJID,
            mentionsMe: event.mentionsMe, attachment: event.attachment, reply: event.reply,
            isUnstyled: event.unstyled, encryption: event.encryption)
        try row.insert(db)
        try touchConversation(event.accountID, event.peer, at: event.timestamp, db)
        if event.encryption != nil { try encryptConversation(event.accountID, event.peer, db) }

        // Edits that arrived before their target. In a room a retraction
        // names the room's id for the message rather than the sender's.
        let targets = [event.senderID, event.archiveID].compactMap { $0 }
        if !targets.isEmpty {
            // A moderation names the room's id and comes from the room, so
            // it applies whichever way the message went and whoever wrote it.
            let edits = try MessageEdit
                .filter(Column("accountID") == event.accountID && Column("peer") == event.peer
                        && (Column("isOutgoing") == event.isOutgoing
                            || Column("kind") == MessageEdit.Kind.moderation.rawValue)
                        && targets.contains(Column("targetID")))
                .order(Column("timestamp"), Column("id"))
                .fetchAll(db)
                .filter { $0.kind == .moderation ? $0.targetID == event.archiveID
                                                 : isSameSender($0.senderNick, $0.occupantID, as: row) }
            for var edit in edits {
                apply(&edit, to: &row)
                try edit.update(db)
            }
            if !edits.isEmpty { try row.update(db) }
        }
        // Writing in a conversation means having read it.
        if event.isOutgoing { try markRead(event.accountID, event.peer, upTo: event.timestamp, db) }
        try applyPendingDisplayed(row, db)
        try recountUnread(event.accountID, event.peer, db)
        return .inserted(row.id!)
    }

    private static func ingestEdit(_ event: MessageEvent, kind: MessageEdit.Kind, target: String, body: String?,
                                   _ db: Database) throws -> IngestResult {
        var duplicates = MessageEdit.filter(Column("accountID") == event.accountID && Column("peer") == event.peer)
        if let archiveID = event.archiveID, let senderID = event.senderID {
            duplicates = duplicates.filter(Column("archiveID") == archiveID || Column("senderID") == senderID)
        } else if let archiveID = event.archiveID {
            duplicates = duplicates.filter(Column("archiveID") == archiveID)
        } else if let senderID = event.senderID {
            duplicates = duplicates.filter(Column("senderID") == senderID)
        } else {
            duplicates = duplicates.none()
        }
        if var existing = try duplicates.fetchOne(db) {
            if existing.archiveID == nil, let archiveID = event.archiveID {
                existing.archiveID = archiveID
                try existing.update(db)
            }
            return .duplicate
        }

        var edit = MessageEdit(
            accountID: event.accountID, peer: event.peer, isOutgoing: event.isOutgoing, kind: kind,
            targetID: target, body: body, timestamp: event.timestamp, senderID: event.senderID,
            archiveID: event.archiveID, applied: false, senderNick: event.sender?.nick,
            occupantID: event.sender?.occupantID)
        // XEP-0308 §5 / XEP-0424: only the original sender may edit — in a
        // one-to-one chat the same direction, in a room the same occupant.
        guard var row = try message(event.accountID, event.peer, isOutgoing: event.isOutgoing, id: target,
                                    sender: event.sender, db) else {
            try edit.insert(db)
            return .deferred
        }
        apply(&edit, to: &row)
        try edit.insert(db)
        try row.update(db)
        try recountUnread(event.accountID, event.peer, db)
        return .edited(row.id!)
    }

    /// XEP-0425: takes down the room message with this archive id, in either
    /// direction; waits for it if it has not arrived.
    private static func ingestModeration(_ event: MessageEvent, target: String, moderator: String?, reason: String?,
                                         _ db: Database) throws -> IngestResult {
        let existing = MessageEdit.filter(Column("accountID") == event.accountID && Column("peer") == event.peer
                                          && Column("kind") == MessageEdit.Kind.moderation.rawValue
                                          && Column("targetID") == target)
        if try existing.fetchCount(db) > 0 { return .duplicate }
        var edit = MessageEdit(
            accountID: event.accountID, peer: event.peer, isOutgoing: event.isOutgoing, kind: .moderation,
            targetID: target, body: reason, timestamp: event.timestamp, senderID: event.senderID,
            archiveID: event.archiveID, applied: false, senderNick: moderator ?? "", occupantID: nil)
        guard var row = try StoredMessage.filter(Column("accountID") == event.accountID && Column("peer") == event.peer
                                                 && Column("archiveID") == target).fetchOne(db) else {
            try edit.insert(db)
            return .deferred
        }
        apply(&edit, to: &row)
        try edit.insert(db)
        try row.update(db)
        try recountUnread(event.accountID, event.peer, db)
        return .edited(row.id!)
    }

    /// Applies an edit unless the row already has a newer one, or is retracted.
    private static func apply(_ edit: inout MessageEdit, to row: inout StoredMessage) {
        edit.applied = true
        if edit.kind == .moderation, row.moderatedBy == nil {
            // Even over the author's own retraction: say who took it down.
            row.isRetracted = true
            row.body = ""
            row.moderatedBy = edit.senderNick ?? ""
            row.moderationReason = edit.body
            return
        }
        guard !row.isRetracted else { return }
        switch edit.kind {
        case .retraction:
            row.isRetracted = true
            row.body = ""
        case .moderation:
            break
        case .correction:
            guard let body = edit.body else { return }
            if let editedAt = row.editedAt, editedAt > edit.timestamp { return }
            row.body = body
            row.editedAt = edit.timestamp
        }
    }

    /// The message a receipt, marker or edit refers to: by origin id, or by
    /// stanza id for senders that set no origin id — and in a room by the
    /// room's id (XEP-0424 retractions), and only among `sender`'s messages.
    static func message(_ accountID: String, _ peer: String, isOutgoing: Bool, id: String,
                        sender: MessageEvent.RoomSender? = nil, _ db: Database) throws -> StoredMessage? {
        let base = StoredMessage.filter(Column("accountID") == accountID && Column("peer") == peer
                                        && Column("isOutgoing") == isOutgoing)
        var byID = Column("originID") == id || Column("stanzaID") == id
        if sender != nil { byID = byID || Column("archiveID") == id }
        let candidates = try base.filter(byID).order(Column("timestamp"), Column("id")).fetchAll(db)
        let matching = candidates.filter { row in
            guard let sender, !isOutgoing else { return true }
            return isSameSender(sender.nick, sender.occupantID, as: row)
        }
        return matching.first { $0.originID == id } ?? matching.first { $0.stanzaID == id } ?? matching.first
    }

    /// Whether a room occupant (by occupant id when both sides have one, else
    /// by nick) sent `row`. Always true outside rooms and for our own messages.
    static func isSameSender(_ nick: String?, _ occupantID: String?, as row: StoredMessage) -> Bool {
        guard !row.isOutgoing, row.senderNick != nil || row.occupantID != nil else { return true }
        if let occupantID, let rowOccupant = row.occupantID { return occupantID == rowOccupant }
        return nick != nil && nick == row.senderNick
    }

    /// An encrypted message decides a conversation still undecided: it is
    /// encrypted from now on, and never falls back to plain text by itself.
    static func encryptConversation(_ accountID: String, _ peer: String, _ db: Database) throws {
        try db.execute(sql: "UPDATE conversation SET encryption = 'omemo' WHERE accountID = ? AND peer = ? AND encryption IS NULL",
                       arguments: [accountID, peer])
    }

    static func touchConversation(_ accountID: String, _ peer: String, at date: Date, _ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO conversation (accountID, peer, lastActivity, unreadCount) VALUES (?, ?, ?, 0)
            ON CONFLICT (accountID, peer) DO UPDATE SET lastActivity = MAX(lastActivity, excluded.lastActivity)
            """, arguments: [accountID, peer, date])
    }

    @discardableResult
    static func markRead(_ accountID: String, _ peer: String, upTo date: Date, _ db: Database) throws -> Int {
        try db.execute(sql: """
            UPDATE message SET state = 'read', notified = 1
            WHERE accountID = ? AND peer = ? AND NOT isOutgoing AND state = 'received' AND timestamp <= ?
            """, arguments: [accountID, peer, date])
        let changed = db.changesCount
        try recountUnread(accountID, peer, db)
        return changed
    }

    private static func recountUnread(_ accountID: String, _ peer: String, _ db: Database) throws {
        try db.execute(sql: """
            UPDATE conversation SET unreadCount = (
                SELECT COUNT(*) FROM message
                WHERE accountID = ?1 AND peer = ?2 AND NOT isOutgoing AND state = 'received' AND NOT isRetracted)
            WHERE accountID = ?1 AND peer = ?2
            """, arguments: [accountID, peer])
    }
}

// MARK: - Local actions

extension HrafnDatabase {

    /// Records a message the user just wrote, before it is sent.
    public func insertOutgoing(accountID: String, peer: String, body: String, id: String,
                               state: MessageState = .pending, timestamp: Date = Date(),
                               reply: ReplyReference? = nil, encryption: MessageEncryption? = nil) throws -> StoredMessage {
        try writer.write { db in
            var row = StoredMessage(accountID: accountID, peer: peer, isOutgoing: true, body: body, timestamp: timestamp,
                                    originID: id, stanzaID: id, state: state, isMarkable: true, reply: reply,
                                    encryption: encryption)
            try row.insert(db)
            try Self.touchConversation(accountID, peer, at: timestamp, db)
            if encryption != nil { try Self.encryptConversation(accountID, peer, db) }
            try Self.markRead(accountID, peer, upTo: timestamp, db)
            return row
        }
    }

    /// How an outgoing message went out, recorded once it has.
    public func setEncryption(messageID: Int64, _ encryption: MessageEncryption?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE message SET encryption = ? WHERE id = ?",
                           arguments: [encryption?.rawValue, messageID])
            if encryption != nil,
               let row = try Row.fetchOne(db, sql: "SELECT accountID, peer FROM message WHERE id = ?", arguments: [messageID]) {
                try Self.encryptConversation(row["accountID"], row["peer"], db)
            }
        }
    }

    /// Handed to a connection. Only from `pending`: a receipt, marker or room
    /// reflection may already have moved it further.
    public func markSent(messageID: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE message SET state = 'sent' WHERE id = ? AND state = 'pending'",
                           arguments: [messageID])
        }
    }

    public func setState(messageID: Int64, _ state: MessageState, errorText: String? = nil) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE message SET state = ?, errorText = ? WHERE id = ?",
                           arguments: [state.rawValue, errorText, messageID])
        }
    }

    /// Outgoing messages that never reached a connection, oldest first.
    public func outbox(accountID: String) throws -> [StoredMessage] {
        try writer.read { db in
            try StoredMessage.filter(Column("accountID") == accountID && Column("state") == MessageState.pending.rawValue)
                .order(Column("timestamp"), Column("id")).fetchAll(db)
        }
    }

    public func message(id: Int64) throws -> StoredMessage? {
        try writer.read { db in try StoredMessage.fetchOne(db, key: id) }
    }

    /// Marks every incoming message in the conversation read. Returns the
    /// newest markable one's origin id, for a XEP-0333 displayed marker, if
    /// anything was unread.
    public func markConversationRead(accountID: String, peer: String) throws -> String? {
        try writer.write { db in
            let changed = try Self.markRead(accountID, peer, upTo: .distantFuture, db)
            guard changed > 0 else { return nil }
            return try String.fetchOne(db, sql: """
                SELECT originID FROM message
                WHERE accountID = ? AND peer = ? AND NOT isOutgoing AND isMarkable AND originID IS NOT NULL
                ORDER BY timestamp DESC, id DESC LIMIT 1
                """, arguments: [accountID, peer])
        }
    }

    /// Opens (or creates) an empty conversation, so a new chat can be shown.
    public func openConversation(accountID: String, peer: String) throws {
        try writer.write { db in try Self.touchConversation(accountID, peer, at: Date(), db) }
    }

    public func conversationDraft(accountID: String, peer: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT draft FROM conversation WHERE accountID = ? AND peer = ?",
                                arguments: [accountID, peer])
        }
    }

    public func setDraft(accountID: String, peer: String, _ draft: String?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE conversation SET draft = ? WHERE accountID = ? AND peer = ?",
                           arguments: [draft?.isEmpty == true ? nil : draft, accountID, peer])
        }
    }

    /// Removes the conversation and its local history (the server archive keeps
    /// its copy).
    public func deleteConversation(accountID: String, peer: String) throws {
        try writer.write { db in
            try StoredMessage.filter(Column("accountID") == accountID && Column("peer") == peer).deleteAll(db)
            try MessageEdit.filter(Column("accountID") == accountID && Column("peer") == peer).deleteAll(db)
            try Reaction.filter(Column("accountID") == accountID && Column("peer") == peer).deleteAll(db)
            try Conversation.deleteOne(db, key: ["accountID": accountID, "peer": peer])
        }
    }

    /// The oldest archived message stored for a conversation, for paging back.
    public func oldestArchiveID(accountID: String, peer: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT archiveID FROM message WHERE accountID = ? AND peer = ? AND archiveID IS NOT NULL
                ORDER BY timestamp, id LIMIT 1
                """, arguments: [accountID, peer])
        }
    }
}

// MARK: - Encryption

extension HrafnDatabase {

    /// The conversation's choice; `nil` while undecided.
    public func conversationEncryption(accountID: String, peer: String) throws -> ConversationEncryption? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT encryption FROM conversation WHERE accountID = ? AND peer = ?",
                                arguments: [accountID, peer]).flatMap(ConversationEncryption.init(rawValue:))
        }
    }

    public func setConversationEncryption(accountID: String, peer: String, _ encryption: ConversationEncryption?) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO conversation (accountID, peer, lastActivity, unreadCount, encryption) VALUES (?, ?, ?, 0, ?)
                ON CONFLICT (accountID, peer) DO UPDATE SET encryption = excluded.encryption
                """, arguments: [accountID, peer, Date(), encryption?.rawValue])
        }
    }

    public func observeConversationEncryption(accountID: String, peer: String)
        -> AsyncThrowingStream<ConversationEncryption?, any Error> {
        observe { db in
            try String.fetchOne(db, sql: "SELECT encryption FROM conversation WHERE accountID = ? AND peer = ?",
                                arguments: [accountID, peer]).flatMap(ConversationEncryption.init(rawValue:))
        }
    }
}
