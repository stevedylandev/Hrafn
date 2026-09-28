import Foundation
import Security
import Testing
@testable import XMPPTransport
import XMPPTestSupport

@Suite struct CertificateIdentityTests {

    @Test func readsSRVIDs() {
        let identity = CertificateIdentity(der: CertificateFixtures.srv)
        #expect(identity.srvNames == ["_xmpp-client.example.org"])
        #expect(identity.xmppAddrs.isEmpty)
    }

    @Test func readsXMPPAddrs() {
        #expect(CertificateIdentity(der: CertificateFixtures.xmppaddr).xmppAddrs == ["example.org"])
        #expect(CertificateIdentity(der: CertificateFixtures.idn).xmppAddrs == ["café.example"])
    }

    @Test func certificatesWithoutThemHaveNone() {
        #expect(CertificateIdentity(der: CertificateFixtures.none) == CertificateIdentity())
        #expect(CertificateIdentity(der: CertificateFixtures.ca) == CertificateIdentity())
    }

    @Test func matchesOnlyTheClientServiceOfTheDomain() {
        let srv = CertificateIdentity(srvNames: ["_XMPP-Client.Example.ORG", "_xmpp-server.other.org"])
        #expect(srv.matches(domain: "example.org"))
        #expect(!srv.matches(domain: "other.org"))           // server-to-server only
        #expect(!srv.matches(domain: "sub.example.org"))
        #expect(CertificateIdentity(srvNames: ["_xmpps-client.example.org"]).matches(domain: "example.org"))
        #expect(!CertificateIdentity(srvNames: ["_xmpp-client.*.org"]).matches(domain: "example.org"))
    }

    @Test func xmppAddrsAreComparedAsALabels() {
        let identity = CertificateIdentity(der: CertificateFixtures.idn)
        #expect(identity.matches(domain: "xn--caf-dma.example",
                                 xmppAddrToALabel: { CertificateChallenge.aLabel($0) }))
        #expect(!identity.matches(domain: "cafe.example",
                                  xmppAddrToALabel: { CertificateChallenge.aLabel($0) }))
    }

    // MARK: - Policy

    /// Evaluates `leaf` for `domain` against the fixture CA, at a date inside
    /// the fixtures' validity.
    private func trusted(_ leaf: Data, domain: String) throws -> Bool {
        let certificate = try #require(SecCertificateCreateWithData(nil, leaf as CFData))
        let ca = try #require(SecCertificateCreateWithData(nil, CertificateFixtures.ca as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let secTrust = try #require(trust)
        SecTrustSetAnchorCertificates(secTrust, [ca] as CFArray)
        SecTrustSetAnchorCertificatesOnly(secTrust, true)
        SecTrustSetVerifyDate(secTrust, Date(timeIntervalSince1970: 1_800_000_000) as CFDate)   // 2027-01
        return TLSPolicy.isTrusted(CertificateChallenge(domain: domain, host: "host.provider.net", trust: secTrust))
    }

    @Test func acceptsATrustedChainNamingTheDomainAnyWay() throws {
        #expect(try trusted(CertificateFixtures.dns, domain: "example.org"))
        #expect(try trusted(CertificateFixtures.srv, domain: "example.org"))
        #expect(try trusted(CertificateFixtures.xmppaddr, domain: "example.org"))
        #expect(try trusted(CertificateFixtures.idn, domain: "café.example"))
    }

    @Test func refusesACertificateForTheHostOnly() throws {
        // The SRV target is not the identity (RFC 6120 §13.7.2.1).
        #expect(try !trusted(CertificateFixtures.none, domain: "example.org"))
        #expect(try !trusted(CertificateFixtures.srv, domain: "other.org"))
        #expect(try !trusted(CertificateFixtures.xmppaddr, domain: "sub.example.org"))
    }

    @Test func refusesAnUntrustedChainWhateverItNames() throws {
        let certificate = try #require(SecCertificateCreateWithData(nil, CertificateFixtures.srv as CFData))
        var trust: SecTrust?
        _ = SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust)
        let secTrust = try #require(trust)
        SecTrustSetVerifyDate(secTrust, Date(timeIntervalSince1970: 1_800_000_000) as CFDate)
        #expect(!TLSPolicy.isTrusted(CertificateChallenge(domain: "example.org", host: "h", trust: secTrust)))
    }

    // MARK: - Hostile input

    @Test func truncatedAndMutatedCertificatesNeverTrap() {
        var generator = Fuzz.generator()
        let fixtures = [CertificateFixtures.srv, CertificateFixtures.xmppaddr, CertificateFixtures.idn]
        for iteration in 0..<Fuzz.iterations(3000) {
            var bytes = Array(fixtures[iteration % fixtures.count])
            switch iteration % 3 {
            case 0:
                bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &generator)))
            case 1:
                for _ in 0..<(1 + iteration % 7) {
                    bytes[Int.random(in: 0..<bytes.count, using: &generator)] = .random(in: 0...255, using: &generator)
                }
            default:
                bytes = (0..<Int.random(in: 0..<256, using: &generator)).map { _ in .random(in: 0...255, using: &generator) }
            }
            _ = CertificateIdentity(der: Data(bytes))
        }
    }

    @Test func lengthsThatOverrunAreRefused() {
        var reader = DERReader([0x30, 0x84, 0x7F, 0xFF, 0xFF, 0xFF, 0x00][...])
        #expect(throws: DERReader.Failure.self) { try reader.next() }
        var indefinite = DERReader([0x30, 0x80, 0x00, 0x00][...])
        #expect(throws: DERReader.Failure.self) { try indefinite.next() }
        var highTag = DERReader([0x1F, 0x81, 0x01, 0x00][...])
        #expect(throws: DERReader.Failure.self) { try highTag.next() }
    }
}
