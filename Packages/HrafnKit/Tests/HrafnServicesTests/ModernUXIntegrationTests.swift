import Testing
import Foundation
import GRDB
@testable import HrafnServices
import HrafnStore
import XMPPCore

/// Phase 8 end to end: reactions, replies and XEP-0490 read positions through
/// the sessions and the database, against the Docker servers. Off unless
/// `HRAFN_INTEGRATION=1`. Uses its own accounts (escalus, potpan).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HRAFN_INTEGRATION"] == "1"),
       .serialized, .timeLimit(.minutes(2)))
@MainActor
struct ModernUXIntegrationTests {

    private func reactions(_ device: Device, _ peer: String, on target: String?) throws -> [ReactionCount] {
        guard let target else { return [] }
        return try device.database.writer.read { db in
            ReactionCount.summaries(try Reaction.filter(Column("accountID") == device.account.id && Column("peer") == peer)
                .fetchAll(db))[target] ?? []
        }
    }

    /// A reply and reactions each way, on one server and across two.
    @Test(arguments: [(LiveServer.prosody, LiveServer.prosody), (LiveServer.ejabberd, LiveServer.ejabberd),
                      (LiveServer.prosody, LiveServer.ejabberd)])
    func chat(_ servers: (LiveServer, LiveServer)) async throws {
        let escalus = try await Device("escalus", on: servers.0)
        let potpan = try await Device("potpan", on: servers.1)
        try await closing([escalus, potpan]) {
            let escalusJID = escalus.account.jid
            let potpanJID = potpan.account.jid
            let text = "Rebellious subjects \(UUID())"
            let original = try await escalus.session.send(text, to: potpanJID)
            try await eventually("delivery") { try potpan.messages(with: escalusJID).contains { $0.body == text } }
            let received = try #require(try potpan.messages(with: escalusJID).first { $0.body == text })

            // The reply arrives without its quote, pointing at the original.
            let answer = try await potpan.session.send("Where's Potpan?", to: escalusJID, replyingTo: received.id)
            #expect(answer.replyToID == original.originID)
            try await eventually("reply") {
                try escalus.messages(with: potpanJID).contains { $0.originID == answer.originID }
            }
            let reply = try #require(try escalus.messages(with: potpanJID).first { $0.originID == answer.originID })
            #expect(reply.body == "Where's Potpan?")
            #expect(reply.replyToID == original.originID)
            #expect(reply.replyQuote == text)
            #expect(try escalus.database.message(accountID: escalus.account.id, peer: potpanJID,
                                                 referenceID: reply.replyToID!, inRoom: false)?.id == original.id)

            // Reactions: added, changed, taken away — each a full set.
            try await potpan.session.toggleReaction("👍", on: received.id!)
            try await eventually("reaction") {
                try reactions(escalus, potpanJID, on: original.originID).map(\.emoji) == ["👍"]
            }
            #expect(try reactions(potpan, escalusJID, on: received.originID).first?.includesMe == true)
            try await potpan.session.toggleReaction("🎉", on: received.id!)
            try await eventually("second reaction") {
                try reactions(escalus, potpanJID, on: original.originID).map(\.emoji) == ["👍", "🎉"]
            }
            try await potpan.session.toggleReaction("👍", on: received.id!)
            try await potpan.session.toggleReaction("🎉", on: received.id!)
            try await eventually("reactions removed") { try reactions(escalus, potpanJID, on: original.originID).isEmpty }

            try await escalus.session.toggleReaction("❤️", on: reply.id!)
            try await eventually("reaction to the reply") {
                try reactions(potpan, escalusJID, on: answer.originID).map(\.emoji) == ["❤️"]
            }
            // Reactions are not messages: nothing new to read (potpan read
            // everything when replying).
            #expect(try potpan.unread(escalusJID) == 0)
        }
    }

    /// In a room: replies and reactions by the room's ids, and read
    /// positions shared between two of escalus's devices through XEP-0490 —
    /// the only way they learn it in a room, which has no displayed markers.
    @Test(arguments: [LiveServer.prosody, LiveServer.ejabberd])
    func room(_ server: LiveServer) async throws {
        let phone = try await Device("escalus", on: server)
        let potpan = try await Device("potpan", on: server)
        var desktop: Device?
        try await closing([phone, potpan]) {
            let key = try await phone.session.createRoom(name: "Verona Square", kind: .channel)
            try await eventually("phone joined") { phone.status.room(key).isJoined }
            try await potpan.session.joinRoom(key)
            try await eventually("potpan joined") { potpan.status.room(key).isJoined }
            // The desktop joins from the bookmark the phone published.
            let second = try await Device("escalus", on: server)
            desktop = second
            try await eventually("desktop joined") { second.status.room(key).isJoined }

            // A message from escalus; potpan replies to it and reacts.
            let own = try await phone.session.send("Throw your mistempered weapons", to: key)
            try await eventually("reflection") { try phone.messages(with: key).first { $0.id == own.id }?.archiveID != nil }
            let ownID = try #require(try phone.messages(with: key).first { $0.id == own.id }?.archiveID)
            try await eventually("potpan has it") { try potpan.messages(with: key).contains { $0.archiveID == ownID } }
            let theirs = try #require(try potpan.messages(with: key).first { $0.archiveID == ownID })
            _ = try await potpan.session.send("Aye", to: key, replyingTo: theirs.id)
            try await eventually("reply in the room") {
                try phone.messages(with: key).contains { $0.body == "Aye" && $0.replyToID == ownID }
            }
            // A reply to us counts as a mention.
            #expect(try phone.messages(with: key).first { $0.body == "Aye" }?.mentionsMe == true)
            try await potpan.session.toggleReaction("😮", on: theirs.id!)
            try await eventually("room reaction") {
                let counts = try reactions(phone, key, on: ownID)
                return counts.map(\.emoji) == ["😮"] && counts.first?.senders == ["potpan"]
            }

            // Three messages, unread on both of escalus's devices.
            for n in 1...3 { _ = try await potpan.session.send("news \(n)", to: key) }
            try await eventually("unread on both") {
                try phone.unread(key) == 4 && second.unread(key) == 4
            }
            // The phone reads them; the desktop follows.
            await phone.session.setVisibleConversation(key)
            #expect(try phone.unread(key) == 0)
            try await withKnownIssue("ejabberd PEP notifications to our own resources", isIntermittent: true) {
                try await eventually("desktop reads too", timeout: .seconds(8)) { try second.unread(key) == 0 }
            } when: { server.domain == LiveServer.ejabberd.domain }
            await phone.session.setVisibleConversation(nil)

            // The desktop is off while more arrives and the phone reads it:
            // when it comes back, its catch-up finds the messages already
            // read — the marker was fetched before the room's history came.
            await second.manager.setEnabled(second.account.id, false)
            for n in 4...5 { _ = try await potpan.session.send("news \(n)", to: key) }
            try await eventually("phone has them") { try phone.unread(key) == 2 }
            await phone.session.setVisibleConversation(key)
            try await eventually("marker published") {
                let conversation = try phone.database.writer.read { db in
                    try Conversation.fetchOne(db, key: ["accountID": phone.account.id, "peer": key])
                }
                let newest = try phone.messages(with: key).last?.archiveID
                return conversation?.syncedDisplayedID == newest
            }
            await phone.session.setVisibleConversation(nil)
            await second.manager.setEnabled(second.account.id, true)
            try await second.waitOnline()
            try await eventually("desktop caught up") {
                let rows = try second.messages(with: key)
                return second.status.room(key).isJoined && rows.contains { $0.body == "news 5" }
            }
            #expect(try second.unread(key) == 0)

            try await phone.session.destroyRoom(key)
            await second.manager.stopAll()
        }
        if let desktop { await desktop.manager.stopAll() }
    }
}
