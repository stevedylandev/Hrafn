import Foundation
import XMPPClient
import XMPPCore
import XMPPXML

extension Namespaces {
    /// XEP-0402 Bookmarks 2: the PEP node and the payload namespace.
    public static let bookmarks = "urn:xmpp:bookmarks:1"
    /// XEP-0402 §5.3: the server keeps XEP-0048 bookmarks in step.
    public static let bookmarksCompat = "urn:xmpp:bookmarks:1#compat"
    /// XEP-0048, read-only fallback.
    public static let legacyBookmarks = "storage:bookmarks"
    /// XEP-0049 private XML storage, where XEP-0048 keeps them.
    public static let privateStorage = "jabber:iq:private"
    public static let pubsubEvent = "http://jabber.org/protocol/pubsub#event"
}

/// A bookmarked room (XEP-0402 §3).
public struct Bookmark: Sendable, Hashable {
    public var room: JID
    public var name: String?
    public var autojoin: Bool
    public var nick: String?
    public var password: String?
    /// §3.3: what other clients stored alongside; published back untouched.
    public var extensions: Element?

    public init(room: JID, name: String? = nil, autojoin: Bool = true, nick: String? = nil,
                password: String? = nil, extensions: Element? = nil) {
        self.room = room.bare
        self.name = name
        self.autojoin = autojoin
        self.nick = nick
        self.password = password
        self.extensions = extensions
    }

    /// A PubSub `<item id='room'>` carrying a `<conference/>`.
    public init?(item: Element) {
        guard let id = item["id"].flatMap({ try? JID($0) }), id.isBare, id.localpart != nil,
              let conference = item.firstChild(name: "conference", namespaceURI: Namespaces.bookmarks) else { return nil }
        room = id
        name = conference["name"]?.nilIfEmpty
        autojoin = conference["autojoin"] == "true" || conference["autojoin"] == "1"
        nick = conference.firstChild(name: "nick", namespaceURI: Namespaces.bookmarks)?.text.nilIfEmpty
        password = conference.firstChild(name: "password", namespaceURI: Namespaces.bookmarks)?.text
        extensions = conference.firstChild(name: "extensions", namespaceURI: Namespaces.bookmarks)
    }

    /// XEP-0048 `<conference jid=''/>`.
    init?(legacy conference: Element) {
        guard conference.matches(name: "conference", namespaceURI: Namespaces.legacyBookmarks),
              let jid = conference["jid"].flatMap({ try? JID($0) }), jid.localpart != nil else { return nil }
        room = jid.bare
        name = conference["name"]?.nilIfEmpty
        autojoin = conference["autojoin"] == "true" || conference["autojoin"] == "1"
        nick = conference.firstChild(name: "nick", namespaceURI: Namespaces.legacyBookmarks)?.text.nilIfEmpty
        password = conference.firstChild(name: "password", namespaceURI: Namespaces.legacyBookmarks)?.text
        extensions = nil
    }

    public var conference: Element {
        var conference = Element(name: "conference", namespaceURI: Namespaces.bookmarks)
        conference["name"] = name
        if autojoin { conference["autojoin"] = "true" }
        if let nick { conference.addChild(Element(name: "nick", namespaceURI: Namespaces.bookmarks, text: nick)) }
        if let password {
            conference.addChild(Element(name: "password", namespaceURI: Namespaces.bookmarks, text: password))
        }
        if let extensions { conference.addChild(extensions) }
        return conference
    }
}

/// XEP-0402 Bookmarks 2 in PEP, with a read-only XEP-0048 fallback.
public struct Bookmarks: Sendable {

    public enum Change: Sendable, Equatable {
        case published(Bookmark)
        case retracted(JID)
    }

    /// §4: advertise this to receive `Change`s.
    public static let notifyFeature = Namespaces.bookmarks + "+notify"

    public let client: XMPPClient

    public init(client: XMPPClient) {
        self.client = client
    }

    /// Every bookmark in the node; none when the node does not exist yet.
    public func fetch() async throws -> [Bookmark] {
        let pubsub = Element(name: "pubsub", namespaceURI: Namespaces.pubsub)
            .adding(Element(name: "items", namespaceURI: Namespaces.pubsub, attributes: ["node": Namespaces.bookmarks]))
        do {
            let reply = try await client.send(IQ(type: .get, payload: pubsub))
            return reply.payload?.firstChild(name: "items", namespaceURI: Namespaces.pubsub)?
                .childElements(name: "item", namespaceURI: Namespaces.pubsub)
                .compactMap(Bookmark.init(item:)) ?? []
        } catch let error as StanzaError where error.condition == .itemNotFound {
            return []
        }
    }

    /// Whether the server mirrors XEP-0048 into Bookmarks 2 (§5.3). Without
    /// it, older clients' bookmarks are only in private storage.
    public func isCompatible() async throws -> Bool {
        guard let account = await client.jid?.bare else { throw ClientError.notConnected }
        return try await client.discoInfo(account).supports(Namespaces.bookmarksCompat)
    }

    /// XEP-0048 bookmarks from private XML storage.
    public func fetchLegacy() async throws -> [Bookmark] {
        let query = Element(name: "query", namespaceURI: Namespaces.privateStorage)
            .adding(Element(name: "storage", namespaceURI: Namespaces.legacyBookmarks))
        let reply = try await client.send(IQ(type: .get, payload: query))
        return reply.payload?.firstChild(name: "storage", namespaceURI: Namespaces.legacyBookmarks)?
            .childElements(name: "conference", namespaceURI: Namespaces.legacyBookmarks)
            .compactMap(Bookmark.init(legacy:)) ?? []
    }

    /// §3.2: publishes (adds or replaces) one bookmark, with the node options
    /// that keep bookmarks private and every item kept.
    public func publish(_ bookmark: Bookmark) async throws {
        _ = try await client.send(IQ(type: .set, payload: Self.publish(bookmark)))
    }

    static func publish(_ bookmark: Bookmark) -> Element {
        var item = Element(name: "item", namespaceURI: Namespaces.pubsub, attributes: ["id": bookmark.room.description])
        item.addChild(bookmark.conference)
        let options = DataForm(type: .submit, fields: [
            .init(variable: "FORM_TYPE", type: "hidden", values: [Namespaces.publishOptions]),
            .init(variable: "pubsub#persist_items", values: ["true"]),
            .init(variable: "pubsub#max_items", values: ["max"]),
            .init(variable: "pubsub#send_last_published_item", values: ["never"]),
            .init(variable: "pubsub#access_model", values: ["whitelist"]),
        ])
        return Element(name: "pubsub", namespaceURI: Namespaces.pubsub)
            .adding(Element(name: "publish", namespaceURI: Namespaces.pubsub, attributes: ["node": Namespaces.bookmarks])
                .adding(item))
            .adding(Element(name: "publish-options", namespaceURI: Namespaces.pubsub).adding(options.element))
    }

    /// §3.4: removes a bookmark, notifying our other clients.
    public func retract(_ room: JID) async throws {
        let retract = Element(name: "retract", namespaceURI: Namespaces.pubsub,
                              attributes: ["node": Namespaces.bookmarks, "notify": "true"])
            .adding(Element(name: "item", namespaceURI: Namespaces.pubsub, attributes: ["id": room.bare.description]))
        _ = try await client.send(IQ(type: .set, payload: Element(name: "pubsub", namespaceURI: Namespaces.pubsub)
            .adding(retract)))
    }

    /// The bookmark changes in a PEP notification, or `nil` when the message
    /// is not one. Only notifications from our own account count; anyone
    /// else could otherwise make us join rooms.
    public static func changes(in message: Message, account: JID) -> [Change]? {
        guard let items = message.element.firstChild(name: "event", namespaceURI: Namespaces.pubsubEvent)?
                .firstChild(name: "items", namespaceURI: Namespaces.pubsubEvent),
              items["node"] == Namespaces.bookmarks else { return nil }
        guard message.from == nil || message.from == account.bare else { return [] }
        var changes: [Change] = []
        for child in items.elements where child.namespaceURI == Namespaces.pubsubEvent {
            switch child.name {
            case "item":
                if let bookmark = Bookmark(item: child) { changes.append(.published(bookmark)) }
            case "retract":
                if let room = child["id"].flatMap({ try? JID($0) }) { changes.append(.retracted(room.bare)) }
            default:
                break
            }
        }
        return changes
    }
}
