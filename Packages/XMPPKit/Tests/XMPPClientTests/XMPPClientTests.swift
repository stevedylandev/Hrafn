import Testing
import Foundation
@testable import XMPPClient
@testable import XMPPStream
import XMPPTransport
import XMPPTestSupport
import XMPPCore
import XMPPXML

private let identity = ClientIdentity(name: "Hrafn", node: "https://example.org/hrafn")

private func makeClient(_ transport: ScriptedTransport) throws -> XMPPClient {
    let endpoint = Endpoint(host: "example.com", port: 5223, security: .directTLS, domain: "example.com")
    let configuration = SessionConfiguration(
        credentials: try Credentials(jid: try JID("juliet@example.com"), password: "secret"),
        tlsPolicy: .insecureAcceptAll,
        endpoints: [endpoint],
        negotiationTimeout: .seconds(2))
    let negotiator = SessionNegotiator(configuration: configuration) { endpoint, configuration in
        XMLStream(endpoint: endpoint, domain: configuration.credentials.jid.domain,
                  policy: configuration.tlsPolicy, transport: transport,
                  negotiationTimeout: configuration.negotiationTimeout)
    }
    return XMPPClient(configuration: configuration, identity: identity, negotiator: negotiator,
                      resilience: .oneShot)
}

/// Waits for the client to send a chunk matching `predicate`.
private func sent(_ transport: ScriptedTransport, where predicate: (String) -> Bool) async throws -> String {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if let match = transport.sent.first(where: predicate) { return match }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("nothing matching was sent; sent: \(transport.sent)")
    throw ClientError.timedOut
}

private func parse(_ xml: String) throws -> Element {
    let parser = StreamParser()
    _ = try parser.parse(Array(Script.header.utf8))
    let events = try parser.parse(Array(xml.utf8))
    guard case .stanza(let element) = events.first else { throw ClientError.notConnected }
    return element
}

@Suite struct XMPPClientTests {

    @Test func connectsAndReportsTheBoundJID() async throws {
        let client = try makeClient(plainServer())
        try await client.connect()
        #expect(await client.jid == (try JID("juliet@example.com/abc")))
        #expect(await client.state == .connected(try JID("juliet@example.com/abc")))
        await client.disconnect()
        #expect(await client.state == .disconnected)
    }

    // MARK: Inbound IQ routing

    /// RFC 6120 §8.4: an IQ nobody handles is answered, not dropped.
    @Test func answersUnknownIQsWithServiceUnavailable() async throws {
        let server = plainServer()
        let client = try makeClient(server)
        try await client.connect()
        server.inject("<iq type='get' id='q1' from='romeo@example.com/x'><query xmlns='urn:example:unknown'/></iq>")

        let reply = try parse(try await sent(server) { $0.contains("id='q1'") })
        #expect(reply["type"] == "error")
        #expect(reply["to"] == "romeo@example.com/x")
        #expect(IQ(reply)?.error?.condition == .serviceUnavailable)
        await client.disconnect()
    }

    @Test func answersPayloadlessIQsWithBadRequest() async throws {
        let server = plainServer()
        let client = try makeClient(server)
        try await client.connect()
        server.inject("<iq type='set' id='q2' from='example.com'/>")
        let reply = try parse(try await sent(server) { $0.contains("id='q2'") })
        #expect(IQ(reply)?.error?.condition == .badRequest)
        await client.disconnect()
    }

    @Test func answersPings() async throws {
        let server = plainServer()
        let client = try makeClient(server)
        try await client.connect()
        server.inject("<iq type='get' id='p1' from='example.com'><ping xmlns='urn:xmpp:ping'/></iq>")
        let reply = try parse(try await sent(server) { $0.contains("id='p1'") })
        #expect(reply["type"] == "result")
        #expect(reply.elements.isEmpty)
        await client.disconnect()
    }

    @Test func answersDiscoInfoIncludingTheCapsNode() async throws {
        let server = plainServer()
        let client = try makeClient(server)
        await client.addFeature("urn:xmpp:example:0")
        try await client.connect()

        server.inject("<iq type='get' id='d1' from='romeo@example.com/x'><query xmlns='http://jabber.org/protocol/disco#info'/></iq>")
        let reply = try parse(try await sent(server) { $0.contains("id='d1'") })
        let info = DiscoInfo(query: try #require(IQ(reply)?.payload))
        #expect(info.identities == [.init(category: "client", type: "phone", name: "Hrafn")])
        #expect(info.supports(Namespaces.ping))
        #expect(info.supports("urn:xmpp:example:0"))

        // The caps node echoes back; any other node does not exist.
        let caps = await client.capsElement
        let node = "\(caps["node"]!)#\(caps["ver"]!)"
        #expect(caps["ver"] == (try info.capsVerification()))
        server.inject("<iq type='get' id='d2' from='romeo@example.com/x'><query xmlns='http://jabber.org/protocol/disco#info' node='\(node)'/></iq>")
        let nodeReply = try parse(try await sent(server) { $0.contains("id='d2'") })
        #expect(IQ(nodeReply)?.payload?["node"] == node)

        server.inject("<iq type='get' id='d3' from='romeo@example.com/x'><query xmlns='http://jabber.org/protocol/disco#info' node='bogus'/></iq>")
        let bogus = try parse(try await sent(server) { $0.contains("id='d3'") })
        #expect(IQ(bogus)?.error?.condition == .itemNotFound)
        await client.disconnect()
    }

    @Test func routesToRegisteredHandlersAndAdvertisesThem() async throws {
        let server = plainServer()
        let client = try makeClient(server)
        await client.setHandler(name: "query", namespace: "jabber:iq:version") { _ in
            Element(name: "query", namespaceURI: "jabber:iq:version")
                .adding(Element(name: "name", namespaceURI: "jabber:iq:version", text: "Hrafn"))
        }
        await client.setHandler(name: "q", namespace: "urn:example:fails") { _ in
            throw StanzaError(.forbidden)
        }
        try await client.connect()
        #expect(await client.ownDiscoInfo.supports("jabber:iq:version"))

        server.inject("<iq type='get' id='v1' from='example.com'><query xmlns='jabber:iq:version'/></iq>")
        let reply = try parse(try await sent(server) { $0.contains("id='v1'") })
        #expect(IQ(reply)?.payload?.firstChild(name: "name")?.text == "Hrafn")

        server.inject("<iq type='set' id='f1' from='example.com'><q xmlns='urn:example:fails'/></iq>")
        let failed = try parse(try await sent(server) { $0.contains("id='f1'") })
        #expect(IQ(failed)?.error?.condition == .forbidden)
        await client.disconnect()
    }

    /// RFC 6120 §10.1: requests reach handlers in stream order, even when an
    /// earlier one takes longer — two roster pushes must not swap.
    @Test func handlesRequestsInStreamOrder() async throws {
        let server = plainServer()
        let client = try makeClient(server)
        actor Seen { var ids: [String] = []; func add(_ id: String) { ids.append(id) } }
        let seen = Seen()
        await client.setHandler(name: "q", namespace: "urn:example:order") { iq in
            if iq.id == "o1" { try await Task.sleep(for: .milliseconds(200)) }
            await seen.add(iq.id ?? "")
            return nil
        }
        try await client.connect()
        server.inject("<iq type='set' id='o1' from='example.com'><q xmlns='urn:example:order'/></iq>")
        server.inject("<iq type='set' id='o2' from='example.com'><q xmlns='urn:example:order'/></iq>")
        _ = try await sent(server) { $0.contains("id='o2'") }
        #expect(await seen.ids == ["o1", "o2"])
        await client.disconnect()
    }

    // MARK: IQ tracker

    private func echoingServer(from: String? = nil, error: Bool = false) -> ScriptedTransport {
        plainServer { xml, t in
            guard xml.hasPrefix("<iq"), let id = Script.attribute("id", in: xml) else { return }
            let fromAttribute = from.map { " from='\($0)'" } ?? ""
            if error {
                t.inject("""
                <iq type='error' id='\(id)'\(fromAttribute)><error type='cancel'>\
                <item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>
                """)
            } else {
                t.inject("<iq type='result' id='\(id)'\(fromAttribute)><ok xmlns='urn:example'/></iq>")
            }
        }
    }

    @Test func resolvesRequestsWithTheirResult() async throws {
        let client = try makeClient(echoingServer())
        try await client.connect()
        let reply = try await client.send(IQ(type: .get, payload: Element(name: "q", namespaceURI: "urn:example")))
        #expect(reply.payload?.name == "ok")
        #expect(try await client.ping() < .seconds(2))
        await client.disconnect()
    }

    @Test func throwsErrorRepliesAsStanzaErrors() async throws {
        let client = try makeClient(echoingServer(error: true))
        try await client.connect()
        await #expect(throws: StanzaError(.itemNotFound, type: .cancel)) {
            try await client.send(IQ(type: .get, payload: Element(name: "q", namespaceURI: "urn:example")))
        }
        await client.disconnect()
    }

    /// A reply from someone other than the addressee is a forgery and must not
    /// resolve the request (RFC 6120 §8.2.3).
    @Test func ignoresRepliesFromTheWrongSender() async throws {
        let client = try makeClient(echoingServer(from: "mallory@evil.example/x"))
        try await client.connect()
        await #expect(throws: ClientError.timedOut) {
            try await client.send(IQ(type: .get, to: try JID("romeo@example.com/x"),
                                     payload: Element(name: "q", namespaceURI: "urn:example")),
                                  timeout: .milliseconds(200))
        }
        await #expect(throws: ClientError.timedOut) {
            try await client.send(IQ(type: .get, payload: Element(name: "q", namespaceURI: "urn:example")),
                                  timeout: .milliseconds(200))
        }
        await client.disconnect()
    }

    @Test func acceptsServerRepliesFromTheAccountOrDomain() async throws {
        for from in ["juliet@example.com", "juliet@example.com/abc", "example.com"] {
            let client = try makeClient(echoingServer(from: from))
            try await client.connect()
            _ = try await client.send(IQ(type: .get, payload: Element(name: "q", namespaceURI: "urn:example")),
                                      timeout: .seconds(1))
            await client.disconnect()
        }
    }

    @Test func failsOutstandingRequestsOnDisconnect() async throws {
        let client = try makeClient(plainServer())
        try await client.connect()
        let reply = Task {
            try await client.send(IQ(type: .get, payload: Element(name: "q", namespaceURI: "urn:example")))
        }
        try await Task.sleep(for: .milliseconds(50))
        await client.disconnect()
        await #expect(throws: ClientError.disconnected) { try await reply.value }
    }

    @Test func cancellingARequestResumesIt() async throws {
        let client = try makeClient(plainServer())
        try await client.connect()
        let task = Task {
            try await client.send(IQ(type: .get, payload: Element(name: "q", namespaceURI: "urn:example")))
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await client.disconnect()
    }

    @Test func refusesToSendWhileDisconnected() async throws {
        let client = try makeClient(plainServer())
        await #expect(throws: ClientError.notConnected) {
            try await client.send(IQ(type: .get, payload: Element(name: "q", namespaceURI: "urn:example")))
        }
    }

    // MARK: Events

    @Test func deliversMessagesAndPresenceInOrder() async throws {
        let server = plainServer()
        let client = try makeClient(server)
        try await client.connect()
        server.inject("""
        <message type='chat' from='romeo@example.com/x' id='m1'><body>hi</body></message>\
        <presence from='romeo@example.com/x'/>
        """)

        var received: [String] = []
        for await event in client.events {
            switch event {
            case .message(let message): received.append("message:\(message.body ?? "")")
            case .presence(let presence): received.append("presence:\(presence.type)")
            default: continue
            }
            if received.count == 2 { break }
        }
        #expect(received == ["message:hi", "presence:available"])
        await client.disconnect()
    }

    @Test func aStreamErrorEndsTheSession() async throws {
        let server = plainServer()
        let client = try makeClient(server)
        try await client.connect()
        server.inject("""
        <stream:error><conflict xmlns='urn:ietf:params:xml:ns:xmpp-streams'/></stream:error></stream:stream>
        """)
        for await event in client.events {
            guard case .disconnected(let error) = event else { continue }
            #expect(error as? XMLStream.Failure == .streamError(condition: "conflict", text: nil))
            break
        }
        #expect(await client.state == .disconnected)
    }

    @Test func aDroppedConnectionEndsTheSession() async throws {
        let server = plainServer()
        let client = try makeClient(server)
        try await client.connect()
        server.endOfStream()
        for await event in client.events {
            guard case .disconnected(let error) = event else { continue }
            #expect(error != nil)
            break
        }
        #expect(await client.state == .disconnected)
    }

    @Test func gracefulDisconnectClosesTheStream() async throws {
        let server = plainServer()
        let client = try makeClient(server)
        try await client.connect()
        try await client.send(Message(to: try JID("romeo@example.com"), body: "bye"))
        await client.disconnect()
        let sent = server.sent
        let messageIndex = try #require(sent.firstIndex { $0.contains("<body>bye</body>") })
        let closeIndex = try #require(sent.firstIndex { $0 == "</stream:stream>" })
        #expect(messageIndex < closeIndex, "queued stanzas are flushed before the stream closes")
    }
}

/// XEP-0115 §5.2 and §5.3 worked examples.
@Suite struct CapsTests {

    @Test func simpleExample() throws {
        let info = DiscoInfo(
            identities: [.init(category: "client", type: "pc", name: "Exodus 0.9.1")],
            features: ["http://jabber.org/protocol/disco#info", "http://jabber.org/protocol/disco#items",
                       "http://jabber.org/protocol/muc", "http://jabber.org/protocol/caps"])
        #expect(try info.capsVerificationInput() == """
        client/pc//Exodus 0.9.1<http://jabber.org/protocol/caps<http://jabber.org/protocol/disco#info<\
        http://jabber.org/protocol/disco#items<http://jabber.org/protocol/muc<
        """)
        #expect(try info.capsVerification() == "QgayPKawpkPSDYmwT/WM94uAlu0=")
    }

    @Test func complexExample() throws {
        let query = try parse("""
        <iq type='result' id='x'><query xmlns='http://jabber.org/protocol/disco#info'>\
        <identity xml:lang='en' category='client' name='Psi 0.11' type='pc'/>\
        <identity xml:lang='el' category='client' name='Ψ 0.11' type='pc'/>\
        <feature var='http://jabber.org/protocol/caps'/>\
        <feature var='http://jabber.org/protocol/disco#info'/>\
        <feature var='http://jabber.org/protocol/disco#items'/>\
        <feature var='http://jabber.org/protocol/muc'/>\
        <x xmlns='jabber:x:data' type='result'>\
        <field var='FORM_TYPE' type='hidden'><value>urn:xmpp:dataforms:softwareinfo</value></field>\
        <field var='ip_version'><value>ipv4</value><value>ipv6</value></field>\
        <field var='os'><value>Mac</value></field>\
        <field var='os_version'><value>10.5.1</value></field>\
        <field var='software'><value>Psi</value></field>\
        <field var='software_version'><value>0.11</value></field>\
        </x></query></iq>
        """)
        let info = DiscoInfo(query: try #require(IQ(query)?.payload))
        #expect(try info.capsVerificationInput() == """
        client/pc/el/Ψ 0.11<client/pc/en/Psi 0.11<http://jabber.org/protocol/caps<\
        http://jabber.org/protocol/disco#info<http://jabber.org/protocol/disco#items<\
        http://jabber.org/protocol/muc<urn:xmpp:dataforms:softwareinfo<ip_version<ipv4<ipv6<\
        os<Mac<os_version<10.5.1<software<Psi<software_version<0.11<
        """)
        #expect(try info.capsVerification() == "q07IKJEyjvHSyhy//CH0CxmKi8w=")
    }

    /// §5.4: inputs that make a hash ambiguous are refused rather than hashed.
    @Test func refusesUnverifiableInput() {
        let identity = DiscoInfo.Identity(category: "client", type: "pc")
        #expect(throws: DiscoInfo.CapsError.duplicateIdentity) {
            try DiscoInfo(identities: [identity, identity], features: []).capsVerification()
        }
        #expect(throws: DiscoInfo.CapsError.duplicateFeature) {
            try DiscoInfo(identities: [identity], features: ["a", "a"]).capsVerification()
        }
        let form = DataForm(type: .result, fields: [.init(variable: "FORM_TYPE", type: "hidden", values: ["urn:x"])])
        #expect(throws: DiscoInfo.CapsError.duplicateFormType) {
            try DiscoInfo(identities: [identity], features: [], forms: [form, form]).capsVerification()
        }
        let visible = DataForm(type: .result, fields: [.init(variable: "FORM_TYPE", type: "text-single", values: ["urn:x"])])
        #expect(throws: DiscoInfo.CapsError.formTypeNotHidden) {
            try DiscoInfo(identities: [identity], features: [], forms: [visible]).capsVerification()
        }
    }
}
