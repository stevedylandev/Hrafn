import Testing
import Foundation
import XMPPClient
import XMPPIM
import XMPPTestSupport
import XMPPCore
import XMPPXML

/// Phase 6 protocol behaviour against the live servers: rooms, their
/// archives, self-ping, invitations, moderation and bookmarks. Off unless
/// `HRAFN_INTEGRATION=1`. Uses its own accounts (rosaline, balthasar), since a
/// room's traffic reaches every occupant.
@Suite(.enabled(if: integrationEnabled), .serialized, .timeLimit(.minutes(1)))
struct MUCIntegrationTests {

    private func newRoom(on server: TestServer) throws -> JID {
        try JID("room-\(UUID().uuidString.prefix(8).lowercased())@conference.\(server.domain)")
    }

    private func occupant(_ client: XMPPClient, in room: JID,
                          where predicate: @escaping @Sendable (OccupantPresence) -> Bool) async throws -> OccupantPresence {
        try await next(client) { event in
            guard case .presence(let p) = event, let occupant = OccupantPresence(p), occupant.room == room,
                  predicate(occupant) else { return nil }
            return occupant
        }
    }

    private func roomMessage(_ client: XMPPClient, in room: JID, info: RoomInfo?,
                             where predicate: @escaping @Sendable (RoomMessage) -> Bool) async throws -> RoomMessage {
        try await next(client) { event in
            guard case .message(let m) = event, let message = RoomMessage(live: m, info: info), message.room == room,
                  predicate(message) else { return nil }
            return message
        }
    }

    /// Create, join, talk, find it in the archive, self-ping, leave.
    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func roomLifecycle(_ server: TestServer) async throws {
        let rosaline = try liveClient("rosaline", on: server)
        let balthasar = try liveClient("balthasar", on: server)
        let rosalineMUC = await MultiUserChat(client: rosaline)
        let balthasarMUC = await MultiUserChat(client: balthasar)
        let archive = await MessageArchive(client: balthasar)
        try await rosaline.connect()
        try await balthasar.connect()
        let room = try newRoom(on: server)

        #expect(try await rosalineMUC.findService(on: try JID(server.domain)) == (try JID("conference.\(server.domain)")))

        // A new room is created locked (201) until its owner configures it.
        let created = try await rosalineMUC.join(room, nick: "Rosaline")
        #expect(created.statusCodes.contains(MUCStatus.created))
        #expect(created.affiliation == .owner)
        var form = try await rosalineMUC.configurationForm(room)
        #expect(form.formType == Namespaces.mucRoomConfig)
        form.set("muc#roomconfig_roomname", ["Verona"])
        form.set("muc#roomconfig_persistentroom", ["1"])
        try await rosalineMUC.configure(room, form: form)

        let info = try #require(try await balthasarMUC.info(room))
        #expect(info.name == "Verona")
        #expect(info.isPersistent)
        #expect(info.supportsArchive)
        #expect(info.supportsStableIDs)
        #expect(info.supportsOccupantIDs)

        let joined = try await balthasarMUC.join(room, nick: "Balthasar")
        #expect(joined.isSelf && joined.role == .participant)
        let seen = try await occupant(rosaline, in: room) { $0.nick == "Balthasar" && $0.isAvailable }
        #expect(seen.occupantID != nil)

        // A second session asking for a taken nick is refused with conflict.
        let intruder = try liveClient("balthasar", on: server)
        let intruderMUC = await MultiUserChat(client: intruder)
        try await intruder.connect()
        await #expect(throws: StanzaError.self) { try await intruderMUC.join(room, nick: "Rosaline") }
        do {
            try await intruderMUC.join(room, nick: "Rosaline")
        } catch let error as StanzaError {
            #expect(error.condition == .conflict)
        }
        await intruder.disconnect()

        // The sender's reflection carries the same origin-id and the room's
        // stanza-id; the other occupant sees the same stanza-id.
        let id = StanzaID.make()
        try await rosaline.send(Message.groupchat(to: room, body: "Good morrow", id: id))
        let reflection = try await roomMessage(rosaline, in: room, info: info) { $0.senderID == id }
        let delivered = try await roomMessage(balthasar, in: room, info: info) { $0.senderID == id }
        #expect(reflection.nick == "Rosaline")
        #expect(delivered.message.body == "Good morrow")
        let stanzaID = try #require(delivered.archiveID)
        #expect(reflection.archiveID == stanzaID)
        #expect(delivered.occupantID == seen.occupantID.map { _ in reflection.occupantID } ?? nil)

        // The room's archive has it under the same id.
        let page = try await archive.query(.init(page: .before(nil), max: 10), archive: room)
        let archived = try #require(page.messages.compactMap { RoomMessage(archived: $0, room: room, info: info) }
            .first { $0.senderID == id })
        #expect(archived.archiveID == stanzaID)
        #expect(archived.nick == "Rosaline")
        #expect(archived.message.body == "Good morrow")

        // Subject changes arrive as a body-less message.
        try await rosaline.send(Message.subject("Two households", room: room))
        let subject = try await roomMessage(balthasar, in: room, info: info) { $0.subject != nil }
        #expect(subject.subject == "Two households")

        #expect(await balthasarMUC.selfPing(room, nick: "Balthasar") == .joined)
        try await balthasarMUC.leave(room, nick: "Balthasar")
        var occupants = RoomOccupants()
        _ = occupants.apply(joined)
        let exit = try await occupant(balthasar, in: room) { $0.isSelf && !$0.isAvailable }
        #expect(occupants.apply(exit) == .exited(.left))
        #expect(await balthasarMUC.selfPing(room, nick: "Balthasar") == .notJoined)

        try await rosalineMUC.destroy(room)
        await rosaline.disconnect()
        await balthasar.disconnect()
    }

    /// Nick changes, members-only invitations, kicking.
    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func membershipAndModeration(_ server: TestServer) async throws {
        let rosaline = try liveClient("rosaline", on: server)
        let balthasar = try liveClient("balthasar", on: server)
        let rosalineMUC = await MultiUserChat(client: rosaline)
        let balthasarMUC = await MultiUserChat(client: balthasar)
        try await rosaline.connect()
        try await balthasar.connect()
        // Invitations go to the bare JID: without presence they would wait in
        // offline storage.
        try await balthasar.send(Presence.available())
        let room = try newRoom(on: server)
        let balthasarJID = try JID("balthasar@\(server.domain)")

        try await rosalineMUC.join(room, nick: "Rosaline")
        var form = try await rosalineMUC.configurationForm(room)
        form.set("muc#roomconfig_membersonly", ["1"])
        form.set("muc#roomconfig_whois", ["anyone"])
        try await rosalineMUC.configure(room, form: form)
        #expect(try await rosalineMUC.info(room)?.isPrivateGroup == true)

        // Not a member yet.
        do {
            try await balthasarMUC.join(room, nick: "Balthasar")
            Issue.record("joined a members-only room without being a member")
        } catch let error as StanzaError {
            #expect(error.condition == .registrationRequired)
        }

        // A mediated invitation makes the invitee a member (§7.8.2).
        try await rosaline.send(Message.mediatedInvite(to: balthasarJID, room: room, reason: "Supper"))
        let invite = try await next(balthasar) { event -> RoomInvite? in
            guard case .message(let m) = event, let invite = RoomInvite(m), invite.room == room else { return nil }
            return invite
        }
        #expect(invite.kind == .mediated)
        #expect(invite.inviter == (try JID("rosaline@\(server.domain)")))
        #expect(invite.reason == "Supper")
        #expect(try await rosalineMUC.list(.member, in: room).contains(balthasarJID))

        let joined = try await balthasarMUC.join(room, nick: "Balthasar")
        #expect(joined.affiliation == .member)
        let seen = try await occupant(rosaline, in: room) { $0.nick == "Balthasar" && $0.isAvailable }
        #expect(seen.realJID?.bare == balthasarJID)

        // Nick change: unavailable with 303 under the old nick, then available.
        var occupants = RoomOccupants()
        _ = occupants.apply(joined)
        let renamed = try await balthasarMUC.changeNick(in: room, to: "Balthasar2")
        #expect(renamed.nick == "Balthasar2")
        let taken = try? await balthasarMUC.changeNick(in: room, to: "Rosaline")
        #expect(taken == nil)

        // Kicked: our unavailable self-presence says 307.
        try await rosalineMUC.setRole(.none, nick: "Balthasar2", in: room, reason: "Out")
        let kicked = try await occupant(balthasar, in: room) { $0.isSelf && !$0.isAvailable && $0.nick == "Balthasar2" }
        var fresh = RoomOccupants()
        _ = fresh.apply(renamed)
        #expect(fresh.apply(kicked) == .exited(.kicked(reason: "Out")))

        // Direct invitations (XEP-0249) go straight to the contact.
        try await rosaline.send(Message.directInvite(to: balthasarJID, room: room, reason: "Again"))
        let direct = try await next(balthasar) { event -> RoomInvite? in
            guard case .message(let m) = event, let invite = RoomInvite(m), invite.kind == .direct else { return nil }
            return invite
        }
        #expect(direct.room == room)
        #expect(direct.reason == "Again")

        try await rosalineMUC.destroy(room)
        await rosaline.disconnect()
        await balthasar.disconnect()
    }

    /// Someone on the other server joins and talks (s2s).
    @Test func federatedRoom() async throws {
        let owner = try liveClient("rosaline", on: .ejabberd)
        let guest = try liveClient("balthasar", on: .prosody)
        let ownerMUC = await MultiUserChat(client: owner)
        let guestMUC = await MultiUserChat(client: guest)
        try await owner.connect()
        try await guest.connect()
        let room = try newRoom(on: .ejabberd)

        try await ownerMUC.join(room, nick: "Rosaline")
        try await ownerMUC.createInstantRoom(room)
        let info = try await guestMUC.info(room)
        try await guestMUC.join(room, nick: "Balthasar", timeout: .seconds(15))
        let id = StanzaID.make()
        try await guest.send(Message.groupchat(to: room, body: "From Mantua", id: id))
        let received = try await roomMessage(owner, in: room, info: info) { $0.senderID == id }
        #expect(received.nick == "Balthasar")
        #expect(await guestMUC.selfPing(room, nick: "Balthasar", timeout: .seconds(10)) == .joined)

        try await ownerMUC.destroy(room)
        await owner.disconnect()
        await guest.disconnect()
    }

    /// XEP-0153 in rooms: an occupant's photo hash in their room presence,
    /// and the photo fetched through their occupant JID without knowing who
    /// they are.
    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func occupantVCardPhoto(_ server: TestServer) async throws {
        let rosaline = try liveClient("rosaline", on: server)
        let balthasar = try liveClient("balthasar", on: server)
        let ownerMUC = await MultiUserChat(client: balthasar)
        let guestMUC = await MultiUserChat(client: rosaline)
        try await rosaline.connect()
        try await balthasar.connect()
        let photo = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        try await VCardAvatars(client: rosaline).setPhoto(photo, type: "image/png")
        let room = try newRoom(on: server)
        try await ownerMUC.join(room, nick: "Balthasar")
        try await ownerMUC.createInstantRoom(room)

        async let arrival = occupant(balthasar, in: room) { $0.nick == "Rosaline" && $0.isAvailable }
        try await guestMUC.join(room, nick: "Rosaline")
        let presence = try await arrival
        // Both servers stamp the hash on presence, room presence included.
        #expect(VCardAvatars.advertised(in: presence.presence) == .photo(sha1: Avatars.sha1(photo)))

        let fetched = try await VCardAvatars(client: balthasar).photo(of: try JID("\(room)/Rosaline"))
        #expect(fetched?.data == photo)

        try await ownerMUC.destroy(room)
        try await VCardAvatars(client: rosaline).setPhoto(nil, type: "image/png")
        await rosaline.disconnect()
        await balthasar.disconnect()
    }

    /// XEP-0425: a moderator takes an occupant's message down; everyone is
    /// told, in the version the room speaks, and the archive keeps a
    /// tombstone (or nothing) in its place.
    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func moderation(_ server: TestServer) async throws {
        let rosaline = try liveClient("rosaline", on: server)
        let balthasar = try liveClient("balthasar", on: server)
        let ownerMUC = await MultiUserChat(client: rosaline)
        let guestMUC = await MultiUserChat(client: balthasar)
        try await rosaline.connect()
        try await balthasar.connect()
        let room = try newRoom(on: server)
        try await ownerMUC.join(room, nick: "Rosaline")
        var form = try await ownerMUC.configurationForm(room)
        form.set("muc#roomconfig_persistentroom", ["1"])
        try await ownerMUC.configure(room, form: form)
        let info = try #require(try await ownerMUC.info(room))
        #expect(info.moderationNamespace != nil)
        try await guestMUC.join(room, nick: "Balthasar")

        let id = StanzaID.make()
        async let arrival = roomMessage(rosaline, in: room, info: info) { $0.senderID == id }
        try await balthasar.send(Message.groupchat(to: room, body: "Draw, if you be men", id: id))
        let target = try #require(try await arrival.archiveID)

        async let announced = next(balthasar) { event -> Moderation? in
            guard case .message(let m) = event else { return nil }
            return Moderation(m, room: room)
        }
        try await ownerMUC.moderate(target, in: room, reason: "Keep the peace", info: info)
        let moderation = try await announced
        #expect(moderation.target == target)
        #expect(moderation.moderator == "Rosaline")
        #expect(moderation.reason == "Keep the peace")

        // The archive: a tombstone where the message was, or the message gone.
        let page = try await MessageArchive(client: balthasar).query(.init(page: .before(nil), max: 20), archive: room)
        let original = page.messages.first { $0.archiveID == target }
        if let original {
            let tombstone = try #require(Moderation.tombstone(in: original.message))
            #expect(tombstone.moderator == "Rosaline")
            #expect(original.message.body == nil || original.message.body?.contains("Draw") == false)
        }

        // Only a moderator may: the guest is refused.
        await #expect(throws: StanzaError.self) {
            try await guestMUC.moderate(target, in: room, info: info)
        }
        try await ownerMUC.destroy(room)
        await rosaline.disconnect()
        await balthasar.disconnect()
    }

    /// Bookmarks 2: publish, see the notification on another session, fetch,
    /// retract.
    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func bookmarks(_ server: TestServer) async throws {
        let phone = try liveClient("rosaline", on: server)
        let laptop = try liveClient("rosaline", on: server)
        await laptop.addFeature(Bookmarks.notifyFeature)
        try await phone.connect()
        try await laptop.connect()
        // PEP sends notifications to resources whose caps say +notify.
        try await laptop.send(Presence.available(caps: await laptop.capsElement))
        let account = try JID("rosaline@\(server.domain)")
        let room = try newRoom(on: server)
        let bookmarks = Bookmarks(client: phone)

        let extensions = Element(name: "extensions", namespaceURI: Namespaces.bookmarks)
            .adding(Element(name: "state", namespaceURI: "urn:example:other-client", attributes: ["x": "1"]))
        let bookmark = Bookmark(room: room, name: "Verona", autojoin: true, nick: "Ros", extensions: extensions)
        try await Task.sleep(for: .milliseconds(300))
        try await bookmarks.publish(bookmark)

        // ejabberd 26.07 (Docker) intermittently delivers no PEP notification
        // to the owner's other resource, even with +notify in caps it has
        // queried. Each fresh session fetches bookmarks, so only live sync
        // between two online devices is affected.
        try await withKnownIssue("ejabberd PEP notifications to own resources", isIntermittent: true) {
            let published = try await next(laptop) { event -> [Bookmarks.Change]? in
                guard case .message(let m) = event, let changes = Bookmarks.changes(in: m, account: account),
                      !changes.isEmpty else { return nil }
                return changes
            }
            #expect(published == [.published(bookmark)])
        } when: { server.domain == TestServer.ejabberd.domain }

        let fetched = try await Bookmarks(client: laptop).fetch()
        #expect(fetched.contains(bookmark))

        try await bookmarks.retract(room)
        try await withKnownIssue("ejabberd PEP notifications to own resources", isIntermittent: true) {
            let retracted = try await next(laptop) { event -> [Bookmarks.Change]? in
                guard case .message(let m) = event, let changes = Bookmarks.changes(in: m, account: account),
                      changes.contains(.retracted(room)) else { return nil }
                return changes
            }
            #expect(retracted == [.retracted(room)])
        } when: { server.domain == TestServer.ejabberd.domain }
        #expect(!(try await bookmarks.fetch()).contains { $0.room == room })

        await phone.disconnect()
        await laptop.disconnect()
    }
}
