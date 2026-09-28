import Foundation
import CryptoKit
import XMPPTransport

/// Live tests against the Docker servers in `docker/` are off by default — CI
/// runners have no servers. Run them with:
///
/// ```sh
/// docker compose -f docker/docker-compose.yml up -d
/// HRAFN_INTEGRATION=1 swift test --package-path Packages/XMPPKit
/// ```
public let integrationEnabled = ProcessInfo.processInfo.environment["HRAFN_INTEGRATION"] == "1"

/// Accounts created by `scripts/dev-accounts.sh`.
public let devPassword = ProcessInfo.processInfo.environment["HRAFN_DEV_PASSWORD"] ?? "devpassword"

public struct TestServer: Sendable {
    public let domain: String
    public let host = "127.0.0.1"
    public let startTLSPort: UInt16
    public let directTLSPort: UInt16
    /// The strongest SASL mechanism this server is configured to offer. Prosody
    /// 13 implements SCRAM-SHA-1 only, so ejabberd is what proves SCRAM-SHA-256
    /// works end to end.
    public let strongestMechanism: String
    /// XEP-0114 component port, for the push app server's stand-in.
    public let componentPort: UInt16
    /// The component domain the server routes to that port.
    public var pushDomain: String { "push.\(domain)" }
    /// Path to the PEM the server presents, relative to the repository root.
    public var certificatePath: String { "docker/certs/\(domain).crt" }

    public static let prosody = TestServer(domain: "alpha.test", startTLSPort: 5222,
                                           directTLSPort: 5223, strongestMechanism: "SCRAM-SHA-1",
                                           componentPort: 5347)
    public static let ejabberd = TestServer(domain: "beta.test", startTLSPort: 15222,
                                            directTLSPort: 15223, strongestMechanism: "SCRAM-SHA-256",
                                            componentPort: 15347)

    public func endpoint(_ security: TransportSecurity, domain: String? = nil) -> Endpoint {
        Endpoint(host: host, port: security == .directTLS ? directTLSPort : startTLSPort,
                 security: security, domain: domain ?? self.domain)
    }

    /// Trusts exactly the certificate the test server presents, by fingerprint.
    ///
    /// Exercises the real `TLSPolicy.standard` path — including the exception
    /// store the pinning UI will use — rather than disabling validation.
    public func trustPolicy() throws -> TLSPolicy {
        let store = InMemoryTrustExceptionStore()
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // XMPPTestSupport
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // XMPPKit
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repository root
        let pem = try String(contentsOf: root.appending(path: certificatePath), encoding: .utf8)
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: base64) else { throw CocoaError(.fileReadCorruptFile) }
        store.addException(domain: domain, fingerprint: Data(SHA256.hash(data: der)))
        return .standard(exceptions: store)
    }
}
