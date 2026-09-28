import Foundation
import XMPPClient
import XMPPCore
import XMPPXML

/// RFC 6121 §2.1.2 roster item.
public struct RosterItem: Sendable, Hashable, Codable {
    public enum Subscription: String, Sendable, Hashable, Codable {
        case none, to, from, both
        /// Only ever in a push: the item was deleted.
        case remove
    }

    public var jid: JID
    public var name: String?
    public var subscription: Subscription
    /// `ask='subscribe'`: our subscription request is pending.
    public var isPendingOut: Bool
    public var groups: [String]

    public init(jid: JID, name: String? = nil, subscription: Subscription = .none,
                isPendingOut: Bool = false, groups: [String] = []) {
        self.jid = jid
        self.name = name
        self.subscription = subscription
        self.isPendingOut = isPendingOut
        self.groups = groups
    }

    /// Items with an unparseable or non-bare JID are refused (§2.1.2.2 wants
    /// bare JIDs, and a resource here would split the contact in two).
    public init?(element: Element) {
        guard element.matches(name: "item", namespaceURI: Namespaces.roster),
              let jid = element["jid"].flatMap({ try? JID($0) }), jid.isBare else { return nil }
        self.jid = jid
        let name = element["name"]
        self.name = name?.isEmpty == false ? name : nil
        // §2.1.2.5: a missing or unknown value is "none".
        subscription = element["subscription"].flatMap(Subscription.init(rawValue:)) ?? .none
        isPendingOut = element["ask"] == "subscribe"
        var seen = Set<String>()
        groups = element.childElements(name: "group", namespaceURI: Namespaces.roster)
            .map(\.text).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The item as a client sends it in a roster set: `subscription` and `ask`
    /// belong to the server (§2.1.2.5) and are left out, except for `remove`.
    public var element: Element {
        var item = Element(name: "item", namespaceURI: Namespaces.roster, attributes: ["jid": jid.description])
        if subscription == .remove {
            item["subscription"] = "remove"
            return item
        }
        item["name"] = name
        for group in groups { item.addChild(Element(name: "group", namespaceURI: Namespaces.roster, text: group)) }
        return item
    }

    /// We receive their presence.
    public var isSubscribedTo: Bool { subscription == .to || subscription == .both }
    /// They receive ours.
    public var isSubscribedFrom: Bool { subscription == .from || subscription == .both }
}

/// RFC 6121 §2 roster management: fetch with versioning, add/update/remove,
/// and pushes.
public struct Roster: Sendable {

    public enum FetchResult: Sendable, Equatable {
        /// The whole roster, replacing the cached copy.
        case full(items: [RosterItem], version: String?)
        /// §2.6.3: the cached copy at the requested version is current;
        /// anything that changed arrives as pushes.
        case unchanged
    }

    /// A roster push (§2.1.6). `version` is set when the server versions.
    public struct Push: Sendable, Equatable {
        public let item: RosterItem
        public let version: String?

        public init(item: RosterItem, version: String?) {
            self.item = item
            self.version = version
        }
    }

    public let client: XMPPClient

    public init(client: XMPPClient) {
        self.client = client
    }

    /// Answers roster pushes and hands each valid one to `onPush`; the reply is
    /// sent once `onPush` returns, so persist before returning.
    ///
    /// Pushes from anyone but our own account are refused: a forged push could
    /// otherwise add or remove contacts.
    public func handlePushes(_ onPush: @escaping @Sendable (Push) async -> Void) async {
        let client = self.client
        await client.setHandler(name: "query", namespace: Namespaces.roster, advertise: false) { iq in
            guard iq.type == .set else { throw StanzaError(.badRequest) }
            if let from = iq.from {
                guard let account = await client.jid, from == account.bare else {
                    throw StanzaError(.serviceUnavailable)
                }
            }
            // §2.1.6: exactly one item.
            let items = iq.payload?.childElements(name: "item", namespaceURI: Namespaces.roster) ?? []
            guard items.count == 1, let item = RosterItem(element: items[0]) else {
                throw StanzaError(.badRequest)
            }
            await onPush(Push(item: item, version: iq.payload?["ver"]))
            return nil
        }
    }

    /// Whether the current stream offers roster versioning (§2.6.1).
    public var supportsVersioning: Bool {
        get async {
            await client.streamFeatures?.firstChild(name: "ver", namespaceURI: Namespaces.rosterVersioning) != nil
        }
    }

    /// Fetches the roster. `version` is the one cached from the last fetch or
    /// push; it is only sent when the server versions, and `""` asks for the
    /// full roster with a version.
    public func fetch(version: String?) async throws -> FetchResult {
        var query = Element(name: "query", namespaceURI: Namespaces.roster)
        if await supportsVersioning { query["ver"] = version ?? "" }
        let reply = try await client.send(IQ(type: .get, payload: query))
        guard let payload = reply.payload, payload.matches(name: "query", namespaceURI: Namespaces.roster) else {
            return .unchanged
        }
        let items = payload.childElements(name: "item", namespaceURI: Namespaces.roster)
            .compactMap(RosterItem.init(element:))
            .filter { $0.subscription != .remove }
        return .full(items: items, version: payload["ver"])
    }

    /// Adds or updates an item (§2.3, §2.4). Subscription state is not touched;
    /// use `Subscriptions` for that.
    public func set(_ item: RosterItem) async throws {
        var item = item
        if item.subscription == .remove { item.subscription = .none }
        _ = try await client.send(IQ(type: .set, payload: Element(name: "query", namespaceURI: Namespaces.roster)
            .adding(item.element)))
    }

    /// Deletes an item, which also cancels subscriptions both ways (§2.5).
    public func remove(_ jid: JID) async throws {
        let item = RosterItem(jid: jid.bare, subscription: .remove)
        _ = try await client.send(IQ(type: .set, payload: Element(name: "query", namespaceURI: Namespaces.roster)
            .adding(item.element)))
    }
}
