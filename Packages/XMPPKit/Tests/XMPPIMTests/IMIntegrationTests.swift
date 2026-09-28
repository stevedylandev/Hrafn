import Testing
import Foundation
import XMPPClient
import XMPPIM
import XMPPStream
import XMPPTransport
import XMPPTestSupport
import XMPPCore
import XMPPXML

/// Phase 4 protocol behaviour against the live servers. Off unless
/// `HRAFN_INTEGRATION=1`; see `TestServers.swift`.
@Suite(.enabled(if: integrationEnabled), .serialized, .timeLimit(.minutes(1)))
struct IMIntegrationTests {

    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func rosterVersioningAndPushes(_ server: TestServer) async throws {
        // Legacy SASL: ejabberd sends no stream features after SASL2, so it
        // only says it versions rosters on the restarted stream.
        let client = try liveClient("juliet", on: server, sasl2: false)
        let pushes = AsyncStream<Roster.Push>.makeStream()
        let roster = Roster(client: client)
        await roster.handlePushes { pushes.continuation.yield($0) }
        try await client.connect()
        let contact = try JID("nurse-\(UUID().uuidString.prefix(6).lowercased())@\(server.domain)")

        guard case .full(_, let version) = try await roster.fetch(version: nil) else {
            Issue.record("expected a full roster on the first fetch")
            return
        }
        #expect(await roster.supportsVersioning)
        let v0 = try #require(version)

        try await roster.set(RosterItem(jid: contact, name: "Nurse", groups: ["Staff"]))
        var iterator = pushes.stream.makeAsyncIterator()
        let added = try #require(await iterator.next())
        #expect(added.item.jid == contact)
        #expect(added.item.name == "Nurse")
        #expect(added.item.groups == ["Staff"])

        // Fetching at the old version returns the delta or the whole roster;
        // at the latest version, nothing.
        if let latest = added.version {
            #expect(latest != v0)
            let current = try await roster.fetch(version: latest)
            if case .full(let items, _) = current {
                // Allowed by §2.6.3, but the item must then be in it.
                #expect(items.contains { $0.jid == contact })
            }
        }

        try await roster.remove(contact)
        let removed = try #require(await iterator.next())
        #expect(removed.item.subscription == .remove)
        await client.disconnect()
    }

    /// Subscription handshake, then messages with receipts, markers, chat
    /// states, a correction and a retraction; carbons to a second session; and
    /// the whole exchange found again in the archive.
    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func conversationRoundTrip(_ server: TestServer) async throws {
        let juliet = try liveClient("benvolio", on: server)
        let julietPhone = try liveClient("benvolio", on: server)
        let romeo = try liveClient("mercutio", on: server)
        let julietArchive = await MessageArchive(client: juliet)
        try await juliet.connect()
        try await julietPhone.connect()
        try await romeo.connect()
        let julietJID = try JID("benvolio@\(server.domain)")
        let romeoJID = try JID("mercutio@\(server.domain)")
        let startedAt = Date().addingTimeInterval(-2)

        try await Carbons.enable(on: juliet)
        try await Carbons.enable(on: julietPhone)

        // RFC 6121 §1.3: subscription requests reach only "interested"
        // resources — ones that fetched the roster and sent presence.
        for client in [juliet, julietPhone, romeo] {
            _ = try await Roster(client: client).fetch(version: nil)
            try await client.send(Presence.available(caps: await client.capsElement))
        }

        // Start from no relationship, then the mutual handshake (RFC 6121 §3).
        try? await Roster(client: juliet).remove(romeoJID)
        try? await Roster(client: romeo).remove(julietJID)
        try await Task.sleep(for: .milliseconds(300))
        func subscribeRequest(to client: XMPPClient, from jid: JID) async throws {
            _ = try await next(client) { event -> Bool? in
                guard case .presence(let p) = event, p.type == .subscribe, p.from?.bare == jid else { return nil }
                return true
            }
        }
        try await Subscriptions(client: juliet).request(romeoJID)
        try await subscribeRequest(to: romeo, from: julietJID)
        try await Subscriptions(client: romeo).approve(julietJID)
        try await Subscriptions(client: romeo).request(julietJID)
        try await subscribeRequest(to: juliet, from: romeoJID)
        try await Subscriptions(client: juliet).approve(romeoJID)
        try await Task.sleep(for: .milliseconds(500))
        let roster = try await Roster(client: juliet).fetch(version: nil)
        if case .full(let items, _) = roster {
            #expect(items.first { $0.jid == romeoJID }?.subscription == .both)
        }

        // Juliet → Romeo, with every request attached.
        let token = UUID().uuidString
        let outgoing = Message.chat(to: romeoJID, body: "hello \(token)")
        try await juliet.send(outgoing)
        let arrived = try await nextMessage(romeo, account: romeoJID) { $0.message.body == "hello \(token)" }
        #expect(arrived.message.requestsReceipt)
        #expect(arrived.message.isMarkable)
        #expect(arrived.message.originID == outgoing.id)
        #expect(arrived.archiveID != nil, "server assigns a stanza-id by the recipient's archive")

        // Juliet's other session sees her own message as a sent carbon.
        let carbon = try await nextMessage(julietPhone, account: julietJID) { $0.message.body == "hello \(token)" }
        #expect(carbon.source == .carbon)
        #expect(carbon.isOutgoing)
        #expect(carbon.peer == romeoJID)

        // Romeo answers the receipt and marks it displayed; Juliet gets both.
        let julietFull = try #require(await juliet.jid)
        try await romeo.send(Message.receipt(for: try #require(outgoing.id), to: julietFull))
        let receipt = try await nextMessage(juliet, account: julietJID) { $0.message.receiptID != nil }
        #expect(receipt.message.receiptID == outgoing.id)
        try await romeo.send(Message.displayed(try #require(outgoing.id), to: julietJID))
        let displayed = try await nextMessage(juliet, account: julietJID) { $0.message.displayedID != nil }
        #expect(displayed.message.displayedID == outgoing.id)

        try await romeo.send(Message.chatState(.composing, to: julietFull))
        let typing = try await nextMessage(juliet, account: julietJID) { $0.message.chatState == .composing }
        #expect(typing.message.body == nil)

        let fix = Message.correction(of: try #require(outgoing.id), to: romeoJID, body: "hello again \(token)")
        try await juliet.send(fix)
        let corrected = try await nextMessage(romeo, account: romeoJID) { $0.message.replacedID != nil }
        #expect(corrected.message.replacedID == outgoing.id)
        #expect(corrected.message.body == "hello again \(token)")

        // The archive has the original and the correction, and none of the
        // transient chat states.
        try await Task.sleep(for: .milliseconds(300))
        let before = try await julietArchive.query(.init(with: romeoJID, start: startedAt, page: .after(nil), max: 100))
        let mine = before.messages.filter { $0.message.body?.contains(token) == true }
        #expect(mine.count == 2)
        #expect(mine.first?.isOutgoing == true)
        #expect(mine.first?.senderID == outgoing.id)
        #expect(mine.last?.message.replacedID == outgoing.id)
        #expect(mine.allSatisfy { $0.archiveID != nil && $0.timestamp != nil })
        #expect(!before.messages.contains { $0.message.chatState == .composing })

        try await juliet.send(Message.retraction(of: try #require(outgoing.id), to: romeoJID))
        let retracted = try await nextMessage(romeo, account: romeoJID) { $0.message.retractedID != nil }
        #expect(retracted.message.retractedID == outgoing.id)

        // The retraction is archived. ejabberd also deletes the original from
        // the archive (XEP-0424 lets servers); Prosody keeps it. Either way a
        // client must remember the retraction, not just apply it.
        try await Task.sleep(for: .milliseconds(300))
        let page = try await julietArchive.query(.init(with: romeoJID, start: startedAt, page: .after(nil), max: 100))
        #expect(page.messages.contains { $0.message.retractedID == outgoing.id && $0.isOutgoing })

        // Paging backwards from the newest reaches the same messages.
        var ids: [String] = []
        var cursor: String? = nil
        repeat {
            let back = try await julietArchive.query(.init(with: romeoJID, start: startedAt, page: .before(cursor), max: 2))
            ids.insert(contentsOf: back.messages.compactMap(\.archiveID), at: 0)
            cursor = back.first
            if back.complete || back.messages.isEmpty { break }
        } while true
        #expect(ids == page.messages.compactMap(\.archiveID))

        // Tidy up: drop the subscription so the next run starts the same way.
        try await Roster(client: juliet).remove(romeoJID)
        try await Roster(client: romeo).remove(julietJID)
        await romeo.disconnect()
        await julietPhone.disconnect()
        await juliet.disconnect()
    }

    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func blocksAndUnblocks(_ server: TestServer) async throws {
        let client = try liveClient("juliet", on: server)
        let blocking = Blocking(client: client)
        let pushes = AsyncStream<Blocking.Push>.makeStream()
        await blocking.handlePushes { pushes.continuation.yield($0) }
        try await client.connect()
        #expect(try await blocking.isSupported())
        let spammer = try JID("spam-\(UUID().uuidString.prefix(6).lowercased())@example.org")

        // §3.3: pushes only reach resources that have fetched the list.
        #expect(!(try await blocking.blocklist().contains(spammer)))
        try await blocking.block([spammer])
        var iterator = pushes.stream.makeAsyncIterator()
        #expect(await iterator.next() == .blocked([spammer]))
        #expect(try await blocking.blocklist().contains(spammer))

        try await blocking.unblock([spammer])
        #expect(await iterator.next() == .unblocked([spammer]))
        #expect(!(try await blocking.blocklist().contains(spammer)))
        await client.disconnect()
    }
}
