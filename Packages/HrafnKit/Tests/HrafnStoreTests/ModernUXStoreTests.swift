import Testing
import Foundation
import GRDB
@testable import HrafnStore

private let romeo = "romeo@example.net"
private let verona = "verona@rooms.example.net"

private func makeStore() throws -> (HrafnDatabase, Account) {
    let database = try HrafnDatabase()
    let account = Account(jid: "juliet@example.com")
    try database.save(account)
    return (database, account)
}

private func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

private func reactions(_ database: HrafnDatabase, _ account: Account, peer: String = romeo) throws -> [String: [ReactionCount]] {
    try database.writer.read { db in
        ReactionCount.summaries(try Reaction.filter(Column("accountID") == account.id && Column("peer") == peer).fetchAll(db))
    }
}

private func unread(_ database: HrafnDatabase, _ account: Account, peer: String = romeo) throws -> Int {
    try database.writer.read { db in
        try Conversation.fetchOne(db, key: ["accountID": account.id, "peer": peer])?.unreadCount ?? -1
    }
}

private func react(_ account: Account, _ emojis: [String], to target: String, outgoing: Bool = false, at seconds: TimeInterval,
                   peer: String = romeo, sender: MessageEvent.RoomSender? = nil) -> MessageEvent {
    MessageEvent(accountID: account.id, peer: peer, isOutgoing: outgoing, content: .reactions(to: target, emojis),
                 senderID: UUID().uuidString, timestamp: t(seconds), sender: sender)
}

private func incoming(_ account: Account, _ body: String, id: String, archiveID: String?, at seconds: TimeInterval,
                      peer: String = romeo) -> MessageEvent {
    MessageEvent(accountID: account.id, peer: peer, isOutgoing: false, content: .body(body, markable: true),
                 senderID: id, stanzaID: id, archiveID: archiveID, timestamp: t(seconds))
}

@Suite struct ReactionStoreTests {

    /// Each set replaces the sender's last one; an older set arriving later
    /// (the archive) changes nothing, and taking all away is remembered.
    @Test func newestSetWins() throws {
        let (database, account) = try makeStore()
        try database.ingest(react(account, ["👍", "😂"], to: "m1", at: 1))
        #expect(try reactions(database, account)["m1"]?.map(\.emoji) == ["👍", "😂"])
        try database.ingest(react(account, ["❤️"], to: "m1", at: 3))
        try database.ingest(react(account, ["👍"], to: "m1", at: 2))
        #expect(try reactions(database, account)["m1"]?.map(\.emoji) == ["❤️"])
        try database.ingest(react(account, [], to: "m1", at: 4))
        try database.ingest(react(account, ["👍"], to: "m1", at: 3.5))
        #expect(try reactions(database, account)["m1"] == nil)
    }

    @Test func countsAcrossSendersAndMarksOurOwn() throws {
        let (database, account) = try makeStore()
        try database.ingest(react(account, ["👍"], to: "m1", at: 1))
        try database.ingest(react(account, ["👍", "🎉"], to: "m1", outgoing: true, at: 2))
        try database.ingest(react(account, ["🎉"], to: "m2", outgoing: true, at: 2))
        let counts = try reactions(database, account)
        #expect(counts["m1"] == [
            ReactionCount(emoji: "👍", count: 2, includesMe: true, senders: []),
            ReactionCount(emoji: "🎉", count: 1, includesMe: true, senders: []),
        ])
        #expect(counts["m2"]?.first?.count == 1)
        #expect(try database.ownReactions(accountID: account.id, peer: romeo, targetID: "m1") == ["👍", "🎉"])
        #expect(try database.ownReactions(accountID: account.id, peer: romeo, targetID: "none") == [])
        // Reactions are not messages: nothing unread, no conversation.
        #expect(try unread(database, account) == -1)
    }

    /// In a room each occupant has a set of their own, by occupant id when
    /// the room vouches for one, else by nick.
    @Test func roomSendersAreKeptApart() throws {
        let (database, account) = try makeStore()
        try database.ingest(react(account, ["👍"], to: "S1", at: 1, peer: verona,
                                  sender: .init(nick: "Romeo", occupantID: "oR")))
        try database.ingest(react(account, ["👍"], to: "S1", at: 1, peer: verona, sender: .init(nick: "Tybalt")))
        // Romeo, renamed, changes his set rather than adding one.
        try database.ingest(react(account, ["😢"], to: "S1", at: 2, peer: verona,
                                  sender: .init(nick: "Montague", occupantID: "oR")))
        let counts = try reactions(database, account, peer: verona)["S1"]
        #expect(counts?.map(\.emoji) == ["👍", "😢"])
        #expect(counts?.first?.senders == ["Tybalt"])
        #expect(counts?.last?.senders == ["Montague"])
        // Nobody to attribute it to: ignored.
        #expect(try database.ingest(react(account, ["👍"], to: "S1", at: 3, peer: verona, sender: .init(nick: nil)))
                == .updated(0))
    }

    @Test func deletedWithTheConversation() throws {
        let (database, account) = try makeStore()
        try database.ingest(incoming(account, "hi", id: "m1", archiveID: nil, at: 1))
        try database.ingest(react(account, ["👍"], to: "m1", at: 2))
        try database.deleteConversation(accountID: account.id, peer: romeo)
        #expect(try reactions(database, account).isEmpty)
    }
}

@Suite struct ReplyStoreTests {

    @Test func repliesAreStoredAndFoundByReference() throws {
        let (database, account) = try makeStore()
        try database.ingest(incoming(account, "hello", id: "m1", archiveID: "A1", at: 1))
        var event = incoming(account, "hi yourself", id: "m2", archiveID: "A2", at: 2)
        event.reply = ReplyReference(id: "m1", to: "juliet@example.com", quote: "hello")
        try database.ingest(event)
        let reply = try #require(try database.message(accountID: account.id, peer: romeo, referenceID: "m2", inRoom: false))
        #expect(reply.reply == ReplyReference(id: "m1", to: "juliet@example.com", quote: "hello"))
        #expect(reply.body == "hi yourself")
        let original = try database.message(accountID: account.id, peer: romeo, referenceID: reply.replyToID!, inRoom: false)
        #expect(original?.body == "hello")
        // In a room the reference is the room's id.
        #expect(original?.referenceID(inRoom: true) == "A1")
        #expect(try database.message(accountID: account.id, peer: romeo, referenceID: "A1", inRoom: true)?.body == "hello")
    }

    /// Our own reply, echoed back by the archive: one row, reply kept.
    @Test func ownRepliesMergeWithTheirEcho() throws {
        let (database, account) = try makeStore()
        let reply = ReplyReference(id: "m1", to: romeo, quote: "q")
        let sent = try database.insertOutgoing(accountID: account.id, peer: romeo, body: "answer", id: "o1",
                                               state: .sent, timestamp: t(1), reply: reply)
        #expect(sent.reply == reply)
        var echo = MessageEvent(accountID: account.id, peer: romeo, isOutgoing: true, content: .body("answer", markable: true),
                                senderID: "o1", stanzaID: "o1", archiveID: "A1", timestamp: t(1))
        echo.reply = reply
        #expect(try database.ingest(echo) == .merged(sent.id!))
        #expect(try database.message(id: sent.id!)?.reply == reply)
    }
}

@Suite struct DisplayedSyncStoreTests {

    /// Another device read up to A2: A1 and A2 are read, A3 is not.
    @Test func readsUpToTheMarker() throws {
        let (database, account) = try makeStore()
        for (index, id) in ["A1", "A2", "A3"].enumerated() {
            try database.ingest(incoming(account, id, id: "m\(index)", archiveID: id, at: TimeInterval(index)))
        }
        #expect(try unread(database, account) == 3)
        #expect(try database.applyDisplayedSync(accountID: account.id, peer: romeo, archiveID: "A2") == 2)
        #expect(try unread(database, account) == 1)
        // An older marker does not move ours back, and reads nothing new.
        #expect(try database.applyDisplayedSync(accountID: account.id, peer: romeo, archiveID: "A1") == 0)
        #expect(try database.displayedSyncCandidate(accountID: account.id, peer: romeo) == "A3")
    }

    /// The marker names a message not here yet: applied when it arrives.
    @Test func waitsForTheMarkedMessage() throws {
        let (database, account) = try makeStore()
        try database.ingest(incoming(account, "one", id: "m1", archiveID: "A1", at: 1))
        #expect(try database.applyDisplayedSync(accountID: account.id, peer: romeo, archiveID: "A2") == 0)
        #expect(try unread(database, account) == 1)
        // Someone else is ahead: nothing to publish from here.
        #expect(try database.displayedSyncCandidate(accountID: account.id, peer: romeo) == nil)
        try database.ingest(incoming(account, "two", id: "m2", archiveID: "A2", at: 2))
        #expect(try unread(database, account) == 0)
        try database.ingest(incoming(account, "three", id: "m3", archiveID: "A3", at: 3))
        #expect(try unread(database, account) == 1)
    }

    /// A message stored without its archive id (live, then the archive copy)
    /// is found once the id is merged in.
    @Test func waitsForTheArchiveIDToo() throws {
        let (database, account) = try makeStore()
        try database.ingest(incoming(account, "one", id: "m1", archiveID: nil, at: 1))
        try database.applyDisplayedSync(accountID: account.id, peer: romeo, archiveID: "A1")
        #expect(try unread(database, account) == 1)
        try database.ingest(incoming(account, "one", id: "m1", archiveID: "A1", at: 1))
        #expect(try unread(database, account) == 0)
    }

    @Test func publishesOnlyWhatIsNew() throws {
        let (database, account) = try makeStore()
        // Nothing with an archive id yet.
        try database.openConversation(accountID: account.id, peer: romeo)
        #expect(try database.displayedSyncCandidate(accountID: account.id, peer: romeo) == nil)
        try database.ingest(incoming(account, "one", id: "m1", archiveID: "A1", at: 1))
        #expect(try database.displayedSyncCandidate(accountID: account.id, peer: romeo) == "A1")
        try database.recordDisplayedSync(accountID: account.id, peer: romeo, archiveID: "A1")
        #expect(try database.displayedSyncCandidate(accountID: account.id, peer: romeo) == nil)
        try database.ingest(incoming(account, "two", id: "m2", archiveID: "A2", at: 2))
        #expect(try database.displayedSyncCandidate(accountID: account.id, peer: romeo) == "A2")
    }

    @Test func unknownConversationsAreIgnored() throws {
        let (database, account) = try makeStore()
        #expect(try database.applyDisplayedSync(accountID: account.id, peer: "nobody@example.net", archiveID: "A1") == 0)
        #expect(try database.displayedSyncCandidate(accountID: account.id, peer: "nobody@example.net") == nil)
    }
}
