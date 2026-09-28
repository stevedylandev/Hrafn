import Foundation
import XMPPCore
import XMPPTransport
import XMPPXML

extension Namespaces {
    /// XEP-0388 Extensible SASL Profile.
    public static let sasl2 = "urn:xmpp:sasl:2"
    /// XEP-0386 Bind 2.
    public static let bind2 = "urn:xmpp:bind:0"
    /// XEP-0484 Fast Authentication Streamlining Tokens.
    public static let fast = "urn:xmpp:fast:0"
}

/// Who is logging in, for XEP-0388 `<user-agent/>`. FAST tokens belong to
/// one user agent, so `id` must stay the same for an installation.
public struct UserAgent: Sendable, Equatable {
    public var id: UUID
    public var software: String
    public var device: String?

    public init(id: UUID, software: String, device: String? = nil) {
        self.id = id
        self.software = software
        self.device = device
    }

    var element: Element {
        var agent = Element(name: "user-agent", namespaceURI: Namespaces.sasl2,
                            attributes: ["id": id.uuidString.lowercased()])
        agent.addChild(Element(name: "software", namespaceURI: Namespaces.sasl2, text: software))
        if let device { agent.addChild(Element(name: "device", namespaceURI: Namespaces.sasl2, text: device)) }
        return agent
    }
}

/// A XEP-0484 token: a credential in its own right, so it lives wherever the
/// password does (the keychain, in the app).
public struct FASTToken: Sendable, Codable, Equatable {
    public var mechanism: String
    public var secret: String
    public var expiry: Date?
    /// Incremented for every use (XEP-0484 `count`), so a replayed
    /// authentication can be told apart.
    public var count: UInt32

    public init(mechanism: String, secret: String, expiry: Date?, count: UInt32 = 0) {
        self.mechanism = mechanism
        self.secret = secret
        self.expiry = expiry
        self.count = count
    }

    public func isUsable(at date: Date = Date()) -> Bool { expiry.map { $0 > date } ?? true }
}

/// Where FAST tokens are kept between connections (and processes).
public protocol FASTTokenStore: Sendable {
    func load() -> FASTToken?
    /// `nil` forgets the token (it failed, or was revoked).
    func save(_ token: FASTToken?)
}

/// XEP-0198 inside XEP-0388: how the stream-management part of the login went.
enum InlineStreamManagement: Sendable {
    /// Not asked for, or not offered inline.
    case none
    /// Enabled inside Bind 2; the server's `<enabled/>`.
    case enabled(Element)
}

/// XEP-0388 SASL2 with XEP-0386 Bind 2: authenticates, binds and enables
/// stream management in one exchange, without a stream restart.
/// With XEP-0484, the password is used once to get a token, and the token
/// thereafter.
struct SASL2Authenticator: Authenticator {
    let credentials: Credentials
    let allowPlain: Bool
    let allowChannelBinding: Bool
    let userAgent: UserAgent?
    /// Bind 2 `<tag/>`: the client's name, which servers put into the resource.
    let bindTag: String?
    let tokens: (any FASTTokenStore)?
    /// Ask for XEP-0198 inline (Bind 2 `<enable/>`, or `<resume/>`).
    let streamManagement: Bool

    /// Only with Bind 2 inline: without it, binding would need the stream
    /// features SASL2 does not send again, and legacy SASL does that better.
    func isOffered(in features: Element) -> Bool {
        features.firstChild(name: "authentication", namespaceURI: Namespaces.sasl2)?
            .firstChild(name: "inline", namespaceURI: Namespaces.sasl2)?
            .firstChild(name: "bind", namespaceURI: Namespaces.bind2) != nil
    }

    func authenticate(stream: XMLStream, features: Element,
                      resuming: ResumptionRequest?) async throws -> (mechanism: String, outcome: AuthenticationOutcome) {
        guard let authentication = features.firstChild(name: "authentication", namespaceURI: Namespaces.sasl2) else {
            throw SessionError.noUsableMechanism(offered: [])
        }
        let offered = authentication.childElements(name: "mechanism", namespaceURI: Namespaces.sasl2).map(\.text)
        let inline = authentication.firstChild(name: "inline", namespaceURI: Namespaces.sasl2)
        let bindingTypes = Set(
            features.firstChild(name: "sasl-channel-binding", namespaceURI: Namespaces.saslChannelBinding)?
                .childElements(name: "channel-binding").compactMap { $0["type"] } ?? [])
        let exporter = allowChannelBinding && bindingTypes.contains("tls-exporter")
            ? await stream.channelBindingExporter() : nil
        let fastOffered = inline?.firstChild(name: "fast", namespaceURI: Namespaces.fast)?
            .childElements(name: "mechanism", namespaceURI: Namespaces.fast).map(\.text) ?? []
        let smInline = streamManagement && inline?.firstChild(name: "sm", namespaceURI: Namespaces.streamManagement) != nil

        // The token first, when there is one the server still takes.
        if let tokens, userAgent != nil, var token = tokens.load(), token.isUsable(),
           fastOffered.contains(token.mechanism) {
            // An EXPR token needs this connection's exporter (Direct TLS).
            let binding: HTMechanism.Binding? = switch token.mechanism {
            case "HT-SHA-256-EXPR": exporter.map { .tlsExporter($0) }
            case "HT-SHA-256-NONE": HTMechanism.Binding.none
            default: nil
            }
            if let binding {
                token.count &+= 1
                tokens.save(token)
                var mechanism: any SASLMechanism = HTMechanism(username: credentials.username, token: token.secret,
                                                               binding: binding)
                let fast = Element(name: "fast", namespaceURI: Namespaces.fast, attributes: ["count": String(token.count)])
                do {
                    let outcome = try await exchange(&mechanism, on: stream, resuming: resuming, smInline: smInline,
                                                     fastOffered: fastOffered, exporter: exporter, extra: [fast])
                    return (mechanism.name, outcome)
                } catch SessionError.authenticationFailed {
                    // Expired, revoked, or used from elsewhere: forget it. Not
                    // every server takes a second attempt on the same stream
                    // (Prosody does not), so the negotiator starts over.
                    tokens.save(nil)
                    throw SessionError.fastTokenRejected
                } catch SessionError.sasl(_, let error) where error == .serverSignatureMismatch
                            || error == .serverSignatureMissing {
                    // The server could not prove it knows the token: nothing
                    // more goes to it, token or password.
                    tokens.save(nil)
                    throw SessionError.sasl(mechanism: mechanism.name, error)
                }
            }
        }

        guard var mechanism = MechanismSelector.select(
            offered: offered, channelBindingTypes: bindingTypes, exporter: exporter,
            isEncrypted: await stream.isEncrypted, allowPlain: allowPlain, credentials: credentials)
        else { throw SessionError.noUsableMechanism(offered: offered) }
        let outcome = try await exchange(&mechanism, on: stream, resuming: resuming, smInline: smInline,
                                         fastOffered: fastOffered, exporter: exporter, extra: [])
        return (mechanism.name, outcome)
    }

    /// XEP-0082 date-time, with or without fractional seconds.
    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: Exchange

    private func exchange(_ mechanism: inout any SASLMechanism, on stream: XMLStream, resuming: ResumptionRequest?,
                          smInline: Bool, fastOffered: [String], exporter: Data?,
                          extra: [Element]) async throws -> AuthenticationOutcome {
        var authenticate = Element(name: "authenticate", namespaceURI: Namespaces.sasl2,
                                   attributes: ["mechanism": mechanism.name])
        if let initial = try mechanism.start() {
            authenticate.addChild(Element(name: "initial-response", namespaceURI: Namespaces.sasl2,
                                          text: initial.isEmpty ? "=" : initial.base64EncodedString()))
        }
        if let userAgent { authenticate.addChild(userAgent.element) }
        for element in extra { authenticate.addChild(element) }

        // A new token (or a fresh one, rotating the one just used).
        let tokenMechanism = HTMechanism.names(exporterAvailable: exporter != nil).first { fastOffered.contains($0) }
        if tokens != nil, userAgent != nil, let tokenMechanism {
            authenticate.addChild(Element(name: "request-token", namespaceURI: Namespaces.fast,
                                          attributes: ["mechanism": tokenMechanism]))
        }
        // Bind 2, with XEP-0198 enabled inside it. (Resumption is not done
        // here: see `SessionNegotiator`.)
        var bind = Element(name: "bind", namespaceURI: Namespaces.bind2)
        if let bindTag { bind.addChild(Element(name: "tag", namespaceURI: Namespaces.bind2, text: bindTag)) }
        if smInline {
            bind.addChild(Element(name: "enable", namespaceURI: Namespaces.streamManagement, attributes: ["resume": "true"]))
        }
        authenticate.addChild(bind)
        try await stream.send(authenticate)

        while true {
            let element = try await stream.nextNegotiationElement()
            guard element.namespaceURI == Namespaces.sasl2 else { throw SessionError.unexpectedElement(element.name) }
            switch element.name {
            case "challenge":
                let response: Data
                do {
                    response = try mechanism.respond(to: try SASLAuthenticator.decode(element.text))
                } catch let error as SASLError {
                    try? await stream.send(Element(name: "abort", namespaceURI: Namespaces.sasl2))
                    throw SessionError.sasl(mechanism: mechanism.name, error)
                }
                try await stream.send(Element(name: "response", namespaceURI: Namespaces.sasl2,
                                              text: response.base64EncodedString()))
            case "success":
                return try finish(&mechanism, success: element, resuming: resuming, tokenMechanism: tokenMechanism)
            case "failure":
                let condition = element.elements.first { $0.name != "text" && $0.namespaceURI != Namespaces.sasl2 }?.name
                    ?? element.elements.first { $0.name != "text" }?.name ?? "not-authorized"
                let text = element.firstChild(name: "text", namespaceURI: Namespaces.sasl2)?.text
                throw SessionError.authenticationFailed(condition: condition, text: text)
            case "continue":
                // XEP-0388 tasks (a second factor, a password upgrade): none supported.
                try? await stream.send(Element(name: "abort", namespaceURI: Namespaces.sasl2))
                throw SessionError.authenticationFailed(condition: "continue",
                                                        text: "the server asks for steps this client does not support")
            default:
                throw SessionError.unexpectedElement(element.name)
            }
        }
    }

    private func finish(_ mechanism: inout any SASLMechanism, success: Element, resuming: ResumptionRequest?,
                        tokenMechanism: String?) throws -> AuthenticationOutcome {
        let additional = success.firstChild(name: "additional-data", namespaceURI: Namespaces.sasl2)?.text
        do {
            try mechanism.finish(additionalData: try additional.map(SASLAuthenticator.decode))
        } catch let error as SASLError {
            throw SessionError.sasl(mechanism: mechanism.name, error)
        }

        // The token answers our `<request-token/>`, for the mechanism named there.
        if let token = success.firstChild(name: "token", namespaceURI: Namespaces.fast), let secret = token["token"],
           let tokens, let tokenMechanism {
            tokens.save(FASTToken(mechanism: tokenMechanism, secret: secret,
                                  expiry: token["expiry"].flatMap(Self.parseDate)))
        }

        guard let identifier = success.firstChild(name: "authorization-identifier", namespaceURI: Namespaces.sasl2)?.text,
              let jid = try? JID(identifier.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SessionError.bindFailed(StanzaError(.undefinedCondition, text: "no authorization identifier"))
        }

        let resumption: Resumption = resuming == nil ? .none : .failed(handled: nil)
        guard jid.isFull else {
            throw SessionError.bindFailed(StanzaError(.undefinedCondition, text: "Bind 2 gave no full JID"))
        }
        let enabled = success.firstChild(name: "bound", namespaceURI: Namespaces.bind2)?
            .firstChild(name: "enabled", namespaceURI: Namespaces.streamManagement)
        return .bound(jid: jid, features: success, resumption: resumption,
                      streamManagement: enabled.map(InlineStreamManagement.enabled) ?? .none)
    }
}
