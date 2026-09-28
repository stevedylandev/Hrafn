import Foundation
import XMPPXML

/// The three stanza kinds of RFC 6120 §8, as thin typed views over an `Element`.
///
/// Each wrapper keeps the element it was built from, so extension payloads the
/// wrapper knows nothing about survive a round trip untouched.
public protocol Stanza: Sendable, Hashable {
    var element: Element { get set }
    init?(_ element: Element)
}

public extension Stanza {
    var id: String? {
        get { element["id"] }
        set { element["id"] = newValue }
    }

    /// `nil` both when absent and when unparseable: an invalid address is
    /// treated like a missing one, never trusted.
    var to: JID? {
        get { element["to"].flatMap { try? JID($0) } }
        set { element["to"] = newValue?.description }
    }

    var from: JID? {
        get { element["from"].flatMap { try? JID($0) } }
        set { element["from"] = newValue?.description }
    }

    /// The `<error/>` child of a `type='error'` stanza.
    var error: StanzaError? {
        guard element["type"] == "error",
              let error = element.firstChild(name: "error", namespaceURI: Namespaces.client)
        else { return nil }
        return StanzaError(element: error)
    }
}

public enum StanzaID {
    /// Unique, unguessable ids. Guessable ids let a third party forge IQ
    /// responses; the tracker also checks `from`, but there is no reason to help.
    public static func make() -> String {
        UUID().uuidString.lowercased()
    }
}

// MARK: - IQ

/// Info/Query (RFC 6120 §8.2.3): exactly one payload on get/set, a reply for each.
public struct IQ: Stanza {
    public enum Kind: String, Sendable, Hashable {
        case get, set, result, error

        public var isRequest: Bool { self == .get || self == .set }
    }

    public var element: Element

    /// Requires `type` and `id`, which every IQ must carry (§8.2.3).
    public init?(_ element: Element) {
        guard element.matches(name: "iq", namespaceURI: Namespaces.client),
              element["type"].flatMap(Kind.init(rawValue:)) != nil,
              element["id"] != nil
        else { return nil }
        self.element = element
    }

    public init(type: Kind, id: String = StanzaID.make(), to: JID? = nil, payload: Element? = nil) {
        var element = Element(name: "iq", namespaceURI: Namespaces.client,
                              attributes: ["type": type.rawValue, "id": id])
        if let to { element["to"] = to.description }
        if let payload { element.addChild(payload) }
        self.element = element
    }

    public var type: Kind {
        element["type"].flatMap(Kind.init(rawValue:)) ?? .error
    }

    /// Non-optional: `init?(_:)` refuses IQs without one.
    public var requestID: String { element["id"] ?? "" }

    /// The request's (or result's) child element; never the `<error/>`.
    public var payload: Element? {
        element.elements.first { !$0.matches(name: "error", namespaceURI: Namespaces.client) }
    }

    /// A `result` addressed back to the requester.
    public func makeResult(payload: Element? = nil) -> IQ {
        var reply = IQ(type: .result, id: requestID, payload: payload)
        reply.element["to"] = element["from"]
        return reply
    }

    /// An `error` addressed back to the requester. The request payload is not
    /// echoed: RFC 6120 §8.3.1 makes that optional, and not echoing keeps a
    /// large request from being reflected.
    public func makeError(_ error: StanzaError) -> IQ {
        var reply = IQ(type: .error, id: requestID)
        reply.element["to"] = element["from"]
        reply.element.addChild(error.element)
        return reply
    }
}

// MARK: - Message

public struct Message: Stanza {
    public enum Kind: String, Sendable, Hashable {
        case chat, error, groupchat, headline, normal
    }

    public var element: Element

    public init?(_ element: Element) {
        guard element.matches(name: "message", namespaceURI: Namespaces.client) else { return nil }
        self.element = element
    }

    public init(type: Kind = .chat, id: String? = StanzaID.make(), to: JID? = nil, body: String? = nil) {
        var element = Element(name: "message", namespaceURI: Namespaces.client,
                              attributes: ["type": type.rawValue])
        if let id { element["id"] = id }
        if let to { element["to"] = to.description }
        if let body { element.addChild(Element(name: "body", namespaceURI: Namespaces.client, text: body)) }
        self.element = element
    }

    /// RFC 6121 §5.2.2: a missing or unknown type is `normal`.
    public var type: Kind {
        element["type"].flatMap(Kind.init(rawValue:)) ?? .normal
    }

    public var body: String? {
        element.firstChild(name: "body", namespaceURI: Namespaces.client)?.text
    }
}

// MARK: - Presence

public struct Presence: Stanza {
    /// RFC 6121 §4.7.1. Available presence has no `type`, modelled as `.available`.
    public enum Kind: String, Sendable, Hashable {
        case available
        case unavailable, subscribe, subscribed, unsubscribe, unsubscribed, probe, error
    }

    public var element: Element

    public init?(_ element: Element) {
        guard element.matches(name: "presence", namespaceURI: Namespaces.client) else { return nil }
        self.element = element
    }

    public init(type: Kind = .available, to: JID? = nil) {
        var element = Element(name: "presence", namespaceURI: Namespaces.client)
        if type != .available { element["type"] = type.rawValue }
        if let to { element["to"] = to.description }
        self.element = element
    }

    /// An unknown `type` is treated as `error` rather than as available: a
    /// server sending something we cannot read has not told us anyone is online.
    public var type: Kind {
        guard let raw = element["type"] else { return .available }
        guard let kind = Kind(rawValue: raw), kind != .available else { return .error }
        return kind
    }
}
