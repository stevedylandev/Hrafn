import Foundation
import GRDB

/// An incoming message that has not been announced yet.
public struct PendingNotification: Sendable, Hashable, Identifiable {
    public var message: StoredMessage
    /// The contact's or room's name, else the address.
    public var title: String
    /// Muted conversations, and room messages the room's level does not
    /// announce, are marked announced without a banner.
    public var muted: Bool
    /// Group chat: who wrote it.
    public var sender: String? = nil

    public var id: Int64 { message.id! }
    public var accountID: String { message.accountID }
    public var peer: String { message.peer }
    /// Groups a conversation's banners (and lets them be withdrawn together).
    public var threadID: String { Self.threadID(accountID: message.accountID, peer: message.peer) }

    public static func threadID(accountID: String, peer: String) -> String { accountID + "|" + peer }
}

extension HrafnDatabase {

    /// Unread incoming messages nobody has announced, oldest first.
    public func pendingNotifications(accountIDs: [String]? = nil) throws -> [PendingNotification] {
        try writer.read { db in try Self.pending(accountIDs: accountIDs, db) }
    }

    /// Returns the pending notifications and marks them announced in one
    /// transaction, so the app and the notification service extension never
    /// both announce a message.
    public func claimPendingNotifications(accountIDs: [String]? = nil) throws -> [PendingNotification] {
        try writer.write { db in
            let pending = try Self.pending(accountIDs: accountIDs, db)
            if !pending.isEmpty {
                let ids = pending.map(\.id)
                try db.execute(sql: "UPDATE message SET notified = 1 WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                               arguments: StatementArguments(ids))
            }
            return pending
        }
    }

    static func pending(accountIDs: [String]?, _ db: Database) throws -> [PendingNotification] {
        var request = StoredMessage.filter(Column("notified") == false && Column("isOutgoing") == false
                                           && Column("state") == MessageState.received.rawValue
                                           && Column("isRetracted") == false)
        if let accountIDs { request = request.filter(accountIDs.contains(Column("accountID"))) }
        return try request.order(Column("timestamp"), Column("id")).fetchAll(db).map { message in
            let key: [String: any DatabaseValueConvertible] = ["accountID": message.accountID, "jid": message.peer]
            var muted = try Bool.fetchOne(db, sql: "SELECT muted FROM conversation WHERE accountID = ? AND peer = ?",
                                          arguments: [message.accountID, message.peer]) ?? false
            if let room = try Room.fetchOne(db, key: key) {
                switch room.effectiveNotify {
                case .always: break
                case .mentions: muted = muted || !message.mentionsMe
                case .never: muted = true
                }
                return PendingNotification(message: message, title: room.displayName, muted: muted,
                                           sender: message.senderNick)
            }
            if let (roomJID, nick) = RoomPrivate.split(message.peer) {
                let room = try Room.fetchOne(db, key: ["accountID": message.accountID, "jid": roomJID])
                return PendingNotification(message: message, title: RoomPrivate.title(nick: nick, room: room, roomJID: roomJID),
                                           muted: muted)
            }
            let contact = try Contact.fetchOne(db, key: key)
            return PendingNotification(message: message, title: contact?.name ?? message.peer, muted: muted)
        }
    }

    public func setMuted(accountID: String, peer: String, _ muted: Bool) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO conversation (accountID, peer, lastActivity, unreadCount, muted) VALUES (?, ?, ?, 0, ?)
                ON CONFLICT (accountID, peer) DO UPDATE SET muted = excluded.muted
                """, arguments: [accountID, peer, Date(), muted])
        }
    }

    public func isMuted(accountID: String, peer: String) -> AsyncThrowingStream<Bool, any Error> {
        observe { db in
            try Bool.fetchOne(db, sql: "SELECT muted FROM conversation WHERE accountID = ? AND peer = ?",
                              arguments: [accountID, peer]) ?? false
        }
    }

    /// The badge: unread incoming messages across every account.
    public func unreadTotal() throws -> Int {
        try writer.read { db in try Int.fetchOne(db, sql: Self.badgeSQL) ?? 0 }
    }

    /// Messages whose banners may stay: unread and not retracted. A banner
    /// for anything else — read here or on another device, or retracted —
    /// should go.
    public func unreadMessageIDs() -> AsyncThrowingStream<Set<Int64>, any Error> {
        observe { db in try Self.unreadMessageIDs(db) }
    }

    /// The same, once (for the notification service extension).
    public func fetchUnreadMessageIDs() throws -> Set<Int64> {
        try writer.read { db in try Self.unreadMessageIDs(db) }
    }

    static func unreadMessageIDs(_ db: Database) throws -> Set<Int64> {
        Set(try Int64.fetchAll(db, sql: """
            SELECT id FROM message WHERE NOT isOutgoing AND state = 'received' AND NOT isRetracted
            """))
    }

    /// Unread one-to-one messages, plus unread room messages the room's
    /// notification level announces: a busy channel's chatter does not add to
    /// the badge, its mentions do.
    static let badgeSQL = """
        SELECT COUNT(*) FROM message m
        LEFT JOIN room r ON r.accountID = m.accountID AND r.jid = m.peer
        WHERE NOT m.isOutgoing AND m.state = 'received' AND NOT m.isRetracted
          AND (r.jid IS NULL
               OR COALESCE(r.notify, CASE WHEN r.isMembersOnly AND r.isNonAnonymous THEN 'always' ELSE 'mentions' END)
                  = 'always'
               OR (COALESCE(r.notify, CASE WHEN r.isMembersOnly AND r.isNonAnonymous THEN 'always' ELSE 'mentions' END)
                   = 'mentions' AND m.mentionsMe))
        """
}
