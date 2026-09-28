import Foundation
import XMPPCore

/// How TLS is established on a connection attempt.
public enum TransportSecurity: Sendable, Hashable {
    /// XEP-0368: TLS from the first byte, ALPN `xmpp-client`.
    case directTLS
    /// RFC 6120 §5: plaintext stream, upgraded by `<starttls/>`.
    case startTLS
}

/// One candidate connection, in the order the resolver wants it tried.
public struct Endpoint: Sendable, Hashable {
    /// Host to connect to — the SRV target, or the domain itself on fallback.
    public let host: String
    public let port: UInt16
    public let security: TransportSecurity
    /// The XMPP domain. Certificates are validated against this, never against
    /// `host`: the SRV target is unauthenticated data (RFC 6120 §13.7.2.1).
    public let domain: String

    public init(host: String, port: UInt16, security: TransportSecurity, domain: String) {
        self.host = host
        self.port = port
        self.security = security
        self.domain = domain
    }

    public var description: String { "\(host):\(port) (\(security))" }
}

/// Turns a domain into an ordered list of connection candidates.
///
/// Lookup order follows XEP-0368 §3: prefer the Direct TLS service, then the
/// STARTTLS service, then the RFC 6120 fallback of the domain itself on 5222.
public struct EndpointResolver: Sendable {
    public typealias Lookup = @Sendable (String) async throws -> [SRVRecord]

    private let lookup: Lookup

    public init(lookup: Lookup? = nil) {
        self.lookup = lookup ?? { try await SRVResolver.query($0) }
    }

    public func endpoints(for domain: JID) async throws -> [Endpoint] {
        try await endpoints(forDomain: domain.domainForDNS, presentedAs: domain.domainpart)
    }

    public func endpoints(forDomain dnsName: String, presentedAs xmppDomain: String? = nil) async throws -> [Endpoint] {
        let domain = xmppDomain ?? dnsName

        // An IP literal or a bracketed address is never an SRV name.
        if dnsName.hasPrefix("[") || isIPv4Literal(dnsName) {
            return fallbackEndpoints(host: dnsName, domain: domain)
        }

        async let direct = records("_xmpps-client._tcp.\(dnsName)")
        async let starttls = records("_xmpp-client._tcp.\(dnsName)")
        let directRecords = await direct
        let startTLSRecords = await starttls

        // "." in either service means the domain says so explicitly.
        let refusesAll = !directRecords.isEmpty && !startTLSRecords.isEmpty
            && directRecords.allSatisfy(\.isServiceDecidedlyUnavailable)
            && startTLSRecords.allSatisfy(\.isServiceDecidedlyUnavailable)
        if refusesAll { return [] }

        var endpoints: [Endpoint] = []
        endpoints += SRVResolver.ordered(directRecords.filter { !$0.isServiceDecidedlyUnavailable })
            .map { Endpoint(host: $0.target, port: $0.port, security: .directTLS, domain: domain) }
        endpoints += SRVResolver.ordered(startTLSRecords.filter { !$0.isServiceDecidedlyUnavailable })
            .map { Endpoint(host: $0.target, port: $0.port, security: .startTLS, domain: domain) }

        if endpoints.isEmpty {
            return fallbackEndpoints(host: dnsName, domain: domain)
        }
        return endpoints
    }

    /// A failed or empty SRV lookup is not fatal on its own — the other service
    /// or the A/AAAA fallback may still work.
    private func records(_ name: String) async -> [SRVRecord] {
        (try? await lookup(name)) ?? []
    }

    private func fallbackEndpoints(host: String, domain: String) -> [Endpoint] {
        // RFC 6120 §3.2.2 names only 5222; port 5223 is the widely deployed
        // legacy Direct TLS port and costs nothing to try after it.
        [
            Endpoint(host: host, port: 5222, security: .startTLS, domain: domain),
            Endpoint(host: host, port: 5223, security: .directTLS, domain: domain),
        ]
    }

    private func isIPv4Literal(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
