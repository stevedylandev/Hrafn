import Testing
import Foundation
import CryptoKit
@testable import XMPPStream
import XMPPTransport
import XMPPTestSupport
import XMPPCore
import XMPPXML

private let endpoint = Endpoint(host: "example.com", port: 5223, security: .directTLS, domain: "example.com")

private func negotiator(
    password: String = "secret",
    resource: String? = nil,
    transports: [ScriptedTransport]
) throws -> SessionNegotiator {
    let configuration = SessionConfiguration(
        credentials: try Credentials(jid: try JID("juliet@example.com"), password: password),
        resource: resource,
        tlsPolicy: .insecureAcceptAll,
        endpoints: transports.map { _ in endpoint },
        negotiationTimeout: .seconds(2))
    let queue = TransportQueue(transports)
    return SessionNegotiator(configuration: configuration) { endpoint, configuration in
        XMLStream(endpoint: endpoint, domain: configuration.credentials.jid.domain,
                  policy: configuration.tlsPolicy, transport: queue.next(),
                  negotiationTimeout: configuration.negotiationTimeout)
    }
}

/// Hands out one transport per connection attempt.
private final class TransportQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [ScriptedTransport]
    init(_ transports: [ScriptedTransport]) { remaining = transports }
    func next() -> ScriptedTransport { lock.withLock { remaining.removeFirst() } }
}

@Suite struct SessionNegotiatorTests {

    @Test func authenticatesRestartsAndBinds() async throws {
        let server = plainServer()
        let session = try await negotiator(transports: [server]).establish()
        #expect(session.jid == (try JID("juliet@example.com/abc")))
        #expect(session.mechanism == "PLAIN")
        #expect(session.features.firstChild(name: "bind", namespaceURI: Namespaces.bind) != nil)

        // Every header on an encrypted stream names the account (RFC 6120
        // §4.7.1): this transport is encrypted from the start, like Direct TLS.
        let headers = server.sent.filter { $0.hasPrefix("<stream:stream") }
        #expect(headers.count == 2)
        #expect(headers.allSatisfy { $0.contains("from='juliet@example.com'") })
        await session.stream.close()
    }

    /// On a plaintext connection the first header keeps the account to itself.
    @Test func plaintextHeaderOmitsTheAccount() async throws {
        let transport = ScriptedTransport(encrypted: false)
        let stream = XMLStream(endpoint: endpoint, domain: try JID("example.com"), policy: .standard(),
                               transport: transport, negotiationTimeout: .seconds(2))
        transport.respond = { xml, t in
            if xml.hasPrefix("<stream:stream") {
                t.inject("<?xml version='1.0'?><stream:stream id='s' from='example.com' version='1.0' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>")
            }
        }
        try await stream.open(from: try JID("juliet@example.com"), onlyIfEncrypted: true)
        #expect(transport.sent.first { $0.hasPrefix("<stream:stream") }?.contains("from=") == false)
        await stream.close()
    }

    @Test func reportsPhasesInOrder() async throws {
        let phases = PhaseLog()
        let session = try await negotiator(transports: [plainServer()]).establish { phases.append($0) }
        #expect(phases.all == [.connecting(endpoint), .authenticating, .binding,
                               .established(try JID("juliet@example.com/abc"))])
        await session.stream.close()
    }

    /// A wrong password is not worth trying on the next endpoint.
    @Test func authenticationFailureIsFatal() async throws {
        let first = plainServer(password: "other")
        let second = plainServer()
        let negotiator = try negotiator(transports: [first, second])
        await #expect(throws: SessionError.authenticationFailed(condition: "not-authorized", text: nil)) {
            try await negotiator.establish()
        }
        #expect(second.sent.isEmpty)
    }

    /// A transport-level failure moves on to the next endpoint.
    @Test func fallsThroughToTheNextEndpoint() async throws {
        let dead = ScriptedTransport()
        dead.respond = { _, t in t.endOfStream() }
        let session = try await negotiator(transports: [dead, plainServer()]).establish()
        #expect(session.jid.resourcepart == "abc")
        await session.stream.close()
    }

    @Test func refusesWhenNoMechanismIsUsable() async throws {
        let server = ScriptedTransport()
        server.respond = { xml, t in
            if xml.hasPrefix("<stream:stream") {
                t.inject(Script.header)
                t.inject(Script.features(Script.mechanisms("X-OAUTH2", "DIGEST-MD5")))
            }
        }
        await #expect(throws: SessionError.noUsableMechanism(offered: ["X-OAUTH2", "DIGEST-MD5"])) {
            try await negotiator(transports: [server]).establish()
        }
    }

    /// RFC 6120 §7.7.2.2: a conflicting resource falls back to a server-chosen one.
    @Test func retriesBindingWithoutAResourceOnConflict() async throws {
        let server = plainServer()
        let inner = server.respond!
        server.respond = { xml, t in
            if xml.contains("<resource>phone</resource>") {
                let id = Script.attribute("id", in: xml)!
                t.inject("""
                <iq type='error' id='\(id)'><error type='cancel'>\
                <conflict xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>
                """)
            } else {
                inner(xml, t)
            }
        }
        let session = try await negotiator(resource: "phone", transports: [server]).establish()
        #expect(session.jid.resourcepart == "abc")
        let binds = server.sent.filter { $0.contains("xmpp-bind") }
        #expect(binds.count == 2)
        #expect(binds[1].contains("<resource>") == false)
        await session.stream.close()
    }

    @Test func sendsAMandatoryLegacySession() async throws {
        let server = plainServer(extraFeatures: "<session xmlns='urn:ietf:params:xml:ns:xmpp-session'/>")
        let inner = server.respond!
        server.respond = { xml, t in
            if xml.contains("xmpp-session") {
                t.inject("<iq type='result' id='\(Script.attribute("id", in: xml)!)'/>")
            } else {
                inner(xml, t)
            }
        }
        let session = try await negotiator(transports: [server]).establish()
        #expect(server.sent.contains { $0.contains("xmpp-session") })
        await session.stream.close()

        let optional = plainServer(extraFeatures:
            "<session xmlns='urn:ietf:params:xml:ns:xmpp-session'><optional/></session>")
        let skipped = try await negotiator(transports: [optional]).establish()
        #expect(!optional.sent.contains { $0.contains("xmpp-session") })
        await skipped.stream.close()
    }

    /// A server that claims success without proving it knows the password is
    /// refused, and told so with <abort/>.
    @Test func scramRejectsAnUnprovenSuccess() async throws {
        let server = ScriptedTransport()
        server.respond = { xml, t in
            if xml.hasPrefix("<stream:stream") {
                t.inject(Script.header)
                t.inject(Script.features(Script.mechanisms("SCRAM-SHA-256")))
            } else if xml.hasPrefix("<auth") {
                let first = String(decoding: Data(base64Encoded: Script.text(of: "auth", in: xml)!)!, as: UTF8.self)
                let nonce = first.components(separatedBy: "r=").last!
                let challenge = "r=\(nonce)SRV,s=QSXCR+Q6sek8bf92,i=4096"
                t.inject("<challenge xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\(Data(challenge.utf8).base64EncodedString())</challenge>")
            } else if xml.hasPrefix("<response") {
                t.inject("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
            }
        }
        await #expect(throws: SessionError.sasl(mechanism: "SCRAM-SHA-256", .serverSignatureMissing)) {
            try await negotiator(transports: [server]).establish()
        }
        #expect(server.sent.contains { $0.contains("<abort") })
    }

    /// Without an exporter the GS2 flag is "n"; with one but no -PLUS offer, "y".
    @Test func scramUsesYWhenBindingIsPossibleButNotOffered() async throws {
        for (exporter, flag) in [(nil, "n,,"), (Data(count: 32), "y,,")] as [(Data?, String)] {
            let server = ScriptedTransport(exporter: exporter)
            server.respond = { xml, t in
                if xml.hasPrefix("<stream:stream") {
                    t.inject(Script.header)
                    t.inject(Script.features(Script.mechanisms("SCRAM-SHA-1")))
                } else if xml.hasPrefix("<auth") {
                    t.inject("<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><not-authorized/></failure>")
                }
            }
            _ = try? await negotiator(transports: [server]).establish()
            let auth = try #require(server.sent.first { $0.hasPrefix("<auth") })
            let initial = String(decoding: Data(base64Encoded: Script.text(of: "auth", in: auth)!)!, as: UTF8.self)
            #expect(initial.hasPrefix(flag))
        }
    }
}

/// XEP-0198 resumption in place of binding.
@Suite struct ResumptionNegotiationTests {

    private func smServer(resumeAnswer: String?) -> ScriptedTransport {
        plainServer(extraFeatures: resumeAnswer == nil ? "" : "<sm xmlns='urn:xmpp:sm:3'/>") { xml, t in
            if xml.hasPrefix("<resume "), let resumeAnswer { t.inject(resumeAnswer) }
        }
    }

    private func request() throws -> ResumptionRequest {
        ResumptionRequest(id: "sm1", jid: try JID("juliet@example.com/old"), handled: 7)
    }

    @Test func resumesInsteadOfBinding() async throws {
        let server = smServer(resumeAnswer: "<resumed xmlns='urn:xmpp:sm:3' previd='sm1' h='4'/>")
        let phases = PhaseLog()
        let session = try await negotiator(transports: [server])
            .establish(resuming: try request()) { phases.append($0) }
        #expect(session.resumption == .resumed(handled: 4))
        #expect(session.jid == (try JID("juliet@example.com/old")))
        #expect(server.sent.contains("<resume xmlns='urn:xmpp:sm:3' h='7' previd='sm1'/>"))
        #expect(!server.sent.contains { $0.contains("xmpp-bind") })
        #expect(phases.all.contains(.resuming) && !phases.all.contains(.binding))
        await session.stream.close()
    }

    @Test func bindsWhenResumptionFails() async throws {
        let server = smServer(resumeAnswer: """
        <failed xmlns='urn:xmpp:sm:3' h='3'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></failed>
        """)
        let session = try await negotiator(transports: [server]).establish(resuming: try request())
        #expect(session.resumption == .failed(handled: 3))
        #expect(session.jid == (try JID("juliet@example.com/abc")))
        await session.stream.close()
    }

    @Test func bindsWhenTheServerNoLongerOffersIt() async throws {
        let server = smServer(resumeAnswer: nil)
        let session = try await negotiator(transports: [server]).establish(resuming: try request())
        #expect(session.resumption == .failed(handled: nil))
        #expect(!server.sent.contains { $0.hasPrefix("<resume") })
        await session.stream.close()
    }

    @Test func refusesAMismatchedResumption() async throws {
        let server = smServer(resumeAnswer: "<resumed xmlns='urn:xmpp:sm:3' previd='other' h='4'/>")
        await #expect(throws: SessionError.unexpectedElement("resumed")) {
            try await negotiator(transports: [server]).establish(resuming: try request())
        }
    }

    @Test func triesTheResumptionLocationFirst() async throws {
        let preferred = Endpoint(host: "node2.example.com", port: 5333, security: .directTLS, domain: "example.com")
        let configuration = SessionConfiguration(
            credentials: try Credentials(jid: try JID("juliet@example.com"), password: "secret"),
            tlsPolicy: .insecureAcceptAll, endpoints: [endpoint], negotiationTimeout: .seconds(2))
        let tried = EndpointLog()
        let negotiator = SessionNegotiator(configuration: configuration) { endpoint, configuration in
            tried.append(endpoint)
            return XMLStream(endpoint: endpoint, domain: configuration.credentials.jid.domain,
                             policy: configuration.tlsPolicy, transport: plainServer(),
                             negotiationTimeout: configuration.negotiationTimeout)
        }
        var request = try request()
        request.endpoint = preferred
        let session = try await negotiator.establish(resuming: request)
        #expect(tried.all == [preferred])
        await session.stream.close()
    }
}

private final class EndpointLog: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: [Endpoint] = []
    func append(_ endpoint: Endpoint) { lock.withLock { endpoints.append(endpoint) } }
    var all: [Endpoint] { lock.withLock { endpoints } }
}

private final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [SessionNegotiator.Phase] = []
    func append(_ phase: SessionNegotiator.Phase) { lock.withLock { phases.append(phase) } }
    var all: [SessionNegotiator.Phase] { lock.withLock { phases } }
}

/// XEP-0388 SASL2 + XEP-0386 Bind 2 + XEP-0484 FAST against a scripted server.
@Suite struct SASL2Tests {

    final class Tokens: FASTTokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private var token: FASTToken?
        init(_ token: FASTToken? = nil) { self.token = token }
        func load() -> FASTToken? { lock.withLock { token } }
        func save(_ token: FASTToken?) { lock.withLock { self.token = token } }
    }

    static let agent = UserAgent(id: UUID(), software: "Hrafn", device: "Tests")

    /// Offers SASL2 (PLAIN, FAST NONE) with Bind 2 and CSI inline. Answers a
    /// password or a token it issued; hands out `issue` when asked.
    private func sasl2Server(token issued: String = "tok-1", rejectToken: Bool = false) -> ScriptedTransport {
        let transport = ScriptedTransport()
        transport.respond = { xml, t in
            if xml.hasPrefix("<stream:stream") {
                t.inject(Script.header)
                t.inject(Script.features("""
                <authentication xmlns='urn:xmpp:sasl:2'><mechanism>PLAIN</mechanism><inline>\
                <bind xmlns='urn:xmpp:bind:0'><inline><feature var='urn:xmpp:sm:3'/><feature var='urn:xmpp:csi:0'/></inline></bind>\
                <sm xmlns='urn:xmpp:sm:3'/><fast xmlns='urn:xmpp:fast:0'><mechanism>HT-SHA-256-NONE</mechanism></fast>\
                </inline></authentication>
                """ + Script.mechanisms("PLAIN")))
            } else if xml.hasPrefix("<authenticate") {
                let response = Data(base64Encoded: Script.text(of: "initial-response", in: xml) ?? "") ?? Data()
                var serverFinal = ""
                if xml.hasPrefix("<authenticate xmlns='urn:xmpp:sasl:2' mechanism='HT-SHA-256-NONE'") {
                    let key = SymmetricKey(data: Data("tok-1".utf8))
                    let expected = Data("juliet".utf8) + Data([0])
                        + Data(HMAC<SHA256>.authenticationCode(for: Data("Initiator".utf8), using: key))
                    guard !rejectToken, response == expected else {
                        t.inject("<failure xmlns='urn:xmpp:sasl:2'><credentials-expired xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/></failure>")
                        return
                    }
                    let proof = Data(HMAC<SHA256>.authenticationCode(for: Data("Responder".utf8), using: key))
                    serverFinal = "<additional-data>\(proof.base64EncodedString())</additional-data>"
                } else if response != Data("\0juliet\0secret".utf8) {
                    t.inject("<failure xmlns='urn:xmpp:sasl:2'><not-authorized xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/></failure>")
                    return
                }
                let token = xml.contains("<request-token") ? "<token xmlns='urn:xmpp:fast:0' token='\(issued)' expiry='2099-01-01T00:00:00Z'/>" : ""
                let enabled = xml.contains("<enable xmlns='urn:xmpp:sm:3'") ? "<enabled xmlns='urn:xmpp:sm:3' id='sm-1' resume='true'/>" : ""
                t.inject("""
                <success xmlns='urn:xmpp:sasl:2'>\(serverFinal)\
                <authorization-identifier>juliet@example.com/Hrafn.x1</authorization-identifier>\
                <bound xmlns='urn:xmpp:bind:0'>\(enabled)</bound>\(token)</success>
                """)
            } else if xml == "</stream:stream>" {
                t.inject("</stream:stream>")
            }
        }
        return transport
    }

    private func negotiator(tokens: Tokens?, transports: [ScriptedTransport]) throws -> SessionNegotiator {
        var configuration = SessionConfiguration(
            credentials: try Credentials(jid: try JID("juliet@example.com"), password: "secret"),
            tlsPolicy: .insecureAcceptAll, endpoints: transports.map { _ in endpoint },
            negotiationTimeout: .seconds(2))
        configuration.userAgent = Self.agent
        configuration.fastTokens = tokens
        let queue = TransportQueue(transports)
        return SessionNegotiator(configuration: configuration) { endpoint, configuration in
            XMLStream(endpoint: endpoint, domain: configuration.credentials.jid.domain,
                      policy: configuration.tlsPolicy, transport: queue.next(),
                      negotiationTimeout: configuration.negotiationTimeout)
        }
    }

    /// Password, Bind 2 with XEP-0198 inside, a token for next time; no
    /// restart and no bind IQ.
    @Test func bindsAndEnablesInOneExchange() async throws {
        let tokens = Tokens()
        let server = sasl2Server()
        let session = try await negotiator(tokens: tokens, transports: [server]).establish(streamManagement: true)
        #expect(session.jid == (try JID("juliet@example.com/Hrafn.x1")))
        #expect(session.mechanism == "PLAIN")
        #expect(session.usedSASL2)
        #expect(session.streamManagementEnabled?["id"] == "sm-1")
        #expect(session.features.firstChild(name: "csi", namespaceURI: Namespaces.csi) != nil)
        #expect(server.sent.filter { $0.hasPrefix("<stream:stream") }.count == 1, "no restart")
        #expect(!server.sent.contains { $0.contains("xmpp-bind") }, "no bind IQ")
        let sent = try #require(server.sent.first { $0.hasPrefix("<authenticate") })
        #expect(sent.contains("<user-agent id='\(Self.agent.id.uuidString.lowercased())'>"))
        #expect(sent.contains("<request-token xmlns='urn:xmpp:fast:0' mechanism='HT-SHA-256-NONE'/>"))
        #expect(sent.contains("<tag>Hrafn</tag>"))
        #expect(tokens.load() == FASTToken(mechanism: "HT-SHA-256-NONE", secret: "tok-1",
                                           expiry: SASL2Authenticator.parseDate("2099-01-01T00:00:00Z")))
        await session.stream.close()
    }

    /// The token logs in, counts its uses, and is rotated.
    @Test func logsInWithTheToken() async throws {
        let tokens = Tokens(FASTToken(mechanism: "HT-SHA-256-NONE", secret: "tok-1", expiry: nil, count: 4))
        let server = sasl2Server(token: "tok-2")
        let session = try await negotiator(tokens: tokens, transports: [server]).establish()
        #expect(session.mechanism == "HT-SHA-256-NONE")
        #expect(server.sent.contains { $0.contains("<fast xmlns='urn:xmpp:fast:0' count='5'/>") })
        #expect(tokens.load()?.secret == "tok-2")
        await session.stream.close()
    }

    /// A refused token is forgotten, and a new connection uses the password.
    @Test func fallsBackToThePasswordOnANewConnection() async throws {
        let tokens = Tokens(FASTToken(mechanism: "HT-SHA-256-NONE", secret: "tok-1", expiry: nil))
        let session = try await negotiator(tokens: tokens,
                                           transports: [sasl2Server(rejectToken: true), sasl2Server(token: "tok-3")])
            .establish()
        #expect(session.mechanism == "PLAIN")
        #expect(tokens.load()?.secret == "tok-3")
        await session.stream.close()
    }

    /// Resuming goes the long way (restart, `<resume/>`), never inline.
    @Test func resumptionUsesLegacySASL() async throws {
        let server = plainServer()
        let session = try await negotiator(tokens: nil, transports: [server])
            .establish(resuming: ResumptionRequest(id: "old", jid: try JID("juliet@example.com/abc"), handled: 3))
        #expect(!session.usedSASL2)
        await session.stream.close()
    }

    /// HT's proof both ways, and a server that cannot prove it knows the token.
    @Test func hashedTokenMechanism() throws {
        let exporter = Data(repeating: 7, count: 32)
        var mechanism = HTMechanism(username: "juliet", token: "t0k", binding: .tlsExporter(exporter))
        #expect(mechanism.name == "HT-SHA-256-EXPR")
        let key = SymmetricKey(data: Data("t0k".utf8))
        let initial = try #require(try mechanism.start())
        #expect(initial == Data("juliet".utf8) + Data([0])
                + Data(HMAC<SHA256>.authenticationCode(for: Data("Initiator".utf8) + exporter, using: key)))
        let proof = Data(HMAC<SHA256>.authenticationCode(for: Data("Responder".utf8) + exporter, using: key))
        try mechanism.finish(additionalData: proof)
        #expect(throws: SASLError.serverSignatureMismatch) { try mechanism.finish(additionalData: Data([1])) }
        #expect(throws: SASLError.serverSignatureMissing) { try mechanism.finish(additionalData: nil) }
    }
}
