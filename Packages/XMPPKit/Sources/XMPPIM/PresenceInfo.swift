import Foundation
import XMPPClient
import XMPPCore
import XMPPXML

/// RFC 6121 §4.7.2.1 `<show/>`, with plain availability as `.online`.
public enum Availability: String, Sendable, Hashable, Comparable, CaseIterable {
    case chat, online, away, xa, dnd, offline

    /// Most to least reachable, for picking what to show for a contact.
    private var rank: Int {
        switch self {
        case .chat: 0
        case .online: 1
        case .dnd: 2
        case .away: 3
        case .xa: 4
        case .offline: 5
        }
    }

    public static func < (lhs: Availability, rhs: Availability) -> Bool { lhs.rank < rhs.rank }
}

extension Presence {

    public var availability: Availability {
        switch type {
        case .available:
            let show = element.firstChild(name: "show", namespaceURI: Namespaces.client)?.text
            return show.flatMap(Availability.init(rawValue:)).flatMap { $0 == .offline ? nil : $0 } ?? .online
        default:
            return .offline
        }
    }

    public var status: String? {
        let text = element.firstChild(name: "status", namespaceURI: Namespaces.client)?.text
        return text?.isEmpty == false ? text : nil
    }

    /// §4.7.2.3: −128…127, default 0.
    public var priority: Int {
        let value = element.firstChild(name: "priority", namespaceURI: Namespaces.client)
            .flatMap { Int($0.text.trimmingCharacters(in: .whitespaces)) } ?? 0
        return min(127, max(-128, value))
    }

    /// Our own available presence, with caps so peers can discover features.
    public static func available(_ availability: Availability = .online, status: String? = nil,
                                 priority: Int = 0, caps: Element? = nil) -> Presence {
        var presence = Presence()
        if availability != .online, availability != .offline {
            presence.element.addChild(Element(name: "show", namespaceURI: Namespaces.client, text: availability.rawValue))
        }
        if let status {
            presence.element.addChild(Element(name: "status", namespaceURI: Namespaces.client, text: status))
        }
        if priority != 0 {
            presence.element.addChild(Element(name: "priority", namespaceURI: Namespaces.client, text: String(priority)))
        }
        if let caps { presence.element.addChild(caps) }
        return presence
    }
}

/// Who is online, per resource, from the presence stream. A value type: the
/// owner feeds it presences and reads it back.
public struct PresenceBook: Sendable, Equatable {

    public struct Resource: Sendable, Equatable {
        public var availability: Availability
        public var status: String?
        public var priority: Int
        /// When it last changed, relative to the others.
        var sequence = 0
    }

    private var resources: [JID: [String: Resource]] = [:]
    private var sequence = 0

    public init() {}

    /// Records an available or unavailable presence; returns whether the
    /// contact's summary changed. Other types are ignored.
    @discardableResult
    public mutating func update(_ presence: Presence) -> Bool {
        guard let from = presence.from else { return false }
        let bare = from.bare
        let before = summary(for: bare)
        let resource = from.resourcepart ?? ""
        switch presence.type {
        case .available:
            sequence += 1
            resources[bare, default: [:]][resource] = Resource(
                availability: presence.availability, status: presence.status, priority: presence.priority,
                sequence: sequence)
        case .unavailable:
            if from.isBare {
                resources[bare] = nil
            } else {
                resources[bare]?[resource] = nil
                if resources[bare]?.isEmpty == true { resources[bare] = nil }
            }
        case .error:
            // RFC 6121 §4.3.3: a presence error means we get no presence from them.
            resources[bare] = nil
        default:
            return false
        }
        return summary(for: bare) != before
    }

    /// Forgets everyone: on a fresh session, presence starts over.
    public mutating func reset() {
        resources.removeAll()
        sequence = 0
    }

    /// The highest-priority resource, ties broken by the latest change. Not
    /// the most reachable: a session the server keeps for resumption still
    /// advertises the old presence, and would hide the one just set.
    public func summary(for jid: JID) -> Resource? {
        resources[jid.bare]?.values.max { lhs, rhs in
            lhs.priority != rhs.priority ? lhs.priority < rhs.priority : lhs.sequence < rhs.sequence
        }
    }

    public func availability(of jid: JID) -> Availability {
        summary(for: jid)?.availability ?? .offline
    }

    public func onlineResources(of jid: JID) -> [String] {
        resources[jid.bare].map { Array($0.keys).sorted() } ?? []
    }
}

/// RFC 6121 §3 presence subscription flows.
public struct Subscriptions: Sendable {
    public let client: XMPPClient

    public init(client: XMPPClient) {
        self.client = client
    }

    /// Asks to see their presence (§3.1.1).
    public func request(_ jid: JID) async throws {
        try await client.send(Presence(type: .subscribe, to: jid.bare))
    }

    /// Lets them see ours — answering a request, or pre-approving (§3.1.4, §3.4).
    public func approve(_ jid: JID) async throws {
        try await client.send(Presence(type: .subscribed, to: jid.bare))
    }

    /// Refuses a request, or revokes their subscription to us (§3.2).
    public func deny(_ jid: JID) async throws {
        try await client.send(Presence(type: .unsubscribed, to: jid.bare))
    }

    /// Stops seeing their presence (§3.3).
    public func cancel(_ jid: JID) async throws {
        try await client.send(Presence(type: .unsubscribe, to: jid.bare))
    }
}
