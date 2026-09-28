import Testing
import Foundation
import GRDB
@testable import HrafnStore

private let romeo = "romeo@example.net"
private let tybalt = "tybalt@example.net"

private func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

@Suite struct SearchTests {
    private let database: HrafnDatabase
    private let account = Account(jid: "juliet@example.com")

    init() throws {
        database = try HrafnDatabase()
        try database.save(account)
    }

    private func say(_ body: String, id: String, peer: String = romeo, at seconds: TimeInterval,
                     attachment: HrafnStore.Attachment? = nil) throws {
        try database.ingest(MessageEvent(accountID: account.id, peer: peer, isOutgoing: false,
                                         content: .body(body, markable: true), senderID: id, stanzaID: id,
                                         timestamp: t(seconds), attachment: attachment))
    }

    private func found(_ query: String, accountIDs: [String]? = nil) throws -> [String] {
        try database.searchMessages(query, accountIDs: accountIDs).map(\.body)
    }

    @Test func findsWordsByPrefixNewestFirstIgnoringCaseAndAccents() throws {
        try say("Meet me at the Café tonight", id: "a", at: 1)
        try say("The café is closed", id: "b", peer: tybalt, at: 2)
        try say("nothing to see", id: "c", at: 3)
        #expect(try found("cafe") == ["The café is closed", "Meet me at the Café tonight"])
        #expect(try found("CAF") == ["The café is closed", "Meet me at the Café tonight"])
        #expect(try found("caf toni") == ["Meet me at the Café tonight"])
        #expect(try found("dragons").isEmpty)
    }

    @Test func blankOrPunctuationOnlyQueriesFindNothing() throws {
        try say("hello", id: "a", at: 1)
        #expect(try found("").isEmpty)
        #expect(try found("   ").isEmpty)
        #expect(try found("\"*()").isEmpty)
    }

    @Test func followsCorrectionsAndRetractions() throws {
        try say("helo wrold", id: "a", at: 1)
        try database.ingest(MessageEvent(accountID: account.id, peer: romeo, isOutgoing: false,
                                         content: .correction(of: "a", body: "hello world"), senderID: "c",
                                         timestamp: t(2)))
        #expect(try found("wrold").isEmpty)
        #expect(try found("world") == ["hello world"])
        try database.ingest(MessageEvent(accountID: account.id, peer: romeo, isOutgoing: false,
                                         content: .retraction(of: "a"), senderID: "r", timestamp: t(3)))
        #expect(try found("world").isEmpty)
    }

    @Test func leavesOutSharedFiles() throws {
        let url = URL(string: "https://up.example.net/cat.png")!
        try say(url.absoluteString, id: "f", at: 1,
                attachment: HrafnStore.Attachment(url: url, fileName: "cat.png", mimeType: "image/png"))
        try say("look at https://example.org", id: "m", at: 2)
        #expect(try found("https") == ["look at https://example.org"])
    }

    @Test func limitsToTheGivenAccounts() throws {
        try say("hello", id: "a", at: 1)
        #expect(try found("hello", accountIDs: [account.id]).count == 1)
        #expect(try found("hello", accountIDs: ["other"]).isEmpty)
    }

    @Test func countsTheWindowAChatMustLoad() throws {
        for index in 0..<5 { try say("m\(index)", id: "m\(index)", at: TimeInterval(index)) }
        let target = try #require(try database.searchMessages("m1").first?.id)
        #expect(try database.messagesNewer(than: target, accountID: account.id, peer: romeo) == 3)
    }

    /// Messages stored before the index existed are indexed by the migration.
    @Test func migrationIndexesExistingHistory() throws {
        let queue = try DatabaseQueue()
        var migrator = HrafnDatabase.migrator
        try migrator.migrate(queue, upTo: "v5")
        try queue.write { db in
            // The record has columns this schema has not reached yet.
            try db.execute(sql: """
                INSERT INTO account (id, jid, directTLS, enabled, createdAt) VALUES (?, ?, 1, 1, ?)
                """, arguments: [account.id, account.jid, t(0)])
            try db.execute(sql: """
                INSERT INTO message (accountID, peer, isOutgoing, body, timestamp, state, isRetracted, isMarkable)
                VALUES (?, ?, 0, 'written before search', ?, 'received', 0, 1)
                """, arguments: [account.id, romeo, t(1)])
        }
        migrator = HrafnDatabase.migrator
        try migrator.migrate(queue)
        let count = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM messageSearch WHERE messageSearch MATCH 'before'")
        }
        #expect(count == 1)
    }

    /// Notes to self stored twice, once as an incoming echo, are stored once.
    @Test func migrationDropsEchoedNotesToSelf() throws {
        let queue = try DatabaseQueue()
        var migrator = HrafnDatabase.migrator
        try migrator.migrate(queue, upTo: "v8")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO account (id, jid, directTLS, enabled, createdAt) VALUES (?, 'Juliet@example.com', 1, 1, ?)
                """, arguments: [account.id, t(0)])
            for (outgoing, body, originID) in [(1, "milk", "n1"), (0, "milk", "n1"), (0, "from my tablet", "n2")] {
                try db.execute(sql: """
                    INSERT INTO message (accountID, peer, isOutgoing, body, timestamp, state, isRetracted, isMarkable, originID)
                    VALUES (?, 'juliet@example.com', ?, ?, ?, 'received', 0, 1, ?)
                    """, arguments: [account.id, outgoing, body, t(1), originID])
            }
        }
        migrator = HrafnDatabase.migrator
        try migrator.migrate(queue)
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT body, isOutgoing FROM message ORDER BY body")
                .map { ($0["body"] as String, $0["isOutgoing"] as Bool) }
        }
        #expect(rows.map(\.0) == ["from my tablet", "milk"])
        #expect(rows.allSatisfy { $0.1 })
    }
}
