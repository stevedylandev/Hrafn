import Testing
import Foundation
import XMPPClient
import XMPPStream
import XMPPTransport
import XMPPTestSupport
import XMPPCore
import XMPPXML

/// Phase 2 exit criteria against the live servers: reliable login and graceful
/// logout, and unknown IQs answered with `service-unavailable`.
/// Off unless `HRAFN_INTEGRATION=1`; see `TestServers.swift`.
private func client(
    _ user: String, on server: TestServer, security: TransportSecurity = .directTLS,
    password: String = devPassword, channelBinding: Bool = true, sasl2: Bool = true,
    tokens: (any FASTTokenStore)? = nil
) throws -> XMPPClient {
    var configuration = SessionConfiguration(
        credentials: try Credentials(jid: try JID("\(user)@\(server.domain)"), password: password),
        tlsPolicy: try server.trustPolicy(),
        endpoints: [server.endpoint(security)],
        allowPlain: false,
        allowChannelBinding: channelBinding,
        console: ProcessInfo.processInfo.environment["HRAFN_XML"] == "1"
            ? RedactingXMLConsole(PrintXMLConsole()) : nil)
    configuration.allowSASL2 = sasl2
    if let tokens {
        configuration.userAgent = UserAgent(id: fastAgent, software: "Hrafn", device: "Tests")
        configuration.fastTokens = tokens
    }
    return XMPPClient(configuration: configuration,
                      identity: ClientIdentity(name: "Hrafn", node: "https://example.org/hrafn"))
}

/// One user agent for the FAST tests: tokens belong to the agent that asked.
private let fastAgent = UUID()

final class MemoryTokenStore: FASTTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: FASTToken?
    init(_ token: FASTToken? = nil) { self.token = token }
    func load() -> FASTToken? { lock.withLock { token } }
    func save(_ token: FASTToken?) { lock.withLock { self.token = token } }
}

@Suite(.enabled(if: integrationEnabled), .serialized)
struct ClientIntegrationTests {

    /// XEP-0388/0386/0484: the first login uses the password over SASL2 and
    /// gets a token; the next uses the token (bound to TLS on Direct TLS);
    /// a token the server no longer knows is dropped and the password used
    /// again on the same stream. Legacy SASL still works when SASL2 is off.
    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func fastTokens(_ server: TestServer) async throws {
        let tokens = MemoryTokenStore()
        let first = try client("juliet", on: server, tokens: tokens)
        try await first.connect()
        #expect(await first.sessionMechanism == server.strongestMechanism + "-PLUS")
        await first.disconnect()
        let issued = try #require(tokens.load())
        #expect(issued.mechanism == "HT-SHA-256-EXPR")

        let second = try client("juliet", on: server, tokens: tokens)
        try await second.connect()
        #expect(await second.sessionMechanism == "HT-SHA-256-EXPR")
        #expect(await second.jid?.isFull == true)
        #expect(await second.isStreamManagementEnabled, "enabled inside Bind 2")
        #expect(try await second.ping() < .seconds(2))
        await second.disconnect()
        #expect(tokens.load() != nil)

        tokens.save(FASTToken(mechanism: "HT-SHA-256-EXPR", secret: "not-a-token", expiry: nil))
        let third = try client("juliet", on: server, tokens: tokens)
        try await third.connect()
        #expect(await third.sessionMechanism == server.strongestMechanism + "-PLUS")
        #expect(tokens.load()?.secret != "not-a-token", "a fresh token replaced the bad one")
        await third.disconnect()

        let legacy = try client("juliet", on: server, sasl2: false)
        try await legacy.connect()
        #expect(try await legacy.ping() < .seconds(2))
        #expect(await legacy.isStreamManagementEnabled)
        await legacy.disconnect()
    }

    /// Direct TLS on TLS 1.3 exposes the exporter, so the -PLUS variant is used;
    /// STARTTLS cannot bind, so plain SCRAM with the "n" flag.
    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func logsInOverBothTransports(_ server: TestServer) async throws {
        for security in [TransportSecurity.directTLS, .startTLS] {
            let juliet = try client("juliet", on: server, security: security)
            try await juliet.connect()
            let jid = try #require(await juliet.jid)
            #expect(jid.bare == (try JID("juliet@\(server.domain)")))
            #expect(jid.isFull)
            let mechanism = try #require(await juliet.sessionMechanism)
            print("[\(server.domain) \(security)] authenticated with \(mechanism) as \(jid)")
            if security == .directTLS {
                #expect(mechanism == server.strongestMechanism + "-PLUS")
            } else {
                #expect(mechanism == server.strongestMechanism)
            }
            await juliet.disconnect()
            #expect(await juliet.state == .disconnected)
        }
    }

    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func logsInWithoutChannelBinding(_ server: TestServer) async throws {
        let juliet = try client("juliet", on: server, channelBinding: false)
        try await juliet.connect()
        #expect(await juliet.sessionMechanism == server.strongestMechanism)
        await juliet.disconnect()
    }

    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func rejectsAWrongPassword(_ server: TestServer) async throws {
        let juliet = try client("juliet", on: server, password: "not-the-password")
        let error = await #expect(throws: SessionError.self) { try await juliet.connect() }
        guard case .authenticationFailed(let condition, _) = error else {
            Issue.record("unexpected error: \(String(describing: error))")
            return
        }
        #expect(condition == "not-authorized")
        #expect(await juliet.state == .disconnected)
    }

    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func pingsAndDiscoversTheServer(_ server: TestServer) async throws {
        let juliet = try client("juliet", on: server)
        try await juliet.connect()
        let rtt = try await juliet.ping(try JID(server.domain))
        #expect(rtt < .seconds(2))

        let info = try await juliet.discoInfo(try JID(server.domain))
        #expect(info.identities.contains { $0.category == "server" && $0.type == "im" })
        #expect(info.supports(Namespaces.ping))
        await juliet.disconnect()
    }

    /// Two sessions on one server: the second exercises the first's responders
    /// through real routing.
    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func answersPeersThroughTheServer(_ server: TestServer) async throws {
        let juliet = try client("juliet", on: server)
        let romeo = try client("romeo", on: server)
        try await juliet.connect()
        try await romeo.connect()
        let julietJID = try #require(await juliet.jid)

        // Exit criterion: an IQ nobody handles gets service-unavailable.
        await #expect(throws: StanzaError(.serviceUnavailable, type: .cancel)) {
            try await romeo.send(IQ(type: .get, to: julietJID,
                                    payload: Element(name: "query", namespaceURI: "urn:example:unknown")),
                                 timeout: .seconds(5))
        }

        #expect(try await romeo.ping(julietJID, timeout: .seconds(5)) < .seconds(2))

        let info = try await romeo.discoInfo(julietJID)
        #expect(info.identities.first?.name == "Hrafn")
        #expect(info.supports(Namespaces.caps))
        let caps = await juliet.capsElement
        let nodeInfo = try await romeo.discoInfo(julietJID, node: "\(caps["node"]!)#\(caps["ver"]!)")
        #expect(try nodeInfo.capsVerification() == caps["ver"])

        await romeo.disconnect()
        await juliet.disconnect()
    }

    /// Logging in twice with the same resource: the server resolves the
    /// conflict, and neither login fails.
    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func survivesAResourceConflict(_ server: TestServer) async throws {
        var configuration = try client("juliet", on: server).configuration
        configuration.resource = "conflict-test"
        let first = XMPPClient(configuration: configuration,
                               identity: ClientIdentity(name: "Hrafn", node: "https://example.org/hrafn"))
        let second = XMPPClient(configuration: configuration,
                                identity: ClientIdentity(name: "Hrafn", node: "https://example.org/hrafn"))
        try await first.connect()
        try await second.connect()
        #expect(await second.jid != nil)
        await second.disconnect()
        await first.disconnect()
    }
}
