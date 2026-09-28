import Foundation
import XMPPCore

/// RFC 5122 `xmpp:` URI, as found in links and QR codes: an address and an
/// optional XEP-0147 query action.
///
/// Only the forms a client acts on are modelled: `xmpp:jid`,
/// `xmpp:jid?message[;body=…]`, `xmpp:jid?roster[;name=…]`, `xmpp:jid?subscribe`
/// and `xmpp:room?join`. Unknown actions keep the address and drop the action.
/// URIs with an authority component (`xmpp://account@host/…`) are refused.
public struct XMPPURI: Sendable, Hashable, CustomStringConvertible {

    public enum Action: Sendable, Hashable {
        case message(body: String?)
        case roster(name: String?)
        case subscribe
        case join
    }

    public var jid: JID
    public var action: Action?
    /// OMEMO fingerprints by device id, as other clients put in QR codes to
    /// verify devices: `omemo-sid-<device id>=<hex fingerprint>` pairs (any
    /// position in the query, with or without an action). Lowercase hex of
    /// the 32-byte identity key.
    public var omemoFingerprints: [UInt32: String]

    public init(jid: JID, action: Action? = nil, omemoFingerprints: [UInt32: String] = [:]) {
        self.jid = jid
        self.action = action
        self.omemoFingerprints = omemoFingerprints
    }

    public init?(_ string: String) {
        guard let colon = string.firstIndex(of: ":"),
              string[..<colon].lowercased() == "xmpp" else { return nil }
        var rest = string[string.index(after: colon)...]
        guard !rest.hasPrefix("//") else { return nil }
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }

        let path: Substring
        let query: Substring?
        if let mark = rest.firstIndex(of: "?") {
            path = rest[..<mark]
            query = rest[rest.index(after: mark)...]
        } else {
            path = rest
            query = nil
        }
        guard let decoded = String(path).removingPercentEncoding,
              let jid = try? JID(decoded) else { return nil }
        self.jid = jid
        omemoFingerprints = [:]

        guard let query else { return }
        var pairs = query.split(separator: ";", omittingEmptySubsequences: true)
        guard !pairs.isEmpty else { return }
        let type = pairs[0].contains("=") ? "" : pairs.removeFirst().lowercased()
        var parameters: [String: String] = [:]
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let value = String(parts[1]).removingPercentEncoding else { continue }
            let key = String(parts[0]).lowercased()
            if key.hasPrefix("omemo-sid-"), let id = UInt32(key.dropFirst("omemo-sid-".count)),
               let fingerprint = Self.fingerprint(value) {
                omemoFingerprints[id] = fingerprint
            } else {
                parameters[key] = value
            }
        }
        switch type {
        case "message": action = .message(body: parameters["body"])
        case "roster": action = .roster(name: parameters["name"])
        case "subscribe": action = .subscribe
        case "join": action = .join
        default: action = nil
        }
    }

    public var description: String {
        var string = "xmpp:" + Self.encode(jid.description, allowed: Self.pathAllowed)
        switch action {
        case nil: break
        case .message(let body):
            string += "?message"
            if let body { string += ";body=" + Self.encode(body, allowed: Self.valueAllowed) }
        case .roster(let name):
            string += "?roster"
            if let name { string += ";name=" + Self.encode(name, allowed: Self.valueAllowed) }
        case .subscribe: string += "?subscribe"
        case .join: string += "?join"
        }
        for (id, fingerprint) in omemoFingerprints.sorted(by: { $0.key < $1.key }) {
            string += (string.contains("?") ? ";" : "?") + "omemo-sid-\(id)=\(fingerprint)"
        }
        return string
    }

    /// 64 hex digits, or 66 with the key's `05` type byte in front (dropped).
    private static func fingerprint(_ value: String) -> String? {
        var hex = value.lowercased().filter { !$0.isWhitespace }
        if hex.count == 66, hex.hasPrefix("05") { hex.removeFirst(2) }
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    /// RFC 5122 §2.2: unreserved, sub-delims except those the query uses, and
    /// `@`, `/` and `:` inside the path.
    private static let pathAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'()*+,=@/:")
    private static let valueAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$'()*+,:@/")

    private static func encode(_ string: String, allowed: CharacterSet) -> String {
        string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
