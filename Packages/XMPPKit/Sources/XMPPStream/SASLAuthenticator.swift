import Foundation
import XMPPCore
import XMPPTransport
import XMPPXML

/// What authenticating left to do.
///
/// RFC 6120 SASL ends with a stream restart and a separate bind. XEP-0388 SASL2
/// with XEP-0386 Bind 2 binds inside the authentication exchange and skips the
/// restart — which is why the outcome can already carry a bound JID, a
/// resumed XEP-0198 session, or one enabled inline (`SASL2Authenticator`).
enum AuthenticationOutcome: Sendable {
    case restartAndBind
    /// `success` is the SASL2 `<success/>`, for whatever else it carried.
    case bound(jid: JID, features: Element, resumption: Resumption, streamManagement: InlineStreamManagement)
}

protocol Authenticator: Sendable {
    /// True when `features` offer what this authenticator speaks.
    func isOffered(in features: Element) -> Bool
    /// `resuming` is the XEP-0198 session to continue, for authenticators
    /// that can resume inline.
    func authenticate(stream: XMLStream, features: Element,
                      resuming: ResumptionRequest?) async throws -> (mechanism: String, outcome: AuthenticationOutcome)
}

/// RFC 6120 §6 SASL negotiation.
struct SASLAuthenticator: Authenticator {
    let credentials: Credentials
    let allowPlain: Bool
    let allowChannelBinding: Bool

    func isOffered(in features: Element) -> Bool {
        features.firstChild(name: "mechanisms", namespaceURI: Namespaces.sasl) != nil
    }

    func authenticate(stream: XMLStream, features: Element,
                      resuming: ResumptionRequest?) async throws -> (mechanism: String, outcome: AuthenticationOutcome) {
        let offered = features.firstChild(name: "mechanisms", namespaceURI: Namespaces.sasl)?
            .childElements(name: "mechanism").map(\.text) ?? []
        let bindingTypes = Set(
            features.firstChild(name: "sasl-channel-binding", namespaceURI: Namespaces.saslChannelBinding)?
                .childElements(name: "channel-binding").compactMap { $0["type"] } ?? [])
        let exporter = allowChannelBinding ? await stream.channelBindingExporter() : nil

        guard var mechanism = MechanismSelector.select(
            offered: offered,
            channelBindingTypes: bindingTypes,
            exporter: exporter,
            isEncrypted: await stream.isEncrypted,
            allowPlain: allowPlain,
            credentials: credentials)
        else { throw SessionError.noUsableMechanism(offered: offered) }

        do {
            try await exchange(&mechanism, on: stream)
        } catch let error as SASLError {
            // A server that failed to prove itself must not get the benefit of
            // the doubt; tell it we are leaving before the caller closes.
            try? await stream.send(Element(name: "abort", namespaceURI: Namespaces.sasl))
            throw SessionError.sasl(mechanism: mechanism.name, error)
        }
        return (mechanism.name, .restartAndBind)
    }

    private func exchange(_ mechanism: inout any SASLMechanism, on stream: XMLStream) async throws {
        var auth = Element(name: "auth", namespaceURI: Namespaces.sasl,
                           attributes: ["mechanism": mechanism.name])
        if let initial = try mechanism.start() {
            // RFC 6120 §6.4.2: a zero-length initial response is sent as "=".
            auth.addText(initial.isEmpty ? "=" : initial.base64EncodedString())
        }
        try await stream.send(auth)

        while true {
            let element = try await stream.nextNegotiationElement()
            guard element.namespaceURI == Namespaces.sasl else {
                throw SessionError.unexpectedElement(element.name)
            }
            switch element.name {
            case "challenge":
                let response = try mechanism.respond(to: try Self.decode(element.text))
                try await stream.send(Element(name: "response", namespaceURI: Namespaces.sasl,
                                              text: response.base64EncodedString()))
            case "success":
                let text = element.text
                try mechanism.finish(additionalData: text.isEmpty ? nil : try Self.decode(text))
                return
            case "failure":
                let condition = element.elements.first { $0.name != "text" }?.name ?? "not-authorized"
                let text = element.firstChild(name: "text")?.text
                throw SessionError.authenticationFailed(condition: condition, text: text)
            default:
                throw SessionError.unexpectedElement(element.name)
            }
        }
    }

    /// Base64 payload of a SASL element; `=` is the explicit empty value.
    static func decode(_ text: String) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "=" { return Data() }
        guard let data = Data(base64Encoded: trimmed) else {
            throw SASLError.malformedServerMessage("payload is not base64")
        }
        return data
    }
}

/// Picks the strongest mechanism both sides support.
public enum MechanismSelector {

    /// Preference order. `-PLUS` first: channel binding is what defeats a
    /// man-in-the-middle holding a certificate the user was talked into
    /// trusting. PLAIN last, and only over TLS.
    public static let preference = [
        "SCRAM-SHA-256-PLUS", "SCRAM-SHA-1-PLUS", "SCRAM-SHA-256", "SCRAM-SHA-1", "PLAIN",
    ]

    public static func select(
        offered: [String],
        channelBindingTypes: Set<String>,
        exporter: Data?,
        isEncrypted: Bool,
        allowPlain: Bool,
        credentials: Credentials
    ) -> (any SASLMechanism)? {
        let offered = Set(offered)
        // XEP-0440: without an advertised tls-exporter we cannot know which
        // binding the server would check, so -PLUS is off the table.
        let canBind = exporter != nil && channelBindingTypes.contains("tls-exporter")
        let serverOffersPlus = offered.contains { $0.hasSuffix("-PLUS") }

        for name in preference where offered.contains(name) {
            switch name {
            case "SCRAM-SHA-256-PLUS", "SCRAM-SHA-1-PLUS":
                guard canBind, let exporter else { continue }
                return SCRAMMechanism(hash: name.contains("256") ? .sha256 : .sha1,
                                      username: credentials.username, password: credentials.password,
                                      binding: .tlsExporter(exporter))
            case "SCRAM-SHA-256", "SCRAM-SHA-1":
                // "y" tells a server that does support binding that we saw no
                // -PLUS offer — so a stripped offer is detected. If -PLUS was
                // offered and we are not using it, we cannot bind: "n".
                let binding: SCRAMMechanism.ChannelBinding =
                    exporter != nil && !serverOffersPlus ? .notOfferedByServer : .unsupported
                return SCRAMMechanism(hash: name.contains("256") ? .sha256 : .sha1,
                                      username: credentials.username, password: credentials.password,
                                      binding: binding)
            case "PLAIN":
                guard isEncrypted, allowPlain else { continue }
                return PlainMechanism(username: credentials.username, password: credentials.password)
            default:
                continue
            }
        }
        return nil
    }
}
