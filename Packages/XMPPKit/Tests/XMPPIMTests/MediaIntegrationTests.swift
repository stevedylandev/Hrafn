import Testing
import Foundation
import XMPPClient
import XMPPIM
import XMPPTestSupport
import XMPPCore
import XMPPXML

/// Phase 7 protocol behaviour against the live servers: HTTP upload through
/// to the file coming back, and avatars and nicknames between contacts.
/// Off unless `HRAFN_INTEGRATION=1`.
@Suite(.enabled(if: integrationEnabled), .serialized, .timeLimit(.minutes(1)))
struct MediaIntegrationTests {

    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func uploadsAndDownloads(_ server: TestServer) async throws {
        let client = try liveClient("abram", on: server)
        try await client.connect()
        let upload = HTTPUpload(client: client)
        let service = try #require(try await upload.discover())
        #expect(service.jid.description == "upload.\(server.domain)")
        #expect(service.maxFileSize == 16 * 1024 * 1024)

        let bytes = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let slot = try await upload.requestSlot(filename: "test file.bin", size: bytes.count,
                                                contentType: "application/octet-stream", service: service.jid)
        let http = try LoopbackHTTP()
        let status = try await http.put(bytes, to: slot.putURL, headers: slot.putHeaders,
                                        contentType: "application/octet-stream")
        #expect((200..<300).contains(status))
        let (downloaded, getStatus) = try await http.get(slot.getURL)
        #expect(getStatus == 200)
        #expect(downloaded == bytes)

        await #expect(throws: HTTPUpload.Failure.self) {
            _ = try await upload.requestSlot(filename: "huge.bin", size: 64 * 1024 * 1024, contentType: nil,
                                             service: service.jid)
        }
        await client.disconnect()
    }

    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func avatarsAndNicknamesReachContacts(_ server: TestServer) async throws {
        let abram = try liveClient("abram", on: server)
        let peter = try liveClient("peter", on: server)
        let abramJID = try JID("abram@\(server.domain)")
        let peterJID = try JID("peter@\(server.domain)")
        for feature in [Avatars.notifyFeature, Nicknames.notifyFeature] { await peter.addFeature(feature) }
        try await abram.connect()
        try await peter.connect()
        for client in [abram, peter] {
            _ = try await Roster(client: client).fetch(version: nil)
            try await client.send(Presence.available(caps: await client.capsElement))
        }
        try await befriend(abram, abramJID, peter, peterJID)

        // A fresh image each run, so the notification is for this one.
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data(UUID().uuidString.utf8))
        // Subscribing sends the last published item first; wait for this one.
        let hash = Avatars.sha1(png)
        let notified = Task {
            try await next(peter, timeout: .seconds(5)) { event -> Avatars.Change? in
                guard case .message(let m) = event, let change = Avatars.change(in: m, account: peterJID),
                      change.jid == abramJID, change.avatar?.id == hash else { return nil }
                return change
            }
        }
        let info = try await Avatars(client: abram).publish(png, type: "image/png", width: 1, height: 1)

        let fetched = try #require(try await Avatars(client: peter).metadata(of: abramJID))
        #expect(fetched.id == info.id)
        #expect(try await Avatars(client: peter).data(of: abramJID, id: info.id) == png)
        // +notify in caps: the server tells contacts as it happens.
        try await withKnownIssue("ejabberd PEP notifications to contacts", isIntermittent: true) {
            _ = try await notified.value
        } when: { server.domain == TestServer.ejabberd.domain }

        // XEP-0398 servers mirror the PEP avatar into the vCard for old clients.
        let converts = try await abram.discoInfo(abramJID).supports(Namespaces.pepVCardConversion)
        if converts {
            let photo = try await VCardAvatars(client: peter).photo(of: abramJID)
            #expect(photo.map { Avatars.sha1($0.data) } == info.id)
        }

        let nick = "Abram \(UUID().uuidString.prefix(4))"
        try await Nicknames(client: abram).publish(nick)
        #expect(try await Nicknames(client: peter).fetch(of: abramJID) == nick)

        try await Avatars(client: abram).disable()
        #expect(try await Avatars(client: peter).metadata(of: abramJID) == nil)

        try await Roster(client: abram).remove(peterJID)
        try await Roster(client: peter).remove(abramJID)
        await peter.disconnect()
        await abram.disconnect()
    }

    /// The mutual subscription avatars need (the nodes are presence-access).
    private func befriend(_ a: XMPPClient, _ aJID: JID, _ b: XMPPClient, _ bJID: JID) async throws {
        try? await Roster(client: a).remove(bJID)
        try? await Roster(client: b).remove(aJID)
        try await Task.sleep(for: .milliseconds(300))
        func request(to client: XMPPClient, from jid: JID) async throws {
            _ = try await next(client) { event -> Bool? in
                guard case .presence(let p) = event, p.type == .subscribe, p.from?.bare == jid else { return nil }
                return true
            }
        }
        try await Subscriptions(client: a).request(bJID)
        try await request(to: b, from: aJID)
        try await Subscriptions(client: b).approve(aJID)
        try await Subscriptions(client: b).request(aJID)
        try await request(to: a, from: bJID)
        try await Subscriptions(client: a).approve(bJID)
        try await Task.sleep(for: .milliseconds(500))
    }
}
