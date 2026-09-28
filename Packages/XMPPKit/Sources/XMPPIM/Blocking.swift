import Foundation
import XMPPClient
import XMPPCore
import XMPPXML

/// XEP-0191 blocking command.
public struct Blocking: Sendable {

    public enum Push: Sendable, Equatable {
        case blocked([JID])
        case unblocked([JID])
        /// An `<unblock/>` with no items: everything was unblocked (§3.4).
        case unblockedAll
    }

    public let client: XMPPClient

    public init(client: XMPPClient) {
        self.client = client
    }

    /// Answers block/unblock pushes from our own server, and hands each to
    /// `onPush` before replying.
    public func handlePushes(_ onPush: @escaping @Sendable (Push) async -> Void) async {
        for name in ["block", "unblock"] {
            await client.setHandler(name: name, namespace: Namespaces.blocking, advertise: false) { [client] iq in
                guard iq.type == .set else { throw StanzaError(.badRequest) }
                if let from = iq.from {
                    guard let account = await client.jid, from == account.bare else {
                        throw StanzaError(.serviceUnavailable)
                    }
                }
                let jids = Self.jids(in: iq.payload)
                switch (name, jids.isEmpty) {
                case ("block", true): throw StanzaError(.badRequest)
                case ("block", false): await onPush(.blocked(jids))
                case (_, true): await onPush(.unblockedAll)
                case (_, false): await onPush(.unblocked(jids))
                }
                return nil
            }
        }
    }

    /// Whether the server supports blocking, from its disco#info.
    public func isSupported() async throws -> Bool {
        guard let domain = await client.jid?.domain else { throw ClientError.notConnected }
        return try await client.discoInfo(domain).supports(Namespaces.blocking)
    }

    public func blocklist() async throws -> [JID] {
        let reply = try await client.send(IQ(type: .get, payload: Element(name: "blocklist", namespaceURI: Namespaces.blocking)))
        return Self.jids(in: reply.payload)
    }

    public func block(_ jids: [JID]) async throws {
        precondition(!jids.isEmpty, "blocking nothing is a bad-request")
        _ = try await client.send(IQ(type: .set, payload: Self.command("block", jids)))
    }

    /// Unblocks `jids`; an empty list unblocks everyone.
    public func unblock(_ jids: [JID]) async throws {
        _ = try await client.send(IQ(type: .set, payload: Self.command("unblock", jids)))
    }

    private static func command(_ name: String, _ jids: [JID]) -> Element {
        var command = Element(name: name, namespaceURI: Namespaces.blocking)
        for jid in jids {
            command.addChild(Element(name: "item", namespaceURI: Namespaces.blocking, attributes: ["jid": jid.description]))
        }
        return command
    }

    private static func jids(in payload: Element?) -> [JID] {
        payload?.childElements(name: "item", namespaceURI: Namespaces.blocking)
            .compactMap { $0["jid"].flatMap { try? JID($0) } } ?? []
    }
}
