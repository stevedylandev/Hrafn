import Foundation
import XMPPClient
import XMPPCore
import XMPPXML

extension Namespaces {
    /// XEP-0357.
    public static let push = "urn:xmpp:push:0"
    /// XEP-0357 §7: the summary form a server may include.
    public static let pushSummary = "urn:xmpp:push:summary"
    /// XEP-0060.
    public static let pubsub = "http://jabber.org/protocol/pubsub"
    /// XEP-0060 §7.1.5: the `FORM_TYPE` of publish options.
    public static let publishOptions = "http://jabber.org/protocol/pubsub#publish-options"
}

/// XEP-0357 push notifications, the client's half: asking the account's
/// server to notify an app server (the "XMPP Push Service") while this client
/// is offline.
public struct PushNotifications: Sendable {

    public let client: XMPPClient

    public init(client: XMPPClient) {
        self.client = client
    }

    /// Whether the account's server can push (§5: the feature is advertised on
    /// the account's bare JID, not the domain).
    public func isSupported() async throws -> Bool {
        guard let account = await client.jid?.bare else { throw ClientError.notConnected }
        return try await client.discoInfo(account).supports(Namespaces.push)
    }

    /// §5: registers `node` on the app server `service`. `publishOptions` are
    /// passed back to the app server with each notification (secrets, which
    /// push module to use, …). Enabling the same service and node again
    /// replaces the options, so this is safe to repeat on every login.
    public func enable(service: JID, node: String, publishOptions: [String: String] = [:]) async throws {
        _ = try await client.send(IQ(type: .set, payload: Self.enable(service: service, node: node,
                                                                       publishOptions: publishOptions)))
    }

    /// §6: stops notifications to `node` on `service`, or to every node there
    /// when `node` is `nil`.
    public func disable(service: JID, node: String?) async throws {
        var disable = Element(name: "disable", namespaceURI: Namespaces.push, attributes: ["jid": service.description])
        disable["node"] = node
        _ = try await client.send(IQ(type: .set, payload: disable))
    }

    static func enable(service: JID, node: String, publishOptions: [String: String]) -> Element {
        var enable = Element(name: "enable", namespaceURI: Namespaces.push,
                             attributes: ["jid": service.description, "node": node])
        if !publishOptions.isEmpty {
            var fields = [DataForm.Field(variable: "FORM_TYPE", type: "hidden", values: [Namespaces.publishOptions])]
            for key in publishOptions.keys.sorted() {
                fields.append(DataForm.Field(variable: key, values: [publishOptions[key]!]))
            }
            enable.addChild(DataForm(type: .submit, fields: fields).element)
        }
        return enable
    }
}

/// A notification as the app server receives it (§7): a XEP-0060 publish to
/// the registered node from the user's server. Hrafn's push app server is
/// fpush; this is what the integration tests use to stand in for it.
public struct PushNotification: Sendable, Equatable {
    public var node: String
    /// §7's summary form, when the server sends one. Servers leave fields out
    /// (message bodies especially) as they see fit.
    public var messageCount: Int?
    public var lastMessageSender: String?
    public var lastMessageBody: String?
    /// The options the client gave in `<enable/>`.
    public var publishOptions: [String: String]

    public init?(_ iq: IQ) {
        guard iq.type == .set, let pubsub = iq.payload, pubsub.matches(name: "pubsub", namespaceURI: Namespaces.pubsub),
              let publish = pubsub.firstChild(name: "publish", namespaceURI: Namespaces.pubsub),
              let node = publish["node"] else { return nil }
        self.node = node
        let notification = publish.firstChild(name: "item", namespaceURI: Namespaces.pubsub)?
            .firstChild(name: "notification", namespaceURI: Namespaces.push)
        let summary = notification?.firstChild(name: "x", namespaceURI: Namespaces.dataForms).flatMap(DataForm.init(element:))
        if let summary, summary.formType == Namespaces.pushSummary {
            messageCount = summary["message-count"]?.first.flatMap { Int($0) }
            lastMessageSender = summary["last-message-sender"]?.first
            lastMessageBody = summary["last-message-body"]?.first
        }
        var options: [String: String] = [:]
        if let form = pubsub.firstChild(name: "publish-options", namespaceURI: Namespaces.pubsub)?
            .firstChild(name: "x", namespaceURI: Namespaces.dataForms).flatMap(DataForm.init(element:)) {
            for field in form.fields where field.variable != nil && field.variable != "FORM_TYPE" {
                options[field.variable!] = field.values.first ?? ""
            }
        }
        publishOptions = options
    }
}
