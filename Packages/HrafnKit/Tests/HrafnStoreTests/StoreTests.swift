import Testing
import Foundation
import GRDB
@testable import HrafnStore

private let romeo = "romeo@example.net"

private func makeStore() throws -> (HrafnDatabase, Account) {
    let database = try HrafnDatabase()
    let account = Account(jid: "juliet@example.com")
    try database.save(account)
    return (database, account)
}

private func rows(_ database: HrafnDatabase, _ account: Account, peer: String = romeo) throws -> [StoredMessage] {
    try database.writer.read { db in
        try StoredMessage.filter(Column("accountID") == account.id && Column("peer") == peer)
            .order(Column("timestamp"), Column("id")).fetchAll(db)
    }
}

private func unread(_ database: HrafnDatabase, _ account: Account, peer: String = romeo) throws -> Int {
    try database.writer.read { db in
        try Conversation.fetchOne(db, key: ["accountID": account.id, "peer": peer])?.unreadCount ?? -1
    }
}

private func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

extension MessageEvent {
    static func incoming(_ account: Account, _ body: String, id: String, archiveID: String? = nil,
                         at seconds: TimeInterval, markable: Bool = true, read: Bool = false) -> MessageEvent {
        MessageEvent(accountID: account.id, peer: romeo, isOutgoing: false, content: .body(body, markable: markable),
                     senderID: id, stanzaID: id, archiveID: archiveID, timestamp: t(seconds), alreadyRead: read)
    }
}

@Suite struct IngestTests {

    /// The same message live, as a carbon and from the archive: one row, the
    /// archive id filled in by whichever copy has it.
    @Test func deduplicatesAcrossPaths() throws {
        let (database, account) = try makeStore()
        #expect(try database.ingest(.incoming(account, "hi", id: "m1", at: 1)) == .inserted(1))
        #expect(try database.ingest(.incoming(account, "hi", id: "m1", archiveID: "A1", at: 1)) == .merged(1))
        #expect(try database.ingest(.incoming(account, "hi", id: "m1", archiveID: "A1", at: 1)) == .duplicate)
        #expect(try database.ingest(.incoming(account, "hi", id: "m1", at: 1)) == .duplicate)
        // Archive id alone (a sender that sets no id) is still enough.
        #expect(try database.ingest(.incoming(account, "x", id: "other", archiveID: "A1", at: 1)) == .duplicate)
        let stored = try rows(database, account)
        #expect(stored.count == 1)
        #expect(stored[0].archiveID == "A1")
        #expect(try unread(database, account) == 1)
    }

    /// Our own message: stored when written, then echoed back as a carbon or
    /// archive copy with the same origin id.
    @Test func mergesEchoesOfOwnMessages() throws {
        let (database, account) = try makeStore()
        let sent = try database.insertOutgoing(accountID: account.id, peer: romeo, body: "hello", id: "o1",
                                               state: .sent, timestamp: t(5))
        let echo = MessageEvent(accountID: account.id, peer: romeo, isOutgoing: true, content: .body("hello", markable: true),
                                senderID: "o1", stanzaID: "o1", archiveID: "A9", timestamp: t(6))
        #expect(try database.ingest(echo) == .merged(sent.id!))
        #expect(try rows(database, account).map(\.archiveID) == ["A9"])
        // An incoming message with the same id from them is a different message.
        #expect(try database.ingest(.incoming(account, "hello", id: "o1", at: 7)) != .duplicate)
    }

    @Test func receiptsAndMarkersAdvanceOutgoingState() throws {
        let (database, account) = try makeStore()
        let first = try database.insertOutgoing(accountID: account.id, peer: romeo, body: "a", id: "o1", state: .sent, timestamp: t(1))
        let second = try database.insertOutgoing(accountID: account.id, peer: romeo, body: "b", id: "o2", state: .sent, timestamp: t(2))
        let third = try database.insertOutgoing(accountID: account.id, peer: romeo, body: "c", id: "o3", state: .sent, timestamp: t(3))

        func from(_ content: MessageEvent.Content) -> MessageEvent {
            MessageEvent(accountID: account.id, peer: romeo, isOutgoing: false, content: content, timestamp: t(10))
        }
        #expect(try database.ingest(from(.receipt(for: "o1"))) == .updated(1))
        #expect(try database.message(id: first.id!)?.state == .delivered)
        // Displayed up to o2 covers o1 and o2, not o3.
        #expect(try database.ingest(from(.displayed(upTo: "o2"))) == .updated(2))
        #expect(try database.message(id: second.id!)?.state == .displayed)
        #expect(try database.message(id: third.id!)?.state == .sent)
        // A late receipt does not move a displayed message backwards.
        #expect(try database.ingest(from(.receipt(for: "o2"))) == .updated(0))
        #expect(try database.message(id: second.id!)?.state == .displayed)

        #expect(try database.ingest(from(.error(stanzaID: "o3", text: "service-unavailable"))) == .updated(1))
        #expect(try database.message(id: third.id!)?.state == .failed)
        #expect(try database.message(id: third.id!)?.errorText == "service-unavailable")
    }

    @Test func unreadFollowsReadingHereAndElsewhere() throws {
        let (database, account) = try makeStore()
        try database.ingest(.incoming(account, "1", id: "i1", at: 1))
        try database.ingest(.incoming(account, "2", id: "i2", at: 2))
        try database.ingest(.incoming(account, "3", id: "i3", at: 3, markable: false))
        #expect(try unread(database, account) == 3)

        // Our other device displayed up to i2 (a sent-carbon marker).
        let elsewhere = MessageEvent(accountID: account.id, peer: romeo, isOutgoing: true,
                                     content: .displayed(upTo: "i2"), timestamp: t(4))
        #expect(try database.ingest(elsewhere) == .updated(2))
        #expect(try unread(database, account) == 1)

        // Reading here returns the newest markable message to mark.
        #expect(try database.markConversationRead(accountID: account.id, peer: romeo) == "i2")
        #expect(try unread(database, account) == 0)
        #expect(try database.markConversationRead(accountID: account.id, peer: romeo) == nil)

        // Replying implies having read.
        try database.ingest(.incoming(account, "4", id: "i4", at: 5))
        _ = try database.insertOutgoing(accountID: account.id, peer: romeo, body: "reply", id: "o1", timestamp: t(6))
        #expect(try unread(database, account) == 0)

        // History from a first login arrives read.
        try database.ingest(.incoming(account, "old", id: "i0", archiveID: "A0", at: 0, read: true))
        #expect(try unread(database, account) == 0)
    }

    @Test func correctionsApplyInOrderAndOnce() throws {
        let (database, account) = try makeStore()
        try database.ingest(.incoming(account, "helo", id: "i1", at: 1))
        func fix(_ body: String, id: String, at seconds: TimeInterval, outgoing: Bool = false) -> MessageEvent {
            MessageEvent(accountID: account.id, peer: romeo, isOutgoing: outgoing, content: .correction(of: "i1", body: body),
                         senderID: id, archiveID: "E-\(id)", timestamp: t(seconds))
        }
        #expect(try database.ingest(fix("hello!", id: "c2", at: 3)) == .edited(1))
        // An older correction arriving late does not win.
        #expect(try database.ingest(fix("hello", id: "c1", at: 2)) == .edited(1))
        #expect(try rows(database, account)[0].body == "hello!")
        #expect(try database.ingest(fix("hello!", id: "c2", at: 3)) == .duplicate)
        // XEP-0308 §5: we cannot correct their message.
        #expect(try database.ingest(fix("pwned", id: "c3", at: 4, outgoing: true)) == .deferred)
        #expect(try rows(database, account)[0].body == "hello!")
        #expect(try rows(database, account)[0].editedAt == t(3))
    }

    /// Archive pages are not always in order, and ejabberd deletes a retracted
    /// original from the archive: an edit must wait for its target.
    @Test func editsWaitForTheirTarget() throws {
        let (database, account) = try makeStore()
        let retraction = MessageEvent(accountID: account.id, peer: romeo, isOutgoing: false,
                                      content: .retraction(of: "i1"), senderID: "r1", archiveID: "A2", timestamp: t(2))
        #expect(try database.ingest(retraction) == .deferred)
        #expect(try database.ingest(.incoming(account, "oops", id: "i1", archiveID: "A1", at: 1)) == .inserted(1))
        let stored = try rows(database, account)[0]
        #expect(stored.isRetracted)
        #expect(stored.body.isEmpty)
        // Retracted messages are not unread.
        #expect(try unread(database, account) == 0)
        // A correction after a retraction changes nothing.
        let late = MessageEvent(accountID: account.id, peer: romeo, isOutgoing: false,
                                content: .correction(of: "i1", body: "back"), senderID: "c9", timestamp: t(3))
        _ = try database.ingest(late)
        #expect(try rows(database, account)[0].body.isEmpty)
    }

    @Test func outboxHoldsPendingMessagesInOrder() throws {
        let (database, account) = try makeStore()
        let a = try database.insertOutgoing(accountID: account.id, peer: romeo, body: "a", id: "o1", timestamp: t(1))
        _ = try database.insertOutgoing(accountID: account.id, peer: romeo, body: "b", id: "o2", state: .sent, timestamp: t(2))
        let c = try database.insertOutgoing(accountID: account.id, peer: romeo, body: "c", id: "o3", timestamp: t(3))
        #expect(try database.outbox(accountID: account.id).map(\.id) == [a.id, c.id])
        try database.setState(messageID: a.id!, .sent)
        #expect(try database.outbox(accountID: account.id).map(\.id) == [c.id])
    }
}

@Suite struct RosterStoreTests {

    @Test func versionedRosterWithPushesAndPendingRequests() throws {
        let (database, account) = try makeStore()
        try database.setPendingIn(accountID: account.id, jid: "stranger@example.org", true)
        try database.replaceRoster(accountID: account.id, entries: [
            RosterEntry(jid: romeo, name: "Romeo", subscription: .both, pendingOut: false, groups: ["Friends"]),
        ], version: "v1")
        var contacts = try database.fetchContacts(accountID: account.id)
        #expect(Set(contacts.map(\.jid)) == [romeo, "stranger@example.org"])
        #expect(contacts.first { $0.jid == "stranger@example.org" }?.inRoster == false)
        #expect(try database.account(id: account.id)?.rosterVersion == "v1")

        // Approving the stranger: they appear in the roster with from, and the
        // request is answered.
        try database.applyRosterPush(accountID: account.id, entry: RosterEntry(
            jid: "stranger@example.org", name: nil, subscription: .from, pendingOut: false, groups: []),
            removed: false, version: "v2")
        contacts = try database.fetchContacts(accountID: account.id)
        #expect(contacts.first { $0.jid == "stranger@example.org" }?.pendingIn == false)
        #expect(contacts.first { $0.jid == "stranger@example.org" }?.inRoster == true)

        try database.applyRosterPush(accountID: account.id, entry: RosterEntry(
            jid: romeo, name: nil, subscription: .none, pendingOut: false, groups: []), removed: true, version: "v3")
        #expect(try database.fetchContacts(accountID: account.id).map(\.jid) == ["stranger@example.org"])
        #expect(try database.account(id: account.id)?.rosterVersion == "v3")
    }

    @Test func deletingAnAccountDeletesItsData() throws {
        let (database, account) = try makeStore()
        try database.ingest(.incoming(account, "hi", id: "m1", at: 1))
        try database.replaceBlocklist(accountID: account.id, jids: ["spam@example.org"])
        try database.deleteAccount(id: account.id)
        let counts = try database.writer.read { db in
            [try StoredMessage.fetchCount(db), try Conversation.fetchCount(db), try BlockedJID.fetchCount(db)]
        }
        #expect(counts == [0, 0, 0])
    }

    @Test func observationEmitsOnChange() async throws {
        let (database, account) = try makeStore()
        var iterator = database.conversations().makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)
        try database.ingest(.incoming(account, "hi", id: "m1", at: 1))
        let summaries = try #require(try await iterator.next())
        #expect(summaries.count == 1)
        #expect(summaries[0].lastMessage?.body == "hi")
        #expect(summaries[0].conversation.unreadCount == 1)
    }

    @Test func persistsToDiskInWALMode() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hrafn-\(UUID().uuidString)/Hrafn.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let database = try HrafnDatabase(url: url)
            try database.save(Account(id: "a", jid: "juliet@example.com"))
        }
        let reopened = try HrafnDatabase(url: url)
        #expect(try reopened.allAccounts().map(\.jid) == ["juliet@example.com"])
        let mode = try reopened.writer.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
        #expect(mode == "wal")
    }
}

@Suite struct NotificationTests {

    @Test func eachIncomingMessageIsClaimedOnce() throws {
        let (database, account) = try makeStore()
        try database.ingest(.incoming(account, "one", id: "a", at: 1))
        try database.ingest(.incoming(account, "history", id: "h", at: 0, read: true))
        _ = try database.insertOutgoing(accountID: account.id, peer: romeo, body: "mine", id: "o", timestamp: t(0.5))
        try database.ingest(.incoming(account, "two", id: "b", at: 2))

        #expect(try database.pendingNotifications().map(\.message.body) == ["one", "two"])
        let claimed = try database.claimPendingNotifications()
        #expect(claimed.map(\.message.body) == ["one", "two"])
        #expect(claimed.first?.title == romeo)
        #expect(claimed.first?.threadID == account.id + "|" + romeo)
        #expect(try database.claimPendingNotifications().isEmpty)
        // A copy from the archive is a duplicate, not a new announcement.
        try database.ingest(.incoming(account, "one", id: "a", archiveID: "arch-1", at: 1))
        #expect(try database.pendingNotifications().isEmpty)
    }

    @Test func readAndRetractedMessagesAreNotAnnounced() throws {
        let (database, account) = try makeStore()
        try database.ingest(.incoming(account, "seen elsewhere", id: "a", at: 1))
        try database.ingest(.incoming(account, "oops", id: "b", at: 2))
        _ = try database.markConversationRead(accountID: account.id, peer: romeo)
        try database.ingest(.incoming(account, "later", id: "c", at: 3))
        try database.ingest(MessageEvent(accountID: account.id, peer: romeo, isOutgoing: false,
                                         content: .retraction(of: "c"), senderID: "r", timestamp: t(4)))
        #expect(try database.pendingNotifications().isEmpty)
    }

    /// Banners stay only for unread messages: one read on another device
    /// (its displayed marker) or retracted drops out.
    @Test func unreadMessageIDsLeaveOutReadAndRetracted() throws {
        let (database, account) = try makeStore()
        try database.ingest(.incoming(account, "one", id: "a", at: 1))
        try database.ingest(.incoming(account, "two", id: "b", at: 2))
        try database.ingest(.incoming(account, "three", id: "c", at: 3))
        let ids = try database.writer.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM message ORDER BY timestamp")
        }
        #expect(try database.fetchUnreadMessageIDs() == Set(ids))

        try database.ingest(MessageEvent(accountID: account.id, peer: romeo, isOutgoing: true,
                                         content: .displayed(upTo: "a"), senderID: "m", timestamp: t(4)))
        try database.ingest(MessageEvent(accountID: account.id, peer: romeo, isOutgoing: false,
                                         content: .retraction(of: "c"), senderID: "r", timestamp: t(5)))
        #expect(try database.fetchUnreadMessageIDs() == [ids[1]])
    }

    @Test func mutedConversationsAreFlagged() throws {
        let (database, account) = try makeStore()
        try database.setMuted(accountID: account.id, peer: romeo, true)
        try database.ingest(.incoming(account, "hush", id: "a", at: 1))
        let claimed = try database.claimPendingNotifications()
        #expect(claimed.count == 1)
        #expect(claimed.first?.muted == true)
        // Mute survives activity in the conversation.
        try database.ingest(.incoming(account, "more", id: "b", at: 2))
        #expect(try database.pendingNotifications().first?.muted == true)
        #expect(try database.unreadTotal() == 2)
    }

    @Test func existingMessagesAreNotAnnouncedAfterMigrating() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hrafn-migrate-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        // A v1 database with an unread message in it.
        let pool = try DatabasePool(path: url.path)
        try HrafnDatabase.migrator.migrate(pool, upTo: "v1")
        try pool.write { db in
            try db.execute(sql: "INSERT INTO account (id, jid, directTLS, enabled, createdAt) VALUES ('x', 'j@example.com', 1, 1, ?)",
                           arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO message (accountID, peer, isOutgoing, body, timestamp, state, isRetracted, isMarkable)
                VALUES ('x', 'r@example.com', 0, 'old', ?, 'received', 0, 0)
                """, arguments: [Date()])
        }
        try pool.close()
        let database = try HrafnDatabase(url: url)
        #expect(try database.pendingNotifications().isEmpty)
    }
}
