import Testing
import Foundation
@testable import XMPPClient
@testable import XMPPStream
import XMPPIM
import XMPPTransport
import XMPPTestSupport
import XMPPCore
import XMPPXML

let identity = ClientIdentity(name: "Hrafn", node: "https://example.org/hrafn")
let juliet = try! JID("juliet@example.com")

func makeClient(_ transport: ScriptedTransport) throws -> XMPPClient {
    let endpoint = Endpoint(host: "example.com", port: 5223, security: .directTLS, domain: "example.com")
    let configuration = SessionConfiguration(
        credentials: try Credentials(jid: juliet, password: "secret"),
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
func sent(_ transport: ScriptedTransport, where predicate: (String) -> Bool) async throws -> String {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if let match = transport.sent.first(where: predicate) { return match }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("nothing matching was sent; sent: \(transport.sent)")
    throw ClientError.timedOut
}

func parse(_ xml: String) throws -> Element {
    let parser = StreamParser()
    _ = try parser.parse(Array(Script.header.utf8))
    let events = try parser.parse(Array(xml.utf8))
    guard case .stanza(let element) = events.first else { throw ClientError.notConnected }
    return element
}

func message(_ xml: String) throws -> Message {
    try #require(Message(try parse(xml)))
}

/// Collects messages delivered on `events` for a short while.
func deliveredMessages(_ client: XMPPClient, for duration: Duration = .milliseconds(200)) async -> [Message] {
    await withTaskGroup(of: [Message].self) { group in
        group.addTask {
            var out: [Message] = []
            for await event in client.events {
                if case .message(let m) = event { out.append(m) }
            }
            return out
        }
        try? await Task.sleep(for: duration)
        group.cancelAll()
        return await group.next() ?? []
    }
}

// MARK: - Live servers

/// A client for a `scripts/dev-accounts.sh` account on a Docker server.
func liveClient(_ user: String, on server: TestServer, sasl2: Bool = true) throws -> XMPPClient {
    var configuration = SessionConfiguration(
        credentials: try Credentials(jid: try JID("\(user)@\(server.domain)"), password: devPassword),
        tlsPolicy: try server.trustPolicy(),
        endpoints: [server.endpoint(.directTLS)],
        allowPlain: false,
        console: ProcessInfo.processInfo.environment["HRAFN_XML"] == "1"
            ? RedactingXMLConsole(PrintXMLConsole()) : nil)
    configuration.allowSASL2 = sasl2
    return XMPPClient(configuration: configuration, identity: identity, resilience: .oneShot)
}

/// The first event `match` accepts, within `timeout`.
func next<T: Sendable>(_ client: XMPPClient, timeout: Duration = .seconds(5),
                       _ match: @escaping @Sendable (XMPPClient.Event) -> T?) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            for await event in client.events { if let value = match(event) { return value } }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() ?? nil else { throw ClientError.timedOut }
        return value
    }
}

func nextMessage(_ client: XMPPClient, account: JID,
                 where predicate: @escaping @Sendable (InboundMessage) -> Bool) async throws -> InboundMessage {
    try await next(client) { event in
        guard case .message(let m) = event, let inbound = InboundMessage(live: m, account: account),
              predicate(inbound) else { return nil }
        return inbound
    }
}
