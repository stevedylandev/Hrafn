import Foundation
import Security
import CryptoKit
import XMPPCore

/// A server certificate chain awaiting a decision.
public struct CertificateChallenge: @unchecked Sendable {
    /// The XMPP domain the user typed — the identity that must be proven.
    public let domain: String
    /// The host actually dialled (an SRV target, usually).
    public let host: String
    public let trust: SecTrust

    public init(domain: String, host: String, trust: SecTrust) {
        self.domain = domain
        self.host = host
        self.trust = trust
    }

    /// `domain` as an A-label, the form certificates and SNI carry.
    public var serverName: String { Self.aLabel(domain) }

    static func aLabel(_ domain: String) -> String {
        ((try? Punycode.encode(domain: domain)) ?? domain).lowercased()
    }

    /// The leaf's SRV-IDs and xmppAddrs.
    public var identity: CertificateIdentity {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return CertificateIdentity() }
        return CertificateIdentity(der: SecCertificateCopyData(leaf) as Data)
    }

    /// SHA-256 of the leaf certificate's DER encoding, the fingerprint users see
    /// and pin.
    public var leafFingerprint: Data? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return Data(SHA256.hash(data: der))
    }

    public var leafFingerprintDescription: String {
        (leafFingerprint ?? Data()).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

/// User-approved exceptions for certificates the system rejects — typically a
/// self-signed cert on a small server. Persisted per account by the app layer.
public protocol TrustExceptionStore: Sendable {
    func hasException(domain: String, fingerprint: Data) -> Bool
}

public final class InMemoryTrustExceptionStore: TrustExceptionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var exceptions: [String: Set<Data>] = [:]

    public init() {}

    public func hasException(domain: String, fingerprint: Data) -> Bool {
        lock.withLock { exceptions[domain]?.contains(fingerprint) ?? false }
    }

    public func addException(domain: String, fingerprint: Data) {
        lock.withLock { _ = exceptions[domain, default: []].insert(fingerprint) }
    }
}

/// TLS requirements for a connection (RFC 7590, RFC 9525).
public struct TLSPolicy: Sendable {
    /// RFC 7590 §3.3: TLS 1.2 is the floor.
    public var minimumVersion: tls_protocol_version_t
    /// XEP-0368 requires ALPN `xmpp-client` for Direct TLS.
    public var applicationProtocols: [String]
    /// Returns true to accept the chain. Runs off the main thread.
    public var evaluate: @Sendable (CertificateChallenge) -> Bool

    public init(
        minimumVersion: tls_protocol_version_t = .TLSv12,
        applicationProtocols: [String] = ["xmpp-client"],
        evaluate: @escaping @Sendable (CertificateChallenge) -> Bool
    ) {
        self.minimumVersion = minimumVersion
        self.applicationProtocols = applicationProtocols
        self.evaluate = evaluate
    }

    /// System trust plus RFC 9525 identity validation against the XMPP domain,
    /// falling back to a user-approved fingerprint.
    ///
    /// The identity checked is the domainpart of the account's JID, not the host
    /// from DNS: SRV answers are unauthenticated (RFC 6120 §13.7.2.1). A DNS-ID
    /// is checked by the Security framework; when none matches, a chain the
    /// system trusts is still accepted if its leaf names the domain in an
    /// SRV-ID or `id-on-xmppAddr` (RFC 6120 §13.7.1.2).
    public static func standard(exceptions: (any TrustExceptionStore)? = nil) -> TLSPolicy {
        TLSPolicy { challenge in
            if isTrusted(challenge) { return true }
            guard let exceptions, let fingerprint = challenge.leafFingerprint else { return false }
            return exceptions.hasException(domain: challenge.domain, fingerprint: fingerprint)
        }
    }

    /// The system-trust part of `standard`, without exceptions.
    public static func isTrusted(_ challenge: CertificateChallenge) -> Bool {
        let name = challenge.serverName
        let dnsPolicy = SecPolicyCreateSSL(true, name as CFString)
        guard SecTrustSetPolicies(challenge.trust, dnsPolicy) == errSecSuccess else { return false }
        if SecTrustEvaluateWithError(challenge.trust, nil) { return true }

        let identity = challenge.identity
        guard identity.matches(domain: name, xmppAddrToALabel: { CertificateChallenge.aLabel($0) }) else {
            return false
        }
        // The name is ours to check; the chain, dates and key usage are still
        // the system's. A server policy without a hostname skips only the name.
        let chainPolicy = SecPolicyCreateSSL(true, nil)
        guard SecTrustSetPolicies(challenge.trust, chainPolicy) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(challenge.trust, nil)
    }

    /// Accepts any chain. Debug builds and integration tests against the local
    /// Docker servers only — never ship a client configured with this.
    public static let insecureAcceptAll = TLSPolicy { _ in true }
}
