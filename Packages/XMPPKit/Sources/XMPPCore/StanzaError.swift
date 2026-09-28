import XMPPXML

/// A stanza-level error (RFC 6120 §8.3): `<error type='…'><condition/>…</error>`.
///
/// Thrown by the IQ tracker when a request is answered with `type='error'`, and
/// thrown by IQ handlers to have the router answer with that error.
public struct StanzaError: Error, Sendable, Hashable, CustomStringConvertible {

    /// RFC 6120 §8.3.2: what the recipient of the error should do about it.
    public enum ErrorType: String, Sendable, Hashable {
        case auth, cancel, `continue`, modify, wait
    }

    /// RFC 6120 §8.3.3. Unknown conditions are read as `undefined-condition`,
    /// which is what §8.3.3.21 tells a receiver to do.
    public enum Condition: String, Sendable, Hashable, CaseIterable {
        case badRequest = "bad-request"
        case conflict
        case featureNotImplemented = "feature-not-implemented"
        case forbidden
        case gone
        case internalServerError = "internal-server-error"
        case itemNotFound = "item-not-found"
        case jidMalformed = "jid-malformed"
        case notAcceptable = "not-acceptable"
        case notAllowed = "not-allowed"
        case notAuthorized = "not-authorized"
        case policyViolation = "policy-violation"
        case recipientUnavailable = "recipient-unavailable"
        case redirect
        case registrationRequired = "registration-required"
        case remoteServerNotFound = "remote-server-not-found"
        case remoteServerTimeout = "remote-server-timeout"
        case resourceConstraint = "resource-constraint"
        case serviceUnavailable = "service-unavailable"
        case subscriptionRequired = "subscription-required"
        case undefinedCondition = "undefined-condition"
        case unexpectedRequest = "unexpected-request"

        /// The type RFC 6120 §8.3.3 gives in each condition's example — the
        /// sensible default when generating an error.
        public var defaultType: ErrorType {
            switch self {
            case .badRequest, .jidMalformed, .notAcceptable, .policyViolation, .redirect:
                .modify
            case .forbidden, .notAuthorized, .registrationRequired, .subscriptionRequired:
                .auth
            case .recipientUnavailable, .remoteServerTimeout, .resourceConstraint,
                 .unexpectedRequest:
                .wait
            case .conflict, .featureNotImplemented, .gone, .internalServerError,
                 .itemNotFound, .notAllowed, .remoteServerNotFound, .serviceUnavailable,
                 .undefinedCondition:
                .cancel
            }
        }
    }

    public var type: ErrorType
    public var condition: Condition
    /// Human-readable description; for logs, never for control flow.
    public var text: String?
    /// The entity that generated the error, when the server says so.
    public var by: String?
    /// Character data of `<gone/>` and `<redirect/>`: the new address.
    public var alternateAddress: String?
    /// An application-specific condition element, if present (§8.3.4).
    public var applicationCondition: Element?

    public init(
        _ condition: Condition,
        type: ErrorType? = nil,
        text: String? = nil,
        by: String? = nil,
        alternateAddress: String? = nil,
        applicationCondition: Element? = nil
    ) {
        self.condition = condition
        self.type = type ?? condition.defaultType
        self.text = text
        self.by = by
        self.alternateAddress = alternateAddress
        self.applicationCondition = applicationCondition
    }

    /// Reads an `<error/>` element. Lenient on purpose: a malformed error from a
    /// remote server is still an error, and callers need something to throw.
    public init(element: Element) {
        let defined = element.elements.first {
            $0.namespaceURI == Namespaces.stanzas && $0.name != "text"
        }
        let condition = defined.flatMap { Condition(rawValue: $0.name) } ?? .undefinedCondition
        self.condition = condition
        self.type = element["type"].flatMap(ErrorType.init(rawValue:)) ?? condition.defaultType
        self.text = element.firstChild(name: "text", namespaceURI: Namespaces.stanzas)?.text
        self.by = element["by"]
        let address = defined?.text ?? ""
        self.alternateAddress = address.isEmpty ? nil : address
        self.applicationCondition = element.elements.first {
            $0.namespaceURI != Namespaces.stanzas && $0.namespaceURI != Namespaces.client
        }
    }

    /// The `<error/>` element, in `jabber:client` like the stanza carrying it.
    public var element: Element {
        var error = Element(name: "error", namespaceURI: Namespaces.client,
                            attributes: ["type": type.rawValue])
        if let by { error["by"] = by }
        error.addChild(Element(name: condition.rawValue, namespaceURI: Namespaces.stanzas,
                               text: alternateAddress ?? ""))
        if let text {
            error.addChild(Element(name: "text", namespaceURI: Namespaces.stanzas,
                                   attributes: ["xml:lang": "en"], text: text))
        }
        if let applicationCondition { error.addChild(applicationCondition) }
        return error
    }

    public var description: String {
        var out = "\(type.rawValue)/\(condition.rawValue)"
        if let text { out += " (\(text))" }
        return out
    }
}
