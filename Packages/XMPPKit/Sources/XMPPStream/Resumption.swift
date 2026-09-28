import Foundation
import XMPPCore
import XMPPTransport
import XMPPXML

extension Namespaces {
    /// XEP-0198 Stream Management.
    public static let streamManagement = "urn:xmpp:sm:3"
    /// XEP-0352 Client State Indication.
    public static let csi = "urn:xmpp:csi:0"
}

/// What the negotiator needs to resume a XEP-0198 session in place of binding.
public struct ResumptionRequest: Sendable, Equatable {
    /// `id` from the server's `<enabled/>`.
    public var id: String
    /// The full JID of the session being resumed; resumption keeps it.
    public var jid: JID
    /// Stanzas this client has handled, for `<resume h=''/>`.
    public var handled: UInt32
    /// The server's preferred reconnection address from `<enabled location=''/>`,
    /// tried before the usual endpoints.
    public var endpoint: Endpoint?

    public init(id: String, jid: JID, handled: UInt32, endpoint: Endpoint? = nil) {
        self.id = id
        self.jid = jid
        self.handled = handled
        self.endpoint = endpoint
    }

    /// Parses `<enabled location=''/>`: `host`, `host:port` or `[v6]:port`.
    /// The TLS mode and the domain certificates are checked against come from
    /// the endpoint the session was established on — `location` is only an address.
    public static func endpoint(forLocation location: String, like base: Endpoint) -> Endpoint? {
        var host = Substring(location)
        var port = base.port
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            let rest = host[host.index(after: close)...]
            host = host[host.index(after: host.startIndex)..<close]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let parsed = UInt16(rest.dropFirst()) else { return nil }
                port = parsed
            }
        } else if let colon = host.lastIndex(of: ":") {
            // More than one colon without brackets is a bare IPv6 address.
            if host.firstIndex(of: ":") == colon {
                guard let parsed = UInt16(host[host.index(after: colon)...]) else { return nil }
                port = parsed
                host = host[..<colon]
            }
        }
        guard !host.isEmpty, port != 0 else { return nil }
        return Endpoint(host: String(host), port: port, security: base.security, domain: base.domain)
    }
}

/// How the session came to be bound.
public enum Resumption: Sendable, Equatable {
    /// No resumption was asked for.
    case none
    /// XEP-0198 §5: the previous session continues. `handled` is how many of
    /// our stanzas the server had processed.
    case resumed(handled: UInt32)
    /// The server could not resume, so a fresh session was bound. `handled` is
    /// the server's count when it included one (XEP-0198 §5, `<failed h=''/>`),
    /// which says exactly which stanzas need sending again.
    case failed(handled: UInt32?)
}

/// XEP-0198 §5 resumption, sent after the post-SASL restart instead of binding.
struct SessionResumer {
    let stream: XMLStream

    static func isOffered(in features: Element) -> Bool {
        features.firstChild(name: "sm", namespaceURI: Namespaces.streamManagement) != nil
    }

    func resume(_ request: ResumptionRequest) async throws -> Resumption {
        try await stream.send(Element(name: "resume", namespaceURI: Namespaces.streamManagement,
                                      attributes: ["previd": request.id, "h": String(request.handled)]))
        let answer = try await stream.nextNegotiationElement()
        guard answer.namespaceURI == Namespaces.streamManagement else {
            throw SessionError.unexpectedElement(answer.name)
        }
        switch answer.name {
        case "resumed":
            guard answer["previd"] == nil || answer["previd"] == request.id,
                  let handled = answer["h"].flatMap(UInt32.init) else {
                throw SessionError.unexpectedElement(answer.name)
            }
            return .resumed(handled: handled)
        case "failed":
            return .failed(handled: answer["h"].flatMap(UInt32.init))
        default:
            throw SessionError.unexpectedElement(answer.name)
        }
    }
}
