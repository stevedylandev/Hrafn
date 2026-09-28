import Foundation
import GRDB

/// A XEP-0402 bookmark as the store takes it, free of protocol types.
public struct BookmarkEntry: Sendable, Hashable {
    public var jid: String
    public var name: String?
    public var nick: String?
    public var password: String?
    public var autojoin: Bool
    /// `<extensions/>` as XML.
    public var extensions: String?

    public init(jid: String, name: String?, nick: String?, password: String?, autojoin: Bool, extensions: String?) {
        self.jid = jid
        self.name = name
        self.nick = nick
        self.password = password
        self.autojoin = autojoin
        self.extensions = extensions
    }
}

extension HrafnDatabase {

    public func fetchRoom(accountID: String, jid: String) throws -> Room? {
        try writer.read { db in try Room.fetchOne(db, key: ["accountID": accountID, "jid": jid]) }
    }

    public func fetchRooms(accountID: String) throws -> [Room] {
        try writer.read { db in try Room.filter(Column("accountID") == accountID).fetchAll(db) }
    }

    public func isRoom(accountID: String, jid: String) throws -> Bool {
        try writer.read { db in try Room.exists(db, key: ["accountID": accountID, "jid": jid]) }
    }

    /// Changes a room's row, creating it first if needed. Returns the result.
    @discardableResult
    public func updateRoom(accountID: String, jid: String, _ change: (inout Room) -> Void) throws -> Room {
        try writer.write { db in
            var room = try Room.fetchOne(db, key: ["accountID": accountID, "jid": jid])
                ?? Room(accountID: accountID, jid: jid, autojoin: false)
            change(&room)
            try room.save(db)
            return room
        }
    }

    /// Replaces the bookmarked set with the server's. Rooms no longer
    /// bookmarked stay (with their history and settings) but are no longer
    /// joined automatically.
    public func replaceBookmarks(accountID: String, _ bookmarks: [BookmarkEntry]) throws {
        try writer.write { db in
            let listed = Set(bookmarks.map(\.jid))
            for var room in try Room.filter(Column("accountID") == accountID && Column("bookmarked")).fetchAll(db)
            where !listed.contains(room.jid) {
                room.bookmarked = false
                room.autojoin = false
                try room.update(db)
            }
            for bookmark in bookmarks { try Self.apply(bookmark, accountID: accountID, db) }
        }
    }

    /// A bookmark published by another of our devices (or by us).
    public func applyBookmark(accountID: String, _ bookmark: BookmarkEntry) throws {
        try writer.write { db in try Self.apply(bookmark, accountID: accountID, db) }
    }

    /// A bookmark retracted: stop joining the room automatically.
    public func removeBookmark(accountID: String, jid: String) throws {
        try writer.write { db in
            guard var room = try Room.fetchOne(db, key: ["accountID": accountID, "jid": jid]) else { return }
            room.bookmarked = false
            room.autojoin = false
            try room.update(db)
        }
    }

    private static func apply(_ bookmark: BookmarkEntry, accountID: String, _ db: Database) throws {
        var room = try Room.fetchOne(db, key: ["accountID": accountID, "jid": bookmark.jid])
            ?? Room(accountID: accountID, jid: bookmark.jid)
        room.name = bookmark.name
        room.nick = bookmark.nick
        room.password = bookmark.password
        room.autojoin = bookmark.autojoin
        room.bookmarked = true
        room.bookmarkExtensions = bookmark.extensions
        try room.save(db)
    }

    /// Forgets a room altogether: its row, conversation and history.
    public func deleteRoom(accountID: String, jid: String) throws {
        try writer.write { db in
            try Room.deleteOne(db, key: ["accountID": accountID, "jid": jid])
            try StoredMessage.filter(Column("accountID") == accountID && Column("peer") == jid).deleteAll(db)
            try MessageEdit.filter(Column("accountID") == accountID && Column("peer") == jid).deleteAll(db)
            try Reaction.filter(Column("accountID") == accountID && Column("peer") == jid).deleteAll(db)
            try Conversation.deleteOne(db, key: ["accountID": accountID, "peer": jid])
        }
    }

    /// When the newest stored message of a room was sent, to ask a room
    /// without an archive for the history since.
    public func newestMessageDate(accountID: String, peer: String) throws -> Date? {
        try writer.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(timestamp) FROM message WHERE accountID = ? AND peer = ?",
                              arguments: [accountID, peer])
        }
    }

    /// Unsent messages for one conversation, oldest first.
    public func outbox(accountID: String, peer: String) throws -> [StoredMessage] {
        try writer.read { db in
            try StoredMessage.filter(Column("accountID") == accountID && Column("peer") == peer
                                     && Column("state") == MessageState.pending.rawValue)
                .order(Column("timestamp"), Column("id")).fetchAll(db)
        }
    }

    /// Records our own message in a room before it is sent.
    public func insertOutgoing(accountID: String, room: String, nick: String?, body: String, id: String,
                               timestamp: Date = Date(), reply: ReplyReference? = nil) throws -> StoredMessage {
        try writer.write { db in
            var row = StoredMessage(accountID: accountID, peer: room, isOutgoing: true, body: body, timestamp: timestamp,
                                    originID: id, stanzaID: id, state: .pending, senderNick: nick, reply: reply)
            try row.insert(db)
            try Self.touchConversation(accountID, room, at: timestamp, db)
            try Self.markRead(accountID, room, upTo: timestamp, db)
            return row
        }
    }

    // MARK: Invitations

    public func saveInvitation(_ invitation: RoomInvitation) throws {
        try writer.write { db in try invitation.save(db) }
    }

    public func deleteInvitation(accountID: String, room: String) throws {
        _ = try writer.write { db in try RoomInvitation.deleteOne(db, key: ["accountID": accountID, "room": room]) }
    }

    public func invitation(accountID: String, room: String) throws -> RoomInvitation? {
        try writer.read { db in try RoomInvitation.fetchOne(db, key: ["accountID": accountID, "room": room]) }
    }
}
