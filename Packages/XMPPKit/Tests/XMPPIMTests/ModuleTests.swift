import Testing
import Foundation
import XMPPClient
@testable import XMPPIM
import XMPPTestSupport
import XMPPCore
import XMPPXML

/// Collects values handed to a push callback.
private final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var values: [T] { lock.withLock { items } }
}

@Suite struct RosterTests {

    @Test func fetchesWithVersioningAndHandlesUnchanged() async throws {
        let server = plainServer(extraFeatures: "<ver xmlns='urn:xmpp:features:rosterver'/>") { xml, t in
            guard xml.contains("jabber:iq:roster"), let id = Script.attribute("id", in: xml) else { return }
            if xml.contains("ver='v7'") {
                t.inject("<iq type='result' id='\(id)'/>")
            } else {
                t.inject("""
                <iq type='result' id='\(id)'><query xmlns='jabber:iq:roster' ver='v7'>\
                <item jid='romeo@example.net' name='Romeo' subscription='both'><group>Friends</group><group>Friends</group></item>\
                <item jid='nurse@example.com' ask='subscribe'/>\
                <item jid='bad@example.com/resource' subscription='both'/>\
                </query></iq>
                """)
            }
        }
        let client = try makeClient(server)
        try await client.connect()
        let roster = Roster(client: client)

        guard case .full(let items, let version) = try await roster.fetch(version: nil) else {
            Issue.record("expected the full roster")
            return
        }
        // The first fetch asks for a version with ver=''.
        #expect(try await sent(server) { $0.contains("jabber:iq:roster") }.contains("ver=''"))
        #expect(version == "v7")
        #expect(items.count == 2)
        #expect(items[0] == RosterItem(jid: try JID("romeo@example.net"), name: "Romeo", subscription: .both,
                                       groups: ["Friends"]))
        #expect(items[1].isPendingOut)
        #expect(items[1].subscription == .none)

        #expect(try await roster.fetch(version: "v7") == .unchanged)
        await client.disconnect()
    }

    @Test func omitsTheVersionWhenTheServerDoesNotVersion() async throws {
        let server = plainServer { xml, t in
            guard xml.contains("jabber:iq:roster"), let id = Script.attribute("id", in: xml) else { return }
            t.inject("<iq type='result' id='\(id)'><query xmlns='jabber:iq:roster'/></iq>")
        }
        let client = try makeClient(server)
        try await client.connect()
        #expect(try await Roster(client: client).fetch(version: "v7") == .full(items: [], version: nil))
        #expect(!(try await sent(server) { $0.contains("jabber:iq:roster") }.contains("ver=")))
        await client.disconnect()
    }

    @Test func acceptsPushesFromTheAccountOnly() async throws {
        let server = plainServer()
        let client = try makeClient(server)
        let pushes = Box<Roster.Push>()
        await Roster(client: client).handlePushes { pushes.append($0) }
        try await client.connect()

        server.inject("""
        <iq type='set' id='p1' from='juliet@example.com'><query xmlns='jabber:iq:roster' ver='v8'>\
        <item jid='romeo@example.net' subscription='remove'/></query></iq>
        """)
        #expect(IQ(try parse(try await sent(server) { $0.contains("id='p1'") }))?.type == .result)
        #expect(pushes.values == [Roster.Push(item: RosterItem(jid: try JID("romeo@example.net"), subscription: .remove),
                                              version: "v8")])

        // RFC 6121 §2.1.6: a push from anyone else is ignored.
        server.inject("""
        <iq type='set' id='p2' from='mallory@evil.example/x'><query xmlns='jabber:iq:roster'>\
        <item jid='mallory@evil.example' subscription='both'/></query></iq>
        """)
        let refused = IQ(try parse(try await sent(server) { $0.contains("id='p2'") }))
        #expect(refused?.error?.condition == .serviceUnavailable)

        server.inject("""
        <iq type='set' id='p3'><query xmlns='jabber:iq:roster'>\
        <item jid='a@example.com'/><item jid='b@example.com'/></query></iq>
        """)
        #expect(IQ(try parse(try await sent(server) { $0.contains("id='p3'") }))?.error?.condition == .badRequest)
        #expect(pushes.values.count == 1)
        await client.disconnect()
    }

    @Test func setsAndRemovesItemsWithoutServerOwnedAttributes() async throws {
        let server = plainServer { xml, t in
            guard xml.contains("jabber:iq:roster"), let id = Script.attribute("id", in: xml) else { return }
            t.inject("<iq type='result' id='\(id)'/>")
        }
        let client = try makeClient(server)
        try await client.connect()
        let roster = Roster(client: client)
        try await roster.set(RosterItem(jid: try JID("romeo@example.net"), name: "R", subscription: .both,
                                        isPendingOut: true, groups: ["A"]))
        let set = try parse(try await sent(server) { $0.contains("name='R'") })
        let item = try #require(set.firstChild()?.firstChild())
        #expect(item["subscription"] == nil)
        #expect(item["ask"] == nil)
        #expect(item.firstChild(name: "group")?.text == "A")

        try await roster.remove(try JID("romeo@example.net/ignored"))
        let removal = try parse(try await sent(server) { $0.contains("subscription='remove'") })
        #expect(removal.firstChild()?.firstChild()?["jid"] == "romeo@example.net")
        await client.disconnect()
    }
}

@Suite struct MessageArchiveTests {

    @Test func buildsTheQueryForm() throws {
        let query = MessageArchive.Query(with: try JID("romeo@example.net"),
                                         start: XMPPDateTime.parse("2010-08-07T00:00:00Z"),
                                         page: .after("A9"), max: 20)
        let element = MessageArchive.element(for: query, id: "q")
        let form = try #require(element.firstChild(name: "x").flatMap(DataForm.init(element:)))
        #expect(form.formType == Namespaces.mam)
        #expect(form["with"] == ["romeo@example.net"])
        #expect(form["start"] == ["2010-08-07T00:00:00.000Z"])
        let set = try #require(element.firstChild(name: "set", namespaceURI: Namespaces.rsm))
        #expect(set.firstChild(name: "max")?.text == "20")
        #expect(set.firstChild(name: "after")?.text == "A9")

        let latest = MessageArchive.element(for: .init(), id: "q")
        #expect(latest.firstChild(name: "set")?.firstChild(name: "before") != nil)
    }

    @Test func collectsResultsAndKeepsThemOffTheEventStream() async throws {
        let server = plainServer { xml, t in
            guard xml.contains("urn:xmpp:mam:2"), let id = Script.attribute("id", in: xml),
                  let queryID = Script.attribute("queryid", in: xml) else { return }
            func result(_ archiveID: String, from: String?, body: String) -> String {
                let fromAttr = from.map { " from='\($0)'" } ?? ""
                return """
                <message to='juliet@example.com/abc'\(fromAttr)><result xmlns='urn:xmpp:mam:2' queryid='\(queryID)' id='\(archiveID)'>\
                <forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='2010-07-10T23:08:25Z'/>\
                <message xmlns='jabber:client' from='romeo@example.net/a' to='juliet@example.com' type='chat'>\
                <body>\(body)</body></message></forwarded></result></message>
                """
            }
            t.inject(result("A1", from: nil, body: "one"))
            t.inject(result("A2", from: "juliet@example.com", body: "two"))
            t.inject(result("A3", from: "mallory@evil.example", body: "forged"))
            t.inject("""
            <iq type='result' id='\(id)'><fin xmlns='urn:xmpp:mam:2' complete='true'>\
            <set xmlns='http://jabber.org/protocol/rsm'><first>A1</first><last>A2</last></set></fin></iq>
            """)
        }
        let client = try makeClient(server)
        let archive = await MessageArchive(client: client)
        try await client.connect()

        async let delivered = deliveredMessages(client, for: .milliseconds(300))
        let page = try await archive.query(.init(page: .after(nil)))
        #expect(page.messages.map(\.message.body) == ["one", "two"])
        #expect(page.messages.map(\.archiveID) == ["A1", "A2"])
        #expect(page.messages.allSatisfy { $0.source == .archive && !$0.isOutgoing })
        #expect(page.messages.first?.timestamp == XMPPDateTime.parse("2010-07-10T23:08:25Z"))
        #expect(page.complete)
        #expect(page.first == "A1")
        #expect(page.last == "A2")
        // Results — even the forged one — were claimed, not delivered.
        #expect(await delivered.isEmpty)
        await client.disconnect()
    }

    @Test func ignoresResultsForUnknownQueries() async throws {
        let server = plainServer()
        let client = try makeClient(server)
        _ = await MessageArchive(client: client)
        try await client.connect()
        async let delivered = deliveredMessages(client)
        server.inject("""
        <message from='juliet@example.com'><result xmlns='urn:xmpp:mam:2' queryid='nope' id='A1'>\
        <forwarded xmlns='urn:xmpp:forward:0'><message xmlns='jabber:client' from='romeo@example.net/a'>\
        <body>stray</body></message></forwarded></result></message>
        """)
        #expect(await delivered.count == 1)
        await client.disconnect()
    }
}

@Suite struct BlockingTests {

    @Test func listsBlocksAndHandlesPushes() async throws {
        let server = plainServer { xml, t in
            guard xml.contains("urn:xmpp:blocking"), let id = Script.attribute("id", in: xml) else { return }
            if xml.contains("<blocklist") {
                t.inject("""
                <iq type='result' id='\(id)'><blocklist xmlns='urn:xmpp:blocking'>\
                <item jid='spam@example.org'/></blocklist></iq>
                """)
            } else {
                t.inject("<iq type='result' id='\(id)'/>")
            }
        }
        let client = try makeClient(server)
        let pushes = Box<Blocking.Push>()
        let blocking = Blocking(client: client)
        await blocking.handlePushes { pushes.append($0) }
        try await client.connect()

        #expect(try await blocking.blocklist() == [try JID("spam@example.org")])
        try await blocking.block([try JID("troll@example.org")])
        #expect(try await sent(server) { $0.contains("<block ") }.contains("troll@example.org"))

        server.inject("<iq type='set' id='b1'><block xmlns='urn:xmpp:blocking'><item jid='x@example.org'/></block></iq>")
        _ = try await sent(server) { $0.contains("id='b1'") }
        server.inject("<iq type='set' id='b2' from='juliet@example.com'><unblock xmlns='urn:xmpp:blocking'/></iq>")
        _ = try await sent(server) { $0.contains("id='b2'") }
        server.inject("<iq type='set' id='b3' from='mallory@evil.example'><unblock xmlns='urn:xmpp:blocking'/></iq>")
        #expect(IQ(try parse(try await sent(server) { $0.contains("id='b3'") }))?.error?.condition == .serviceUnavailable)

        #expect(pushes.values == [.blocked([try JID("x@example.org")]), .unblockedAll])
        await client.disconnect()
    }
}

@Suite struct PushTests {

    @Test func enablesWithPublishOptionsAndDisables() async throws {
        let server = plainServer { xml, t in
            guard let id = Script.attribute("id", in: xml) else { return }
            if xml.contains("disco#info") {
                t.inject("""
                <iq type='result' id='\(id)' from='juliet@example.com'><query xmlns='http://jabber.org/protocol/disco#info'>\
                <identity category='account' type='registered'/><feature var='urn:xmpp:push:0'/></query></iq>
                """)
            } else if xml.contains("urn:xmpp:push:0") {
                t.inject("<iq type='result' id='\(id)'/>")
            }
        }
        let client = try makeClient(server)
        try await client.connect()
        let push = PushNotifications(client: client)
        let service = try JID("push.example.org")

        #expect(try await push.isSupported())
        // §5: asked of the account's bare JID.
        #expect(try await sent(server) { $0.contains("disco#info") }.contains("to='juliet@example.com'"))

        try await push.enable(service: service, node: "token-1", publishOptions: ["pushModule": "prod", "secret": "s"])
        let enable = try #require(IQ(try parse(try await sent(server) { $0.contains("<enable") }))?.payload)
        #expect(enable["jid"] == "push.example.org")
        #expect(enable["node"] == "token-1")
        let form = try #require(enable.firstChild(name: "x", namespaceURI: Namespaces.dataForms).flatMap(DataForm.init(element:)))
        #expect(form.type == .submit)
        #expect(form.formType == Namespaces.publishOptions)
        #expect(form["pushModule"] == ["prod"])
        #expect(form["secret"] == ["s"])

        try await push.disable(service: service, node: nil)
        let disable = try #require(IQ(try parse(try await sent(server) { $0.contains("<disable") }))?.payload)
        #expect(disable["jid"] == "push.example.org")
        #expect(disable["node"] == nil)
        await client.disconnect()
    }

    @Test func enableWithoutOptionsHasNoForm() {
        let enable = PushNotifications.enable(service: try! JID("push.example.org"), node: "n", publishOptions: [:])
        #expect(enable.elements.isEmpty)
    }

    @Test func parsesAPublishedNotification() throws {
        let iq = try #require(IQ(try parse("""
        <iq type='set' id='p1' from='example.com' to='push.example.org'>\
        <pubsub xmlns='http://jabber.org/protocol/pubsub'><publish node='token-1'><item>\
        <notification xmlns='urn:xmpp:push:0'><x xmlns='jabber:x:data' type='submit'>\
        <field var='FORM_TYPE'><value>urn:xmpp:push:summary</value></field>\
        <field var='message-count'><value>3</value></field>\
        <field var='last-message-sender'><value>romeo@example.net/orchard</value></field>\
        </x></notification></item></publish>\
        <publish-options><x xmlns='jabber:x:data' type='submit'>\
        <field var='FORM_TYPE'><value>http://jabber.org/protocol/pubsub#publish-options</value></field>\
        <field var='pushModule'><value>prod</value></field></x></publish-options>\
        </pubsub></iq>
        """)))
        let notification = try #require(PushNotification(iq))
        #expect(notification.node == "token-1")
        #expect(notification.messageCount == 3)
        #expect(notification.lastMessageSender == "romeo@example.net/orchard")
        #expect(notification.lastMessageBody == nil)
        #expect(notification.publishOptions == ["pushModule": "prod"])

        #expect(PushNotification(try #require(IQ(try parse("<iq type='get' id='x'><pubsub xmlns='http://jabber.org/protocol/pubsub'/></iq>")))) == nil)
    }
}
