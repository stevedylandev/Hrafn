import Foundation
import XMPPCore
import XMPPTransport
import XMPPXML

extension Namespaces {
    /// XEP-0440 SASL channel-binding type capability.
    public static let saslChannelBinding = "urn:xmpp:sasl-cb:0"
}

public struct Credentials: Sendable {
    /// The account's bare JID.
    public let jid: JID
    public let password: String

    /// Refuses a JID without a localpart: anonymous login is not supported.
    public init(jid: JID, password: String) throws {
        guard jid.localpart != nil else { throw SessionError.invalidAccountJID }
        self.jid = jid.bare
        self.password = password
    }

    /// The SASL authentication identity: the PRECIS-prepared localpart.
    public var username: String { jid.localpart ?? "" }
}

public enum SessionError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidAccountJID
    /// The domain's SRV records say it offers no XMPP service.
    case noEndpoints
    case noUsableMechanism(offered: [String])
    /// `<failure/>` from the server (RFC 6120 §6.5): wrong password, disabled
    /// account, and so on. Not retried on another endpoint.
    case authenticationFailed(condition: String, text: String?)
    /// The mechanism itself failed, e.g. the server could not prove it knows
    /// the password. Not retried either.
    case sasl(mechanism: String, SASLError)
    case bindingNotOffered
    case bindFailed(StanzaError)
    case unexpectedElement(String)
    /// XEP-0484: the server refused our token. It has been forgotten, and a
    /// new connection authenticates with the password.
    case fastTokenRejected

    /// Failures that would recur on every endpoint of the same domain.
    public var isFatal: Bool {
        switch self {
        case .invalidAccountJID, .authenticationFailed, .sasl, .noEndpoints: true
        default: false
        }
    }

    public var description: String {
        switch self {
        case .invalidAccountJID: "an account JID needs a localpart"
        case .noEndpoints: "the domain offers no XMPP service"
        case .noUsableMechanism(let offered): "no usable SASL mechanism among \(offered)"
        case .authenticationFailed(let condition, let text):
            "authentication failed: \(condition)" + (text.map { " (\($0))" } ?? "")
        case .sasl(let mechanism, let error): "\(mechanism): \(error)"
        case .bindingNotOffered: "server did not offer resource binding"
        case .bindFailed(let error): "resource binding failed: \(error)"
        case .unexpectedElement(let name): "unexpected <\(name)/>"
        case .fastTokenRejected: "the server refused the saved login token"
        }
    }
}

public struct SessionConfiguration: Sendable {
    public var credentials: Credentials
    /// Requested resource. `nil` lets the server generate one, which RFC 6120
    /// §7.6 recommends and which avoids leaking a device name.
    public var resource: String?
    public var tlsPolicy: TLSPolicy
    /// Skips DNS when set: the Docker servers, or a user's manual host setting.
    public var endpoints: [Endpoint]?
    public var resolver: EndpointResolver
    /// PLAIN is only ever used over TLS; this can forbid it altogether.
    public var allowPlain: Bool
    /// Use SCRAM-*-PLUS when both the transport and the server can.
    public var allowChannelBinding: Bool
    public var console: (any XMLConsole)?
    public var negotiationTimeout: Duration
    /// XEP-0388 SASL2 with XEP-0386 Bind 2, when the server offers both.
    public var allowSASL2: Bool
    /// XEP-0388 `<user-agent/>`. FAST needs it: tokens belong to one.
    public var userAgent: UserAgent?
    /// XEP-0484: where tokens are kept. `nil` turns FAST off.
    public var fastTokens: (any FASTTokenStore)?

    public init(
        credentials: Credentials,
        resource: String? = nil,
        tlsPolicy: TLSPolicy = .standard(),
        endpoints: [Endpoint]? = nil,
        resolver: EndpointResolver = EndpointResolver(),
        allowPlain: Bool = true,
        allowChannelBinding: Bool = true,
        console: (any XMLConsole)? = nil,
        negotiationTimeout: Duration = .seconds(20),
        allowSASL2: Bool = true,
        userAgent: UserAgent? = nil,
        fastTokens: (any FASTTokenStore)? = nil
    ) {
        self.credentials = credentials
        self.resource = resource
        self.tlsPolicy = tlsPolicy
        self.endpoints = endpoints
        self.resolver = resolver
        self.allowPlain = allowPlain
        self.allowChannelBinding = allowChannelBinding
        self.console = console
        self.negotiationTimeout = negotiationTimeout
        self.allowSASL2 = allowSASL2
        self.userAgent = userAgent
        self.fastTokens = fastTokens
    }
}

/// An authenticated, bound stream, ready for stanzas.
public struct EstablishedSession: Sendable {
    public let stream: XMLStream
    public let endpoint: Endpoint
    /// The full JID the server bound.
    public let jid: JID
    /// The SASL mechanism that authenticated the stream.
    public let mechanism: String
    /// Features of the authenticated stream: where XEP-0198 and XEP-0352
    /// support is advertised.
    public internal(set) var features: Element
    /// Whether this continues an earlier XEP-0198 session.
    public internal(set) var resumption: Resumption = .none
    /// XEP-0198 enabled during authentication (Bind 2): the server's
    /// `<enabled/>`, so the client does not send `<enable/>` again.
    public internal(set) var streamManagementEnabled: Element?
    /// Authenticated with SASL2 (no stream restart): `features` are the
    /// pre-authentication ones, which is all the server sent.
    public internal(set) var usedSASL2 = false

    /// Adds features the server announced after SASL2 success, keeping any
    /// already known.
    public mutating func mergeFeatures(_ announced: Element) {
        for feature in announced.elements
        where features.firstChild(name: feature.name, namespaceURI: feature.namespaceURI ?? "") == nil {
            features.addChild(feature)
        }
    }
}

/// RFC 6120 stream negotiation: TLS, SASL, restart, bind.
public struct SessionNegotiator: Sendable {

    public enum Phase: Sendable, Equatable {
        case resolving
        case connecting(Endpoint)
        case securing
        case authenticating
        case resuming
        case binding
        case established(JID)
    }

    public let configuration: SessionConfiguration
    private let makeStream: @Sendable (Endpoint, SessionConfiguration) -> XMLStream

    public init(configuration: SessionConfiguration) {
        self.init(configuration: configuration) { endpoint, configuration in
            XMLStream(endpoint: endpoint, domain: configuration.credentials.jid.domain,
                      policy: configuration.tlsPolicy, console: configuration.console,
                      negotiationTimeout: configuration.negotiationTimeout)
        }
    }

    /// Injects the stream, so negotiation can be driven over a fake transport.
    init(configuration: SessionConfiguration,
         makeStream: @escaping @Sendable (Endpoint, SessionConfiguration) -> XMLStream) {
        self.configuration = configuration
        self.makeStream = makeStream
    }

    /// Tries each endpoint in turn until one yields a bound session. Failures
    /// that would recur everywhere (a wrong password) end the attempt at once;
    /// otherwise the last endpoint's error is thrown.
    ///
    /// With `resuming`, the XEP-0198 session it names is resumed instead of a
    /// resource being bound, when the server still can; its `endpoint`, if any,
    /// is tried first.
    /// `streamManagement` asks for XEP-0198 inline where the authentication
    /// can carry it (SASL2 with Bind 2); otherwise the client enables it.
    public func establish(resuming: ResumptionRequest? = nil, streamManagement: Bool = false,
                          onPhase: @Sendable (Phase) -> Void = { _ in }) async throws -> EstablishedSession {
        let jid = configuration.credentials.jid
        var endpoints: [Endpoint]
        if let configured = configuration.endpoints {
            endpoints = configured
        } else {
            onPhase(.resolving)
            endpoints = try await configuration.resolver.endpoints(for: jid.domain)
        }
        guard !endpoints.isEmpty else { throw SessionError.noEndpoints }
        if let preferred = resuming?.endpoint {
            endpoints.removeAll { $0 == preferred }
            endpoints.insert(preferred, at: 0)
        }

        var lastError: any Error = SessionError.noEndpoints
        for endpoint in endpoints {
            try Task.checkCancellation()
            onPhase(.connecting(endpoint))
            // A second go at the same endpoint only after a refused FAST
            // token, which is gone by then: the password is used instead.
            for attempt in 0..<2 {
                let stream = makeStream(endpoint, configuration)
                do {
                    return try await negotiate(stream, endpoint: endpoint, resuming: resuming,
                                               streamManagement: streamManagement, onPhase: onPhase)
                } catch SessionError.fastTokenRejected where attempt == 0 {
                    await stream.close()
                    continue
                } catch {
                    await stream.close()
                    if error is CancellationError { throw error }
                    if let error = error as? SessionError, error.isFatal { throw error }
                    lastError = error
                    break
                }
            }
        }
        throw lastError
    }

    private func negotiate(_ stream: XMLStream, endpoint: Endpoint, resuming: ResumptionRequest?,
                           streamManagement: Bool,
                           onPhase: @Sendable (Phase) -> Void) async throws -> EstablishedSession {
        let account = configuration.credentials.jid
        try await stream.open(from: account, onlyIfEncrypted: true)
        var features = try await stream.awaitFeatures()

        if !(await stream.isEncrypted) {
            onPhase(.securing)
            features = try await stream.negotiateTLS(features: features, from: account) ?? features
        }

        onPhase(.authenticating)
        var authenticators: [any Authenticator] = []
        // SASL2 for fresh sessions only. Resuming inside SASL2 (XEP-0198
        // inline) lost stanzas on ejabberd when attempts were cut short: its
        // queue did not follow the session to the attempt that succeeded.
        // The restart-then-`<resume/>` path has never lost one.
        if configuration.allowSASL2, resuming == nil {
            authenticators.append(SASL2Authenticator(
                credentials: configuration.credentials, allowPlain: configuration.allowPlain,
                allowChannelBinding: configuration.allowChannelBinding, userAgent: configuration.userAgent,
                bindTag: configuration.userAgent?.software, tokens: configuration.fastTokens,
                streamManagement: streamManagement))
        }
        authenticators.append(SASLAuthenticator(credentials: configuration.credentials,
                                                allowPlain: configuration.allowPlain,
                                                allowChannelBinding: configuration.allowChannelBinding))
        guard let authenticator = authenticators.first(where: { $0.isOffered(in: features) }) else {
            throw SessionError.noUsableMechanism(offered: [])
        }
        let (mechanism, outcome) = try await authenticator.authenticate(stream: stream, features: features,
                                                                        resuming: resuming)

        let jid: JID
        var resumption = Resumption.none
        var streamManagementEnabled: Element?
        var usedSASL2 = false
        switch outcome {
        case .bound(let boundJID, _, let inlineResumption, let inlineStreamManagement):
            // No restart, and no second features: the pre-authentication
            // ones stand.
            jid = boundJID
            resumption = inlineResumption
            usedSASL2 = true
            // Bind 2 lists what it can switch on inline; CSI among them means
            // the server takes client state (XEP-0352) on this stream.
            let inlineFeatures = features.firstChild(name: "authentication", namespaceURI: Namespaces.sasl2)?
                .firstChild(name: "inline", namespaceURI: Namespaces.sasl2)?
                .firstChild(name: "bind", namespaceURI: Namespaces.bind2)?
                .firstChild(name: "inline", namespaceURI: Namespaces.bind2)?
                .childElements(name: "feature", namespaceURI: Namespaces.bind2).compactMap { $0["var"] } ?? []
            if inlineFeatures.contains(Namespaces.csi),
               features.firstChild(name: "csi", namespaceURI: Namespaces.csi) == nil {
                features.addChild(Element(name: "csi", namespaceURI: Namespaces.csi))
            }
            if case .enabled(let enabled) = inlineStreamManagement { streamManagementEnabled = enabled }
        case .restartAndBind:
            features = try await stream.restart(from: account)
            if let resuming {
                if SessionResumer.isOffered(in: features) {
                    onPhase(.resuming)
                    resumption = try await SessionResumer(stream: stream).resume(resuming)
                } else {
                    resumption = .failed(handled: nil)
                }
            }
            if let resuming, case .resumed = resumption {
                jid = resuming.jid
            } else {
                onPhase(.binding)
                jid = try await ResourceBinder(stream: stream).bind(features: features,
                                                                     resource: configuration.resource)
            }
        }

        onPhase(.established(jid))
        var session = EstablishedSession(stream: stream, endpoint: endpoint, jid: jid,
                                         mechanism: mechanism, features: features)
        session.resumption = resumption
        session.streamManagementEnabled = streamManagementEnabled
        session.usedSASL2 = usedSASL2
        return session
    }
}

/// RFC 6120 §7 resource binding, plus the RFC 3921 session IQ for the servers
/// that still insist on it.
struct ResourceBinder {
    let stream: XMLStream

    func bind(features: Element, resource: String?) async throws -> JID {
        guard features.firstChild(name: "bind", namespaceURI: Namespaces.bind) != nil else {
            throw SessionError.bindingNotOffered
        }

        let jid: JID
        do {
            jid = try await requestBinding(resource: resource)
        } catch SessionError.bindFailed(let error)
                    where resource != nil
                    && [.conflict, .badRequest, .notAllowed].contains(error.condition) {
            // §7.7.2: the requested resource is taken or unacceptable. Let the
            // server pick one rather than failing the login.
            jid = try await requestBinding(resource: nil)
        }

        // RFC 3921 §3 session establishment. RFC 6120 dropped it; servers that
        // still advertise it mark it <optional/>, and only a mandatory one is sent.
        if let session = features.firstChild(name: "session", namespaceURI: Namespaces.session),
           session.firstChild(name: "optional") == nil {
            let request = IQ(type: .set, payload: Element(name: "session", namespaceURI: Namespaces.session))
            let reply = try await roundTrip(request)
            if let error = reply.error { throw SessionError.bindFailed(error) }
        }
        return jid
    }

    private func requestBinding(resource: String?) async throws -> JID {
        var bind = Element(name: "bind", namespaceURI: Namespaces.bind)
        if let resource {
            bind.addChild(Element(name: "resource", namespaceURI: Namespaces.bind, text: resource))
        }
        let reply = try await roundTrip(IQ(type: .set, payload: bind))
        if let error = reply.error { throw SessionError.bindFailed(error) }

        guard let text = reply.payload?.firstChild(name: "jid", namespaceURI: Namespaces.bind)?.text,
              let jid = try? JID(text), jid.isFull else {
            throw SessionError.bindFailed(StanzaError(.undefinedCondition, text: "no full JID in bind result"))
        }
        return jid
    }

    /// Sends an IQ and waits for its reply. Nothing else is routed before
    /// binding completes, so anything else arriving is out of place.
    private func roundTrip(_ request: IQ) async throws -> IQ {
        try await stream.send(request.element)
        let element = try await stream.nextNegotiationElement()
        guard let reply = IQ(element), reply.requestID == request.requestID,
              reply.type == .result || reply.type == .error else {
            throw SessionError.unexpectedElement(element.name)
        }
        return reply
    }
}
