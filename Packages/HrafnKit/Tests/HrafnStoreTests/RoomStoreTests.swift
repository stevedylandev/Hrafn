import Testing
import Foundation
import GRDB
@testable import HrafnStore

private let verona = "verona@conference.example.com"
private let mantua = "mantua@conference.example.com"

private func makeStore() throws -> (HrafnDatabase, Account) {
    let database = try HrafnDatabase()
    let account = Account(jid: "juliet@example.com")
    try database.save(account)
    return (database, account)
}

private func rows(_ database: HrafnDatabase, _ account: Account, room: String = verona) throws -> [StoredMessage] {
    try database.writer.read { db in
        try StoredMessage.filter(Column("accountID") == account.id && Column("peer") == room)
            .order(Column("timestamp"), Column("id")).fetchAll(db)
    }
}

private func unread(_ database: HrafnDatabase, _ account: Account, room: String = verona) throws -> Int {
    try database.writer.read { db in
        try Conversation.fetchOne(db, key: ["accountID": account.id, "peer": room])?.unreadCount ?? -1
    }
}

private func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

private func roomEvent(_ account: Account, _ content: MessageEvent.Content, from nick: String, occupant: String? = nil,
                       id: String, archiveID: String? = nil, outgoing: Bool = false, room: String = verona,
                       at seconds: TimeInterval, mentions: Bool = false, read: Bool = false) -> MessageEvent {
    MessageEvent(accountID: account.id, peer: room, isOutgoing: outgoing, content: content, senderID: id, stanzaID: id,
                 archiveID: archiveID, timestamp: t(seconds), alreadyRead: read,
                 sender: .init(nick: nick, occupantID: occupant), mentionsMe: mentions)
}

@Suite struct RoomIngestTests {

    /// XEP-0425: the room takes down anyone's message by its room id — ours
    /// or another occupant's — even when the notice comes first, and once.
    @Test func moderationRemovesAnyonesMessage() throws {
        let (database, account) = try makeStore()
        func moderation(_ target: String, at seconds: TimeInterval) -> MessageEvent {
            MessageEvent(accountID: account.id, peer: verona, isOutgoing: false,
                         content: .moderation(of: target, by: "Prince", reason: "Brawling"),
                         senderID: "m-\(target)", archiveID: "M-\(target)", timestamp: t(seconds))
        }
        try database.ingest(roomEvent(account, .body("Draw!", markable: false), from: "Tybalt", id: "t1",
                                      archiveID: "S1", at: 1))
        try database.ingest(roomEvent(account, .body("Peace!", markable: false), from: "Juliet", id: "o1",
                                      archiveID: "S2", outgoing: true, at: 2))
        #expect(try database.ingest(moderation("S1", at: 3)) != .deferred)
        #expect(try database.ingest(moderation("S1", at: 3)) == .duplicate)
        try database.ingest(moderation("S2", at: 4))
        // Before its target: waits, and applies when the message arrives.
        try database.ingest(moderation("S3", at: 5))
        try database.ingest(roomEvent(account, .body("Late", markable: false), from: "Mercutio", id: "m1",
                                      archiveID: "S3", at: 6))

        let stored = try rows(database, account)
        #expect(stored.allSatisfy { $0.isRetracted && $0.body.isEmpty && $0.moderatedBy == "Prince" })
        #expect(stored.allSatisfy { $0.moderationReason == "Brawling" })
        #expect(stored.first?.preview == "Removed by a moderator")
        #expect(try unread(database, account) == 0)
    }

    /// Our message: stored pending, sent, then the room's reflection marks it
    /// delivered and gives it the room's id; the archive copy is a duplicate.
    @Test func reflectionDeliversOurMessage() throws {
        let (database, account) = try makeStore()
        try database.updateRoom(accountID: account.id, jid: verona) { $0.autojoin = true }
        let row = try database.insertOutgoing(accountID: account.id, room: verona, nick: "Juliet", body: "hi", id: "o1",
                                              timestamp: t(0))
        try database.markSent(messageID: row.id!)
        let reflection = roomEvent(account, .body("hi", markable: false), from: "Juliet", occupant: "oJ", id: "o1",
                                   archiveID: "S1", outgoing: true, at: 1)
        #expect(try database.ingest(reflection) == .merged(row.id!))
        #expect(try database.ingest(reflection) == .duplicate)
        let stored = try rows(database, account)
        #expect(stored.count == 1)
        #expect(stored[0].state == .delivered && stored[0].archiveID == "S1" && stored[0].occupantID == "oJ")
        // A late markSent does not move it back.
        try database.markSent(messageID: row.id!)
        #expect(try rows(database, account)[0].state == .delivered)
    }

    /// Only the sender may edit: an occupant reusing another's id is ignored.
    @Test func onlyTheSameOccupantMayCorrectOrRetract() throws {
        let (database, account) = try makeStore()
        _ = try database.ingest(roomEvent(account, .body("original", markable: false), from: "Romeo", occupant: "oR",
                                          id: "m1", archiveID: "S1", at: 0))
        let forged = roomEvent(account, .correction(of: "m1", body: "forged"), from: "Tybalt", occupant: "oT",
                               id: "e1", archiveID: "S2", at: 1)
        #expect(try database.ingest(forged) == .deferred)
        #expect(try rows(database, account)[0].body == "original")

        // Same occupant under a new nick: allowed.
        let genuine = roomEvent(account, .correction(of: "m1", body: "fixed"), from: "Romeo2", occupant: "oR",
                                id: "e2", archiveID: "S3", at: 2)
        #expect(try database.ingest(genuine) == .edited(try rows(database, account)[0].id!))
        #expect(try rows(database, account)[0].body == "fixed")

        // Retractions name the room's id (XEP-0424 in groupchat).
        let retraction = roomEvent(account, .retraction(of: "S1"), from: "Romeo", occupant: "oR", id: "r1",
                                   archiveID: "S4", at: 3)
        #expect(try database.ingest(retraction) != .deferred)
        #expect(try rows(database, account)[0].isRetracted)
    }

    /// Without occupant ids, the nick decides; a retraction arriving before
    /// its target waits for it.
    @Test func deferredRetractionByRoomID() throws {
        let (database, account) = try makeStore()
        #expect(try database.ingest(roomEvent(account, .retraction(of: "S1"), from: "Romeo", id: "r1",
                                              archiveID: "S9", at: 5)) == .deferred)
        _ = try database.ingest(roomEvent(account, .body("oops", markable: false), from: "Romeo", id: "m1",
                                          archiveID: "S1", at: 0))
        #expect(try rows(database, account)[0].isRetracted)
        #expect(try unread(database, account) == 0)

        // Not by someone else of the same id.
        #expect(try database.ingest(roomEvent(account, .retraction(of: "S2"), from: "Tybalt", id: "r2",
                                              archiveID: "S8", at: 6)) == .deferred)
        _ = try database.ingest(roomEvent(account, .body("mine", markable: false), from: "Romeo", id: "m2",
                                          archiveID: "S2", at: 1))
        #expect(try !rows(database, account)[1].isRetracted)
    }

    /// Rooms are separate archives: the same id in two rooms is two messages.
    @Test func archiveIDsArePerRoom() throws {
        let (database, account) = try makeStore()
        _ = try database.ingest(roomEvent(account, .body("a", markable: false), from: "R", id: "x1", archiveID: "1700",
                                          at: 0))
        #expect(try database.ingest(roomEvent(account, .body("b", markable: false), from: "R", id: "x2",
                                              archiveID: "1700", room: mantua, at: 0)) != .duplicate)
        #expect(try rows(database, account).count == 1)
        #expect(try rows(database, account, room: mantua).count == 1)
    }

    @Test func notificationLevelsAndBadge() throws {
        let (database, account) = try makeStore()
        // A channel (default: mentions) and a private group (default: always).
        try database.updateRoom(accountID: account.id, jid: verona) { _ in }
        try database.updateRoom(accountID: account.id, jid: mantua) {
            $0.isMembersOnly = true
            $0.isNonAnonymous = true
        }
        _ = try database.ingest(roomEvent(account, .body("chatter", markable: false), from: "R", id: "1", at: 0))
        _ = try database.ingest(roomEvent(account, .body("juliet?", markable: false), from: "R", id: "2", at: 1,
                                          mentions: true))
        _ = try database.ingest(roomEvent(account, .body("group", markable: false), from: "R", id: "3", room: mantua,
                                          at: 2))
        _ = try database.ingest(roomEvent(account, .body("history", markable: false), from: "R", id: "4", room: mantua,
                                          at: 3, read: true))

        let pending = try database.pendingNotifications()
        #expect(pending.map(\.message.body) == ["chatter", "juliet?", "group"])
        #expect(pending.filter { !$0.muted }.map(\.message.body) == ["juliet?", "group"])
        #expect(pending.first { $0.message.body == "group" }?.title == "mantua")
        #expect(pending.first { $0.message.body == "group" }?.sender == "R")
        #expect(try unread(database, account) == 2)
        #expect(try database.unreadTotal() == 2)

        try database.updateRoom(accountID: account.id, jid: verona) { $0.notify = .always }
        try database.updateRoom(accountID: account.id, jid: mantua) { $0.notify = .never }
        #expect(try database.pendingNotifications().filter { !$0.muted }.map(\.message.body) == ["chatter", "juliet?"])
        #expect(try database.unreadTotal() == 2)
    }

    @Test func bookmarksReplaceWithoutLosingRooms() throws {
        let (database, account) = try makeStore()
        func entry(_ jid: String, autojoin: Bool = true) -> BookmarkEntry {
            BookmarkEntry(jid: jid, name: nil, nick: "J", password: nil, autojoin: autojoin, extensions: "<x/>")
        }
        try database.replaceBookmarks(accountID: account.id, [entry(verona), entry(mantua)])
        try database.updateRoom(accountID: account.id, jid: verona) { $0.subject = "kept" }
        try database.replaceBookmarks(accountID: account.id, [entry(mantua, autojoin: false)])
        let v = try #require(try database.fetchRoom(accountID: account.id, jid: verona))
        #expect(!v.bookmarked && !v.autojoin && v.subject == "kept")
        let m = try #require(try database.fetchRoom(accountID: account.id, jid: mantua))
        #expect(m.bookmarked && !m.autojoin && m.bookmarkExtensions == "<x/>")

        try database.removeBookmark(accountID: account.id, jid: mantua)
        #expect(try database.fetchRoom(accountID: account.id, jid: mantua)?.bookmarked == false)
        try database.deleteRoom(accountID: account.id, jid: verona)
        #expect(try database.fetchRoom(accountID: account.id, jid: verona) == nil)
    }

    @Test func conversationSummariesNameRooms() throws {
        let (database, account) = try makeStore()
        try database.updateRoom(accountID: account.id, jid: verona) { $0.name = "Verona" }
        _ = try database.ingest(roomEvent(account, .body("hi", markable: false), from: "R", id: "1", at: 0))
        let summaries = try database.writer.read { db in try HrafnDatabase.conversationSummaries(db) }
        #expect(summaries.count == 1)
        #expect(summaries[0].isRoom && summaries[0].title == "Verona")
        #expect(summaries[0].lastMessage?.senderNick == "R")
    }
}
