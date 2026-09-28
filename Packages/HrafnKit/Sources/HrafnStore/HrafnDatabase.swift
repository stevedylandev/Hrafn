import Foundation
import GRDB

/// The app's database: every account's roster, conversations and messages.
///
/// Services write; the UI observes. Writes are short transactions so the app
/// and the notification service extension can share the file (WAL).
public final class HrafnDatabase: Sendable {

    public let writer: any DatabaseWriter

    /// Opens (creating if needed) the database at `url`, typically in the App
    /// Group container.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        // Another process (the notification extension) may hold the write lock
        // briefly; wait rather than fail.
        configuration.busyMode = .timeout(5)
        // A suspended app holding a SQLite lock in the App Group is killed
        // (0xdead10cc); `suspend()` interrupts and refuses work until `resume()`.
        configuration.observesSuspensionNotifications = true
        writer = try DatabasePool(path: url.path, configuration: configuration)
        try Self.migrator.migrate(writer)
    }

    /// An in-memory database, for tests and previews.
    public init() throws {
        writer = try DatabaseQueue()
        try Self.migrator.migrate(writer)
    }

    /// Call as the app is about to be suspended: running statements are
    /// interrupted and new ones fail until `resume()`, so no lock on the shared
    /// file is held while suspended.
    public static func suspend() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    public static func resume() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    /// `Hrafn.sqlite` in the App Group container when there is one, else in
    /// Application Support.
    public static func defaultURL(appGroup: String?) -> URL {
        let base = appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            ?? URL.applicationSupportDirectory
        return base.appending(path: "Hrafn.sqlite")
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "account") { t in
                t.primaryKey("id", .text)
                t.column("jid", .text).notNull().unique()
                t.column("host", .text)
                t.column("port", .integer)
                t.column("directTLS", .boolean).notNull()
                t.column("enabled", .boolean).notNull()
                t.column("rosterVersion", .text)
                t.column("trustedFingerprint", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "contact") { t in
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("jid", .text).notNull()
                t.column("name", .text)
                t.column("subscription", .text).notNull()
                t.column("pendingOut", .boolean).notNull()
                t.column("pendingIn", .boolean).notNull()
                t.column("inRoster", .boolean).notNull()
                t.column("groups", .jsonText).notNull()
                t.primaryKey(["accountID", "jid"])
            }
            try db.create(table: "blocked") { t in
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("jid", .text).notNull()
                t.primaryKey(["accountID", "jid"])
            }
            try db.create(table: "conversation") { t in
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("peer", .text).notNull()
                t.column("lastActivity", .datetime).notNull()
                t.column("unreadCount", .integer).notNull()
                t.column("draft", .text)
                t.primaryKey(["accountID", "peer"])
            }
            try db.create(table: "message") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("peer", .text).notNull()
                t.column("isOutgoing", .boolean).notNull()
                t.column("body", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("originID", .text)
                t.column("stanzaID", .text)
                t.column("archiveID", .text)
                t.column("state", .text).notNull()
                t.column("editedAt", .datetime)
                t.column("isRetracted", .boolean).notNull()
                t.column("isMarkable", .boolean).notNull()
                t.column("errorText", .text)
            }
            try db.create(index: "message_chat", on: "message", columns: ["accountID", "peer", "timestamp"])
            try db.create(index: "message_origin", on: "message", columns: ["accountID", "peer", "originID"])
            try db.create(index: "message_archive", on: "message", columns: ["accountID", "archiveID"],
                          options: .unique, condition: Column("archiveID") != nil)
            try db.create(index: "message_state", on: "message", columns: ["accountID", "state"])
            try db.create(table: "messageEdit") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("peer", .text).notNull()
                t.column("isOutgoing", .boolean).notNull()
                t.column("kind", .text).notNull()
                t.column("targetID", .text).notNull()
                t.column("body", .text)
                t.column("timestamp", .datetime).notNull()
                t.column("senderID", .text)
                t.column("archiveID", .text)
                t.column("applied", .boolean).notNull()
            }
            try db.create(index: "messageEdit_target", on: "messageEdit",
                          columns: ["accountID", "peer", "isOutgoing", "targetID"])
            try db.create(table: "archiveCursor") { t in
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("archive", .text).notNull()
                t.column("lastID", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["accountID", "archive"])
            }
        }
        migrator.registerMigration("v2") { db in
            // Phase 5: per-chat mute, and which incoming messages have been
            // announced (by the app or the notification service extension),
            // so each is announced once.
            try db.alter(table: "conversation") { t in
                t.add(column: "muted", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "message") { t in
                t.add(column: "notified", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: "UPDATE message SET notified = 1")
            try db.create(index: "message_notify", on: "message", columns: ["notified", "state"])
        }
        migrator.registerMigration("v3") { db in
            // Phase 6: group chats. Rooms mirror the Bookmarks 2 node plus
            // what only this device knows; invitations wait for an answer.
            try db.create(table: "room") { t in
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("jid", .text).notNull()
                t.column("name", .text)
                t.column("nick", .text)
                t.column("password", .text)
                t.column("autojoin", .boolean).notNull()
                t.column("bookmarked", .boolean).notNull()
                t.column("bookmarkExtensions", .text)
                t.column("subject", .text)
                t.column("notify", .text)
                t.column("isMembersOnly", .boolean).notNull().defaults(to: false)
                t.column("isNonAnonymous", .boolean).notNull().defaults(to: false)
                t.column("ownOccupantID", .text)
                t.primaryKey(["accountID", "jid"])
            }
            try db.create(table: "roomInvite") { t in
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("room", .text).notNull()
                t.column("inviter", .text)
                t.column("reason", .text)
                t.column("password", .text)
                t.column("receivedAt", .datetime).notNull()
                t.primaryKey(["accountID", "room"])
            }
            try db.alter(table: "message") { t in
                t.add(column: "senderNick", .text)
                t.add(column: "occupantID", .text)
                t.add(column: "senderJID", .text)
                t.add(column: "mentionsMe", .boolean).notNull().defaults(to: false)
            }
            // Who sent an edit, so one occupant cannot edit another's message.
            try db.alter(table: "messageEdit") { t in
                t.add(column: "senderNick", .text)
                t.add(column: "occupantID", .text)
            }
            // Archive ids are unique per archive, and each room is one: two
            // rooms (ejabberd uses timestamps) may hand out the same id.
            try db.drop(index: "message_archive")
            try db.create(index: "message_archive", on: "message", columns: ["accountID", "peer", "archiveID"],
                          options: .unique, condition: Column("archiveID") != nil)
        }
        migrator.registerMigration("v4") { db in
            // Phase 7: shared files on messages, and what contacts publish
            // about themselves (avatar, nickname).
            try db.alter(table: "message") { t in
                t.add(column: "attachment", .jsonText)
            }
            try db.create(table: "profile") { t in
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("jid", .text).notNull()
                t.column("nickname", .text)
                t.column("avatarHash", .text)
                t.column("avatarType", .text)
                t.column("avatarFromPEP", .boolean).notNull().defaults(to: false)
                t.column("checkedAt", .datetime)
                t.primaryKey(["accountID", "jid"])
            }
        }
        migrator.registerMigration("v5") { db in
            // Phase 8: replies, reactions, styling opt-out, and XEP-0490 read
            // positions shared between our devices.
            try db.alter(table: "message") { t in
                t.add(column: "replyToID", .text)
                t.add(column: "replyTo", .text)
                t.add(column: "replyQuote", .text)
                t.add(column: "isUnstyled", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "reaction") { t in
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("peer", .text).notNull()
                t.column("targetID", .text).notNull()
                t.column("sender", .text).notNull()
                t.column("emojis", .jsonText).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("senderNick", .text)
                t.primaryKey(["accountID", "peer", "targetID", "sender"])
            }
            try db.alter(table: "conversation") { t in
                t.add(column: "syncedDisplayedID", .text)
                t.add(column: "syncedDisplayedPending", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v6") { db in
            // Phase 9: full-text search over message bodies. External content
            // (the index holds no copy of the text); GRDB's triggers keep it
            // in step with inserts, corrections and retractions, and the
            // existing history is indexed here.
            try db.create(virtualTable: "messageSearch", using: FTS5()) { t in
                t.synchronize(withTable: "message")
                // "cafe" finds "café"; case never matters.
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("body")
            }
        }
        migrator.registerMigration("v7") { db in
            // XEP-0425: who took a room message down, and why.
            try db.alter(table: "message") { t in
                t.add(column: "moderatedBy", .text)
                t.add(column: "moderationReason", .text)
            }
        }
        migrator.registerMigration("v8") { db in
            // OMEMO (docs/OMEMO.md): how each message travelled, and each
            // conversation's choice. The keys and sessions are elsewhere
            // (OMEMODatabase), kept out of backups.
            try db.alter(table: "message") { t in
                t.add(column: "encryption", .text)
            }
            try db.alter(table: "conversation") { t in
                t.add(column: "encryption", .text)
            }
        }
        migrator.registerMigration("v9") { db in
            // Notes to self came back from our own address and were stored
            // a second time as incoming. Drop those echoes, and count what
            // other devices of ours wrote there as ours.
            let isSelf = """
                message.peer = (SELECT lower(jid) FROM account WHERE account.id = message.accountID)
                """
            try db.execute(sql: """
                DELETE FROM message WHERE NOT isOutgoing AND \(isSelf) AND originID IS NOT NULL
                  AND EXISTS (SELECT 1 FROM message AS sent WHERE sent.accountID = message.accountID
                              AND sent.peer = message.peer AND sent.isOutgoing AND sent.originID = message.originID)
                """)
            try db.execute(sql: """
                UPDATE message SET isOutgoing = 1, state = 'sent', notified = 1 WHERE NOT isOutgoing AND \(isSelf)
                """)
            try db.execute(sql: """
                UPDATE conversation SET unreadCount = 0
                WHERE peer = (SELECT lower(jid) FROM account WHERE account.id = conversation.accountID)
                """)
        }
        migrator.registerMigration("v10") { db in
            // Each account's own presence, kept across sessions.
            try db.alter(table: "account") { t in
                t.add(column: "availability", .text)
                t.add(column: "statusMessage", .text)
            }
        }
        return migrator
    }
}

// MARK: - Observation

extension HrafnDatabase {

    /// Emits the current value, then again after every change that affects it.
    public func observe<Value: Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncThrowingStream<Value, any Error> {
        let values = ValueObservation.tracking(fetch).values(in: writer)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in values { continuation.yield(value) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func accounts() -> AsyncThrowingStream<[Account], any Error> {
        observe { db in try Account.order(Column("createdAt")).fetchAll(db) }
    }

    /// Conversations, most recent first, across `accountIDs` (all when `nil`).
    public func conversations(accountIDs: [String]? = nil) -> AsyncThrowingStream<[ConversationSummary], any Error> {
        observe { db in try Self.conversationSummaries(db, accountIDs: accountIDs) }
    }

    /// The same, once (for the share extension, which observes nothing).
    public func fetchConversationSummaries(accountIDs: [String]? = nil) throws -> [ConversationSummary] {
        try writer.read { db in try Self.conversationSummaries(db, accountIDs: accountIDs) }
    }

    public static func conversationSummaries(_ db: Database, accountIDs: [String]? = nil) throws -> [ConversationSummary] {
        var request = Conversation.order(Column("lastActivity").desc)
        if let accountIDs { request = request.filter(accountIDs.contains(Column("accountID"))) }
        return try request.fetchAll(db).map { conversation in
            let key: [String: any DatabaseValueConvertible] = ["accountID": conversation.accountID, "jid": conversation.peer]
            let contact = try Contact.fetchOne(db, key: key)
            let room = try Room.fetchOne(db, key: key)
            let profile = try Profile.fetchOne(db, key: key)
            let last = try StoredMessage
                .filter(Column("accountID") == conversation.accountID && Column("peer") == conversation.peer)
                .order(Column("timestamp").desc, Column("id").desc)
                .fetchOne(db)
            let viaRoom = try RoomPrivate.split(conversation.peer).flatMap {
                try Room.fetchOne(db, key: ["accountID": conversation.accountID, "jid": $0.room])
            }
            return ConversationSummary(conversation: conversation, contact: contact, room: room, lastMessage: last,
                                       profile: profile, viaRoom: viaRoom)
        }
    }

    /// The newest `limit` messages of a conversation, oldest first.
    public func messages(accountID: String, peer: String, limit: Int = 200) -> AsyncThrowingStream<[StoredMessage], any Error> {
        observe { db in
            Array(try StoredMessage
                .filter(Column("accountID") == accountID && Column("peer") == peer)
                .order(Column("timestamp").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
                .reversed())
        }
    }

    /// A conversation's reactions, by message (`targetID`).
    public func reactions(accountID: String, peer: String) -> AsyncThrowingStream<[String: [ReactionCount]], any Error> {
        observe { db in
            ReactionCount.summaries(try Reaction.filter(Column("accountID") == accountID && Column("peer") == peer)
                .fetchAll(db))
        }
    }

    /// Roster entries and pending requests, by name.
    public func contacts(accountID: String) -> AsyncThrowingStream<[Contact], any Error> {
        observe { db in
            try Contact.filter(Column("accountID") == accountID)
                .order(sql: "COALESCE(name, jid) COLLATE NOCASE")
                .fetchAll(db)
        }
    }

    public func contact(accountID: String, jid: String) -> AsyncThrowingStream<Contact?, any Error> {
        observe { db in try Contact.fetchOne(db, key: ["accountID": accountID, "jid": jid]) }
    }

    public func blocked(accountID: String) -> AsyncThrowingStream<[String], any Error> {
        observe { db in
            try String.fetchAll(db, sql: "SELECT jid FROM blocked WHERE accountID = ? ORDER BY jid", arguments: [accountID])
        }
    }

    public func rooms(accountID: String) -> AsyncThrowingStream<[Room], any Error> {
        observe { db in
            try Room.filter(Column("accountID") == accountID)
                .order(sql: "COALESCE(name, jid) COLLATE NOCASE")
                .fetchAll(db)
        }
    }

    public func room(accountID: String, jid: String) -> AsyncThrowingStream<Room?, any Error> {
        observe { db in try Room.fetchOne(db, key: ["accountID": accountID, "jid": jid]) }
    }

    /// Invitations to rooms, across `accountIDs` (all when `nil`), newest first.
    public func invitations(accountIDs: [String]? = nil) -> AsyncThrowingStream<[RoomInvitation], any Error> {
        observe { db in
            var request = RoomInvitation.order(Column("receivedAt").desc)
            if let accountIDs { request = request.filter(accountIDs.contains(Column("accountID"))) }
            return try request.fetchAll(db)
        }
    }

    /// Unread incoming messages across every account, for the badge.
    public func totalUnread() -> AsyncThrowingStream<Int, any Error> {
        observe { db in try Int.fetchOne(db, sql: Self.badgeSQL) ?? 0 }
    }
}
