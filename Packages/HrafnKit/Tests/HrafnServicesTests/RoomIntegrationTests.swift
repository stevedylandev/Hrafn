import Testing
import Foundation
import GRDB
@testable import HrafnServices
import HrafnStore
import XMPPCore
import XMPPIM
import XMPPXML

/// Phase 6 end to end: group chats through the sessions and the database,
/// against the Docker servers. Off unless `HRAFN_INTEGRATION=1`. Uses its own
/// accounts (sampson, gregory): a room's traffic reaches every occupant.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HRAFN_INTEGRATION"] == "1"),
       .serialized, .timeLimit(.minutes(2)))
@MainActor
struct RoomIntegrationTests {

    private func room(_ device: Device, _ key: String) throws -> Room? {
        try device.database.fetchRoom(accountID: device.account.id, jid: key)
    }

    private func joined(_ device: Device, _ key: String) async throws {
        try await eventually("\(device.account.jid) in \(key)") { device.status.room(key).isJoined }
    }

    /// Create a private group, invite, talk, edit, retract, set the subject.
    @Test(arguments: [LiveServer.prosody, LiveServer.ejabberd])
    func privateGroup(_ server: LiveServer) async throws {
        let sampson = try await Device("sampson", on: server)
        let gregory = try await Device("gregory", on: server)
        try await closing([sampson, gregory]) {
            let key = try await sampson.session.createRoom(name: "Capulet Hall", kind: .privateGroup)
            try await joined(sampson, key)
            #expect(sampson.status.room(key).isOwner)
            let stored = try #require(try room(sampson, key))
            #expect(stored.bookmarked && stored.autojoin && stored.isPrivateGroup)
            #expect(stored.name == "Capulet Hall")

            // Members only: the invitation goes through the room.
            try await sampson.session.invite(gregory.account.jid, to: key, reason: "Supper")
            try await eventually("invitation") {
                try gregory.database.invitation(accountID: gregory.account.id, room: key) != nil
            }
            let invitation = try #require(try gregory.database.invitation(accountID: gregory.account.id, room: key))
            #expect(invitation.inviter == sampson.account.jid)
            #expect(invitation.reason == "Supper")
            try await gregory.session.acceptInvitation(key)
            try await joined(gregory, key)
            #expect(try gregory.database.invitation(accountID: gregory.account.id, room: key) == nil)
            #expect(try room(gregory, key)?.bookmarked == true)
            try await eventually("gregory among the occupants") {
                sampson.status.room(key).occupants.contains { $0.nick == "gregory" && $0.jid == gregory.account.jid }
            }

            // A message, its reflection, and the other side.
            let sent = try await gregory.session.send("Do you bite your thumb?", to: key)
            try await eventually("reflection") {
                try gregory.messages(with: key).first { $0.id == sent.id }?.state == .delivered
            }
            let own = try #require(try gregory.messages(with: key).first { $0.id == sent.id })
            #expect(own.archiveID != nil)
            try await eventually("delivery to sampson") { try sampson.messages(with: key).contains { !$0.isOutgoing } }
            let received = try #require(try sampson.messages(with: key).first { !$0.isOutgoing })
            #expect(received.body == "Do you bite your thumb?")
            #expect(received.senderNick == "gregory")
            #expect(received.archiveID == own.archiveID)
            #expect(try sampson.unread(key) == 1)

            // Correction and retraction reach the other side.
            try await gregory.session.correct(messageID: own.id!, with: "Do you bite your thumb at us?")
            try await eventually("correction") {
                try sampson.messages(with: key).first { $0.id == received.id }?.body == "Do you bite your thumb at us?"
            }
            try await gregory.session.retract(messageID: own.id!)
            try await eventually("retraction") {
                try sampson.messages(with: key).first { $0.id == received.id }?.isRetracted == true
            }
            #expect(try sampson.unread(key) == 0)

            // A mention, announced in a private group like everything else.
            _ = try await sampson.session.send("gregory: I do bite my thumb, sir.", to: key)
            try await eventually("mention") { try gregory.messages(with: key).contains { $0.mentionsMe } }
            try await sampson.session.setSubject("Two households", in: key)
            try await eventually("subject") { try room(gregory, key)?.subject == "Two households" }

            try await sampson.session.destroyRoom(key)
            try await eventually("gregory out") { !gregory.status.room(key).isJoined }
            #expect(try room(sampson, key) == nil)
        }
    }

    /// The exit check: rooms are rejoined after the app has been logged out
    /// in the background, missed messages arrive once, unread counts and
    /// notifications follow the room's kind.
    @Test(arguments: [LiveServer.prosody, LiveServer.ejabberd])
    func rejoinsAfterBackgroundAndCatchesUp(_ server: LiveServer) async throws {
        let sampson = try await Device("sampson", on: server)
        let gregory = try await Device("gregory", on: server)
        try await closing([sampson, gregory]) {
            let key = try await sampson.session.createRoom(name: "Verona Square", kind: .channel)
            try await gregory.session.joinRoom(key)
            try await joined(gregory, key)
            #expect(try room(gregory, key)?.effectiveNotify == .mentions)

            await gregory.manager.suspend()
            try await eventually("gregory left the room") {
                !sampson.status.room(key).occupants.contains { $0.nick == "gregory" }
            }
            for text in ["One", "gregory, are you there?", "Three"] {
                _ = try await sampson.session.send(text, to: key)
            }
            try await eventually("sampson's reflections") {
                try sampson.messages(with: key).filter { $0.state == .delivered }.count == 3
            }

            for _ in 0..<2 {
                await gregory.manager.resume()
                try await gregory.waitOnline()
                try await joined(gregory, key)
                try await eventually("catch-up") { try gregory.messages(with: key).count == 3 }
                try await Task.sleep(for: .milliseconds(500))
                #expect(try gregory.messages(with: key).map(\.body) == ["One", "gregory, are you there?", "Three"])
                let states = try gregory.messages(with: key).map { "\($0.state) \($0.archiveID ?? "-")" }
                #expect(try gregory.unread(key) == 3, "\(states)")
                await gregory.manager.suspend()
            }
            // A channel announces mentions only (the rules are unit-tested in
            // HrafnStoreTests; in the foreground everything is claimed quietly).
            #expect(try gregory.messages(with: key).filter(\.mentionsMe).map(\.body) == ["gregory, are you there?"])

            await gregory.manager.resume()
            try await gregory.waitOnline()
            try await sampson.session.destroyRoom(key)
        }
    }

    /// XEP-0410: dropped from a room without being told, the session notices,
    /// rejoins and catches up.
    @Test(arguments: [LiveServer.prosody, LiveServer.ejabberd])
    func selfPingRecoversASilentDrop(_ server: LiveServer) async throws {
        let sampson = try await Device("sampson", on: server)
        let gregory = try await Device("gregory", on: server)
        try await closing([sampson, gregory]) {
            let key = try await sampson.session.createRoom(name: "Mantua", kind: .channel)
            try await gregory.session.joinRoom(key)
            try await joined(gregory, key)
            let roomJID = try JID(key)
            let nick = try #require(gregory.status.room(key).nick)
            let occupant = try roomJID.withResource(nick)

            // Leave behind the session's back, and hide the room's answer.
            let client = gregory.session.client
            await client.addPresenceInterceptor { $0.from == occupant && $0.type == .unavailable }
            try await client.send(Presence(type: .unavailable, to: occupant))
            try await eventually("gregory gone from the room") {
                !sampson.status.room(key).occupants.contains { $0.nick == nick }
            }
            #expect(gregory.status.room(key).isJoined)
            _ = try await sampson.session.send("Missed this", to: key)
            try await Task.sleep(for: .milliseconds(500))
            #expect(try gregory.messages(with: key).isEmpty)

            await gregory.session.checkRooms(force: true)
            try await eventually("rejoined with history") {
                try gregory.messages(with: key).map(\.body) == ["Missed this"]
            }
            try await joined(gregory, key)
            try await sampson.session.destroyRoom(key)
        }
    }

    /// Someone from the other server joins through a direct invitation.
    @Test func federatedChannel() async throws {
        let sampson = try await Device("sampson", on: .ejabberd)
        let gregory = try await Device("gregory", on: .prosody)
        try await closing([sampson, gregory]) {
            let key = try await sampson.session.createRoom(name: "Across the River", kind: .channel)
            try await sampson.session.invite(gregory.account.jid, to: key)
            try await eventually("invitation", timeout: .seconds(15)) {
                try gregory.database.invitation(accountID: gregory.account.id, room: key) != nil
            }
            try await gregory.session.acceptInvitation(key)
            try await joined(gregory, key)
            _ = try await gregory.session.send("From Mantua", to: key)
            try await eventually("delivery", timeout: .seconds(15)) {
                try sampson.messages(with: key).contains { $0.body == "From Mantua" && $0.senderNick == "gregory" }
            }
            try await sampson.session.destroyRoom(key)
        }
    }

    /// Bookmarks 2 between two devices of one account: joining on one joins
    /// the other; leaving leaves. Prosody only (ejabberd's PEP notifications
    /// to own resources are unreliable; see XMPPKit's MUCIntegrationTests).
    @Test func bookmarksFollowAcrossDevices() async throws {
        let sampson = try await Device("sampson", on: .prosody)
        let phone = try await Device("gregory", on: .prosody)
        let laptop = try await Device("gregory", on: .prosody)
        try await closing([sampson, phone, laptop]) {
            let key = try await sampson.session.createRoom(name: "Friar's Cell", kind: .channel)
            try await phone.session.joinRoom(key)
            try await joined(laptop, key)
            #expect(try room(laptop, key)?.bookmarked == true)

            try await phone.session.leaveRoom(key)
            try await eventually("laptop left") { !laptop.status.room(key).isJoined }
            #expect(try room(laptop, key)?.autojoin == false)
            try await sampson.session.destroyRoom(key)
        }
    }

    /// XEP-0045 §7.5: private messages through a room live in their own
    /// conversation with the occupant, in both directions, and never in the
    /// room's.
    @Test(arguments: [LiveServer.prosody, LiveServer.ejabberd])
    func privateMessages(_ server: LiveServer) async throws {
        let sampson = try await Device("sampson", on: server)
        let gregory = try await Device("gregory", on: server)
        try await closing([sampson, gregory]) {
            let key = try await sampson.session.createRoom(name: "Street \(UUID().uuidString.prefix(4))", kind: .channel)
            try await joined(sampson, key)
            try await gregory.session.joinRoom(key)
            try await joined(gregory, key)
            let sampsonNick = try #require(sampson.status.room(key).nick)
            let gregoryNick = try #require(gregory.status.room(key).nick)
            let toSampson = "\(key)/\(sampsonNick)", toGregory = "\(key)/\(gregoryNick)"

            let text = "A word in private \(UUID().uuidString.prefix(4))"
            let sent = try await gregory.session.send(text, to: toSampson)
            #expect(sent.peer == toSampson)
            #expect(sent.state == .sent)
            try await eventually("sampson has it privately") {
                try sampson.messages(with: toGregory).contains { $0.body == text && !$0.isOutgoing }
            }
            #expect(try sampson.unread(toGregory) == 1)
            _ = try await sampson.session.send("Say on", to: toGregory)
            try await eventually("gregory has the answer") {
                try gregory.messages(with: toSampson).contains { $0.body == "Say on" && !$0.isOutgoing }
            }
            #expect(try gregory.messages(with: toSampson).map(\.body) == [text, "Say on"])
            #expect(try !sampson.messages(with: key).contains { $0.body == text || $0.body == "Say on" })
            #expect(try !gregory.messages(with: key).contains { $0.body == text || $0.body == "Say on" })

            let summary = try #require(try sampson.database.fetchConversationSummaries(accountIDs: [sampson.account.id])
                .first { $0.conversation.peer == toGregory })
            #expect(summary.title.hasPrefix(gregoryNick))
            #expect(summary.viaRoom?.jid == key)
            try await sampson.session.destroyRoom(key)
        }
    }

    /// XEP-0425 through the sessions: the owner removes a guest's message;
    /// it is gone on both sides, saying who removed it.
    @Test(arguments: [LiveServer.prosody, LiveServer.ejabberd])
    func moderation(_ server: LiveServer) async throws {
        let sampson = try await Device("sampson", on: server)
        let gregory = try await Device("gregory", on: server)
        try await closing([sampson, gregory]) {
            let key = try await sampson.session.createRoom(name: "Square \(UUID().uuidString.prefix(4))", kind: .channel)
            try await joined(sampson, key)
            try await gregory.session.joinRoom(key)
            try await joined(gregory, key)
            let owner = try #require(sampson.status.room(key).nick)

            let sent = try await gregory.session.send("I will bite my thumb", to: key)
            try await eventually("sampson has it") {
                try sampson.messages(with: key).contains { $0.body == "I will bite my thumb" && $0.archiveID != nil }
            }
            let received = try #require(try sampson.messages(with: key).first { $0.body == "I will bite my thumb" })
            try await sampson.session.moderate(messageID: received.id!, reason: "Disgrace")

            try await eventually("removed for sampson") {
                try sampson.database.message(id: received.id!)?.moderatedBy == owner
            }
            try await eventually("removed for gregory") {
                try gregory.database.message(id: sent.id!)?.moderatedBy == owner
            }
            let own = try #require(try gregory.database.message(id: sent.id!))
            #expect(own.isRetracted && own.body.isEmpty && own.moderationReason == "Disgrace")

            // Gregory is no moderator.
            let mine = try await sampson.session.send("Do you quarrel, sir?", to: key)
            try await eventually("gregory has it") {
                try gregory.messages(with: key).contains { $0.body == "Do you quarrel, sir?" && $0.archiveID != nil }
            }
            let theirs = try #require(try gregory.messages(with: key).first { $0.body == "Do you quarrel, sir?" })
            await #expect(throws: (any Error).self) { try await gregory.session.moderate(messageID: theirs.id!) }
            #expect(try sampson.database.message(id: mine.id!)?.isRetracted == false)
            try await sampson.session.destroyRoom(key)
        }
    }
}
