import Foundation
import GRDB

// MARK: - Reactions (XEP-0444)

extension HrafnDatabase {

    /// Replaces one sender's reactions to one message, unless what is stored
    /// is newer (archives arrive late and out of order).
    static func ingestReactions(_ event: MessageEvent, target: String, emojis: [String],
                                _ db: Database) throws -> IngestResult {
        let sender: String
        if event.isOutgoing {
            sender = ""
        } else if let room = event.sender {
            guard let key = room.occupantID.map({ "occupant:" + $0 }) ?? room.nick.map({ "nick:" + $0 })
            else { return .updated(0) }
            sender = key
        } else {
            sender = event.peer
        }
        let key: [String: any DatabaseValueConvertible] = [
            "accountID": event.accountID, "peer": event.peer, "targetID": target, "sender": sender,
        ]
        if let existing = try Reaction.fetchOne(db, key: key), existing.timestamp > event.timestamp {
            return .duplicate
        }
        try Reaction(accountID: event.accountID, peer: event.peer, targetID: target, sender: sender, emojis: emojis,
                     timestamp: event.timestamp, senderNick: event.isOutgoing ? nil : event.sender?.nick).save(db)
        return .updated(1)
    }

    /// Our current reactions to the message with this reference id.
    public func ownReactions(accountID: String, peer: String, targetID: String) throws -> [String] {
        try writer.read { db in
            try Reaction.fetchOne(db, key: ["accountID": accountID, "peer": peer, "targetID": targetID, "sender": ""])?
                .emojis ?? []
        }
    }

    /// The stored message a reply or reaction refers to, if it is here.
    public func message(accountID: String, peer: String, referenceID: String, inRoom: Bool) throws -> StoredMessage? {
        try writer.read { db in
            let base = StoredMessage.filter(Column("accountID") == accountID && Column("peer") == peer)
            if inRoom { return try base.filter(Column("archiveID") == referenceID).fetchOne(db) }
            return try base.filter(Column("originID") == referenceID || Column("stanzaID") == referenceID)
                .order(Column("timestamp"), Column("id")).fetchOne(db)
        }
    }
}

// MARK: - Displayed synchronization (XEP-0490)

extension HrafnDatabase {

    /// Another of our devices (or this one, echoed) displayed the message with
    /// this archive id: it and everything before it is read. If it is not
    /// here yet, that happens when it arrives. Returns the messages marked read.
    @discardableResult
    public func applyDisplayedSync(accountID: String, peer: String, archiveID: String) throws -> Int {
        try writer.write { db in
            guard var conversation = try Conversation.fetchOne(db, key: ["accountID": accountID, "peer": peer])
            else { return 0 }
            guard let target = try StoredMessage
                .filter(Column("accountID") == accountID && Column("peer") == peer && Column("archiveID") == archiveID)
                .fetchOne(db) else {
                conversation.syncedDisplayedID = archiveID
                conversation.syncedDisplayedPending = true
                try conversation.update(db)
                return 0
            }
            // The marker only moves forward here; one naming an older message
            // (a device that fell behind) still reads what it covers.
            if try !Self.isAhead(of: target, conversation, db) {
                conversation.syncedDisplayedID = archiveID
                conversation.syncedDisplayedPending = false
                try conversation.update(db)
            }
            return try Self.markRead(accountID, peer, upTo: target.timestamp, db)
        }
    }

    /// The archive id to publish as this conversation's marker now that it
    /// has been read here, or `nil` when the published one is as new — or
    /// when another device is ahead, at a message not stored here yet.
    public func displayedSyncCandidate(accountID: String, peer: String) throws -> String? {
        try writer.read { db in
            guard let conversation = try Conversation.fetchOne(db, key: ["accountID": accountID, "peer": peer]),
                  !conversation.syncedDisplayedPending,
                  let newest = try StoredMessage
                    .filter(Column("accountID") == accountID && Column("peer") == peer && Column("archiveID") != nil)
                    .order(Column("timestamp").desc, Column("id").desc)
                    .fetchOne(db),
                  try !Self.isAhead(of: newest, conversation, db)
            else { return nil }
            return newest.archiveID
        }
    }

    /// Records a marker this device published.
    public func recordDisplayedSync(accountID: String, peer: String, archiveID: String) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE conversation SET syncedDisplayedID = ?, syncedDisplayedPending = 0
                WHERE accountID = ? AND peer = ?
                """, arguments: [archiveID, accountID, peer])
        }
    }

    /// Whether the conversation's marker already names `message` or a later one.
    private static func isAhead(of message: StoredMessage, _ conversation: Conversation, _ db: Database) throws -> Bool {
        guard let synced = conversation.syncedDisplayedID else { return false }
        if synced == message.archiveID { return true }
        guard let current = try StoredMessage
            .filter(Column("accountID") == conversation.accountID && Column("peer") == conversation.peer
                    && Column("archiveID") == synced)
            .fetchOne(db) else { return false }
        return current.timestamp > message.timestamp
            || (current.timestamp == message.timestamp && (current.id ?? 0) >= (message.id ?? 0))
    }

    /// A marker that waited for this message: read up to it now.
    static func applyPendingDisplayed(_ row: StoredMessage, _ db: Database) throws {
        guard let archiveID = row.archiveID else { return }
        try db.execute(sql: """
            UPDATE conversation SET syncedDisplayedPending = 0
            WHERE accountID = ? AND peer = ? AND syncedDisplayedPending AND syncedDisplayedID = ?
            """, arguments: [row.accountID, row.peer, archiveID])
        if db.changesCount > 0 { try markRead(row.accountID, row.peer, upTo: row.timestamp, db) }
    }
}
