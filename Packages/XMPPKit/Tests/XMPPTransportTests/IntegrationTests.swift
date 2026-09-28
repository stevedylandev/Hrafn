import Testing
import Foundation
@testable import XMPPTransport
import XMPPCore
import XMPPXML
import XMPPTestSupport

private func stream(_ server: TestServer, security: TransportSecurity) throws -> XMLStream {
    let endpoint = Endpoint(
        host: server.host,
        port: security == .directTLS ? server.directTLSPort : server.startTLSPort,
        security: security,
        domain: server.domain)
    return XMLStream(endpoint: endpoint,
                     domain: try JID(server.domain),
                     policy: try server.trustPolicy(),
                     console: RedactingXMLConsole(PrintXMLConsole()))
}

@Suite(.enabled(if: integrationEnabled), .serialized)
struct ServerIntegrationTests {

    /// XEP-0368: TLS from the first byte, ALPN `xmpp-client`.
    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func opensADirectTLSStream(_ server: TestServer) async throws {
        let stream = try stream(server, security: .directTLS)
        let header = try await stream.open()
        #expect(header.namespaceURI == Namespaces.stream)
        #expect(header["from"] == server.domain || header["from"] == nil)
        #expect(await stream.isEncrypted)

        let features = try await stream.awaitFeatures()
        let mechanisms = try #require(features.firstChild(name: "mechanisms", namespaceURI: Namespaces.sasl))
        let offered = mechanisms.childElements(name: "mechanism").map(\.text)
        // PLAIN alone would mean the server is misconfigured for Phase 2.
        #expect(offered.contains(server.strongestMechanism))

        // Both servers advertise XEP-0440 channel binding with tls-exporter,
        // which is what SCRAM-*-PLUS needs in v1.1 — and what the Direct TLS
        // transport can supply.
        let channelBinding = features.firstChild(name: "sasl-channel-binding",
                                                namespaceURI: "urn:xmpp:sasl-cb:0")
        #expect(channelBinding?.childElements(name: "channel-binding")
            .contains { $0["type"] == "tls-exporter" } == true)
        await stream.close()
    }

    /// RFC 6120 §5: plaintext stream, upgrade, restart.
    @Test(arguments: [TestServer.prosody, TestServer.ejabberd])
    func upgradesASTARTTLSStream(_ server: TestServer) async throws {
        let stream = try stream(server, security: .startTLS)
        try await stream.open()
        #expect(!(await stream.isEncrypted))

        let features = try await stream.awaitFeatures()
        let secured = try #require(try await stream.negotiateTLS(features: features))
        #expect(await stream.isEncrypted)
        #expect(secured.firstChild(name: "mechanisms", namespaceURI: Namespaces.sasl) != nil)
        // The pre-TLS stream must not have offered SASL; servers are configured
        // with c2s_require_encryption.
        #expect(features.firstChild(name: "mechanisms", namespaceURI: Namespaces.sasl) == nil)
        await stream.close()
    }

    /// A stream header for a domain the server does not host must be answered
    /// with `host-unknown` (RFC 6120 §4.9.3.6), not a silent drop.
    ///
    /// Asked over STARTTLS: on the Direct TLS port the server has no certificate
    /// for the SNI name and aborts the handshake, so the XMPP-level error never
    /// gets a chance to be sent.
    @Test func rejectsAnUnknownHost() async throws {
        let server = TestServer.prosody
        let endpoint = Endpoint(host: server.host, port: server.startTLSPort,
                               security: .startTLS, domain: "not-hosted.invalid")
        let stream = XMLStream(endpoint: endpoint,
                               domain: try JID("not-hosted.invalid"),
                               policy: .insecureAcceptAll)
        do {
            try await stream.open()
            _ = try await stream.awaitFeatures()
            Issue.record("expected a stream error")
            return
        } catch let failure as XMLStream.Failure {
            guard case .streamError(let condition, _) = failure else {
                Issue.record("unexpected failure: \(failure)")
                return
            }
            #expect(condition == "host-unknown")
        }
        await stream.close()
    }

    /// A Direct TLS connection for a domain the server does not host fails in the
    /// handshake, because SNI names a virtual host it has no certificate for.
    @Test func failsTheHandshakeForAnUnhostedDomainOverDirectTLS() async throws {
        let server = TestServer.prosody
        let transport = NetworkTransport(
            endpoint: Endpoint(host: server.host, port: server.directTLSPort,
                               security: .directTLS, domain: "not-hosted.invalid"),
            policy: .insecureAcceptAll)
        await #expect(throws: TransportError.self) { try await transport.connect() }
        await transport.close()
    }

    /// The certificate must be judged against the XMPP domain, so a fingerprint
    /// exception issued for another domain must not be accepted.
    @Test func refusesACertificateWithoutAMatchingException() async throws {
        let server = TestServer.prosody
        let endpoint = Endpoint(host: server.host, port: server.directTLSPort,
                               security: .directTLS, domain: server.domain)
        let stream = XMLStream(endpoint: endpoint,
                               domain: try JID(server.domain),
                               policy: .standard(exceptions: InMemoryTrustExceptionStore()))
        // A rejected certificate must surface as an error rather than an
        // indefinite wait: NWConnection retries TLS failures on its own.
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            try await stream.open()
        }
        #expect(started.duration(to: .now) < .seconds(5))
        await stream.close()
    }

    /// The exporter that SCRAM-*-PLUS will need in v1.1 is available on the
    /// Direct TLS path and absent on the STARTTLS path.
    @Test func exposesChannelBindingOnlyOverDirectTLS() async throws {
        let server = TestServer.prosody

        let direct = NetworkTransport(
            endpoint: Endpoint(host: server.host, port: server.directTLSPort,
                               security: .directTLS, domain: server.domain),
            policy: try server.trustPolicy())
        try await direct.connect()
        let exporter = await direct.channelBindingExporter()
        #expect(exporter?.count == 32)
        await direct.close()

        let upgraded = StreamTaskTransport(
            endpoint: Endpoint(host: server.host, port: server.startTLSPort,
                               security: .startTLS, domain: server.domain),
            policy: try server.trustPolicy())
        try await upgraded.connect()
        #expect(await upgraded.channelBindingExporter() == nil)
        await upgraded.close()
    }
}

extension TestServer: CustomTestStringConvertible {
    public var testDescription: String { domain }
}
