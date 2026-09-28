import CryptoKit
import Foundation
import XMPPClient
import XMPPCore
import XMPPXML

extension Namespaces {
    /// XEP-0084 data node and payload.
    public static let avatarData = "urn:xmpp:avatar:data"
    /// XEP-0084 metadata node and payload.
    public static let avatarMetadata = "urn:xmpp:avatar:metadata"
    /// XEP-0054.
    public static let vcardTemp = "vcard-temp"
    /// XEP-0153 presence element.
    public static let vcardUpdate = "vcard-temp:x:update"
    /// XEP-0398: the server keeps the vCard photo and the PEP avatar in step.
    public static let pepVCardConversion = "urn:xmpp:pep-vcard-conversion:0"
    /// XEP-0172.
    public static let nick = "http://jabber.org/protocol/nick"
}

/// One advertised version of an avatar (XEP-0084 §4.2 `<info/>`).
public struct AvatarInfo: Sendable, Hashable {
    /// Hex SHA-1 of the image bytes; also the data item's id.
    public var id: String
    public var bytes: Int
    public var type: String
    public var width: Int?
    public var height: Int?
    /// Set when the image is hosted elsewhere rather than in the data node.
    public var url: URL?

    public init(id: String, bytes: Int, type: String, width: Int? = nil, height: Int? = nil, url: URL? = nil) {
        self.id = id
        self.bytes = bytes
        self.type = type
        self.width = width
        self.height = height
        self.url = url
    }

    init?(_ info: Element) {
        guard let id = info["id"]?.lowercased(), Avatars.isSHA1(id), let type = info["type"] else { return nil }
        self.id = id
        bytes = info["bytes"].flatMap { Int($0) } ?? 0
        self.type = type
        width = info["width"].flatMap { Int($0) }
        height = info["height"].flatMap { Int($0) }
        url = info["url"].flatMap(URL.init(string:))
    }

    var element: Element {
        var info = Element(name: "info", namespaceURI: Namespaces.avatarMetadata,
                           attributes: ["id": id, "bytes": String(bytes), "type": type])
        info["width"] = width.map(String.init)
        info["height"] = height.map(String.init)
        info["url"] = url?.absoluteString
        return info
    }
}

/// XEP-0084 User Avatar in PEP.
public struct Avatars: Sendable {

    /// A contact's (or our own) metadata changed: the new avatar, or `nil`
    /// when it was removed.
    public struct Change: Sendable, Hashable {
        public var jid: JID
        public var avatar: AvatarInfo?
    }

    public enum Failure: Error, Sendable, Equatable {
        /// The data does not hash to the id it was published under.
        case hashMismatch
        case notFound
    }

    /// §4.3: advertise this to be sent metadata changes.
    public static let notifyFeature = Namespaces.avatarMetadata + "+notify"

    public let client: XMPPClient

    public init(client: XMPPClient) {
        self.client = client
    }

    /// The avatar `jid` advertises now: `nil` when there is none (no node,
    /// or an empty `<metadata/>`). Prefers PNG, which every publisher must
    /// offer (§4.2.1).
    public func metadata(of jid: JID) async throws -> AvatarInfo? {
        let items = try await fetchItems(of: jid, node: Namespaces.avatarMetadata, id: nil, max: 1)
        guard let metadata = items.last?.firstChild(name: "metadata", namespaceURI: Namespaces.avatarMetadata) else {
            return nil
        }
        return Self.preferred(in: metadata)
    }

    /// The image for `id`, checked against its hash.
    public func data(of jid: JID, id: String) async throws -> Data {
        let items = try await fetchItems(of: jid, node: Namespaces.avatarData, id: id, max: nil)
        guard let item = items.first(where: { $0["id"]?.lowercased() == id.lowercased() }),
              let payload = item.firstChild(name: "data", namespaceURI: Namespaces.avatarData),
              let data = Data(base64Encoded: payload.text, options: .ignoreUnknownCharacters) else {
            throw Failure.notFound
        }
        guard Self.sha1(data) == id.lowercased() else { throw Failure.hashMismatch }
        return data
    }

    /// §4.1–4.2: publishes the data, then the metadata that points at it.
    @discardableResult
    public func publish(_ data: Data, type: String, width: Int?, height: Int?) async throws -> AvatarInfo {
        let info = AvatarInfo(id: Self.sha1(data), bytes: data.count, type: type, width: width, height: height)
        _ = try await client.send(IQ(type: .set, payload: Self.publishData(data, id: info.id)))
        _ = try await client.send(IQ(type: .set, payload: Self.publishMetadata(info)))
        return info
    }

    /// §4.6: an empty `<metadata/>` tells contacts there is no avatar.
    public func disable() async throws {
        _ = try await client.send(IQ(type: .set, payload: Self.publishMetadata(nil)))
    }

    static func publishData(_ data: Data, id: String) -> Element {
        let item = Element(name: "item", namespaceURI: Namespaces.pubsub, attributes: ["id": id])
            .adding(Element(name: "data", namespaceURI: Namespaces.avatarData, text: data.base64EncodedString()))
        return Element(name: "pubsub", namespaceURI: Namespaces.pubsub)
            .adding(Element(name: "publish", namespaceURI: Namespaces.pubsub, attributes: ["node": Namespaces.avatarData])
                .adding(item))
    }

    static func publishMetadata(_ info: AvatarInfo?) -> Element {
        var metadata = Element(name: "metadata", namespaceURI: Namespaces.avatarMetadata)
        if let info { metadata.addChild(info.element) }
        var item = Element(name: "item", namespaceURI: Namespaces.pubsub)
        item["id"] = info?.id ?? "current"
        item.addChild(metadata)
        return Element(name: "pubsub", namespaceURI: Namespaces.pubsub)
            .adding(Element(name: "publish", namespaceURI: Namespaces.pubsub,
                            attributes: ["node": Namespaces.avatarMetadata]).adding(item))
    }

    /// A metadata notification, or `nil` when the message is not one. A
    /// notification without `from` comes from our own account.
    public static func change(in message: Message, account: JID) -> Change? {
        guard let items = message.element.firstChild(name: "event", namespaceURI: Namespaces.pubsubEvent)?
                .firstChild(name: "items", namespaceURI: Namespaces.pubsubEvent),
              items["node"] == Namespaces.avatarMetadata else { return nil }
        // PEP events come from the owner's bare JID (XEP-0163 §4.3.2).
        let from = message.from ?? account.bare
        guard from.isBare else { return nil }
        if items.firstChild(name: "retract", namespaceURI: Namespaces.pubsubEvent) != nil
            && items.firstChild(name: "item", namespaceURI: Namespaces.pubsubEvent) == nil {
            return Change(jid: from, avatar: nil)
        }
        guard let metadata = items.childElements(name: "item", namespaceURI: Namespaces.pubsubEvent).last?
            .firstChild(name: "metadata", namespaceURI: Namespaces.avatarMetadata) else { return nil }
        return Change(jid: from, avatar: preferred(in: metadata))
    }

    static func preferred(in metadata: Element) -> AvatarInfo? {
        let infos = metadata.childElements(name: "info", namespaceURI: Namespaces.avatarMetadata).compactMap(AvatarInfo.init)
        // Only what the data node holds; `url` avatars need an HTTP fetch
        // nobody publishes without the PNG anyway.
        let local = infos.filter { $0.url == nil }
        return local.first { $0.type == "image/png" } ?? local.first
    }

    private func fetchItems(of jid: JID, node: String, id: String?, max: Int?) async throws -> [Element] {
        var items = Element(name: "items", namespaceURI: Namespaces.pubsub, attributes: ["node": node])
        items["max_items"] = max.map(String.init)
        if let id { items.addChild(Element(name: "item", namespaceURI: Namespaces.pubsub, attributes: ["id": id])) }
        do {
            let reply = try await client.send(IQ(type: .get, to: jid.bare,
                                                 payload: Element(name: "pubsub", namespaceURI: Namespaces.pubsub)
                                                    .adding(items)))
            return reply.payload?.firstChild(name: "items", namespaceURI: Namespaces.pubsub)?
                .childElements(name: "item", namespaceURI: Namespaces.pubsub) ?? []
        } catch let error as StanzaError where error.condition == .itemNotFound {
            return []
        }
    }

    public static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isSHA1(_ id: String) -> Bool {
        id.utf8.count == 40 && id.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
}

/// XEP-0153 / XEP-0054: the older avatar, a photo in the vCard with its hash
/// in presence. Read for contacts whose clients or servers have no PEP
/// avatar; written only when the server does not convert (XEP-0398).
public struct VCardAvatars: Sendable {

    /// What a presence says about the sender's vCard photo.
    public enum Advertised: Sendable, Hashable {
        /// No `<x/>`: the sender does not take part, or is not ready (§4.1).
        case unknown
        /// An empty `<photo/>`: no avatar.
        case none
        case photo(sha1: String)
        /// A `<photo/>` that is not a SHA-1 hash: something changed, but
        /// the hash does not say what. Prosody sends its PEP item id
        /// (`current`) once an avatar is removed. Look at the vCard again.
        case unverified
    }

    public let client: XMPPClient

    public init(client: XMPPClient) {
        self.client = client
    }

    public static func advertised(in presence: Presence) -> Advertised {
        guard let update = presence.element.firstChild(name: "x", namespaceURI: Namespaces.vcardUpdate) else {
            return .unknown
        }
        // §4.1: `<x/>` without `<photo/>` means "not ready to advertise".
        guard let photo = update.firstChild(name: "photo", namespaceURI: Namespaces.vcardUpdate) else { return .unknown }
        let hash = photo.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if hash.isEmpty { return .none }
        return Avatars.isSHA1(hash) ? .photo(sha1: hash) : .unverified
    }

    /// The photo in `jid`'s vCard, `nil` when there is none. A room
    /// occupant's JID (`room@service/nick`) reaches the occupant's own vCard:
    /// the room passes the request on to their bare JID (XEP-0045 §7.8.2 for
    /// IQs; both Prosody and ejabberd do this for vcard-temp).
    public func photo(of jid: JID) async throws -> (data: Data, type: String)? {
        guard let vcard = try await vcard(of: jid) else { return nil }
        return Self.photo(in: vcard)
    }

    static func photo(in vcard: Element) -> (data: Data, type: String)? {
        guard let photo = vcard.firstChild(name: "PHOTO", namespaceURI: Namespaces.vcardTemp),
              let binval = photo.firstChild(name: "BINVAL", namespaceURI: Namespaces.vcardTemp)?.text,
              let data = Data(base64Encoded: binval, options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
        let type = photo.firstChild(name: "TYPE", namespaceURI: Namespaces.vcardTemp)?.text
        return (data, type?.nilIfBlank ?? "image/png")
    }

    /// Replaces (or with `nil` removes) the photo in our vCard, keeping
    /// every other field (vcard-temp is read-modify-write).
    public func setPhoto(_ data: Data?, type: String) async throws {
        var vcard = try await vcard(of: nil) ?? Element(name: "vCard", namespaceURI: Namespaces.vcardTemp)
        vcard.removeChildren(name: "PHOTO", namespaceURI: Namespaces.vcardTemp)
        if let data {
            vcard.addChild(Element(name: "PHOTO", namespaceURI: Namespaces.vcardTemp)
                .adding(Element(name: "TYPE", namespaceURI: Namespaces.vcardTemp, text: type))
                .adding(Element(name: "BINVAL", namespaceURI: Namespaces.vcardTemp, text: data.base64EncodedString())))
        }
        _ = try await client.send(IQ(type: .set, payload: vcard))
    }

    private func vcard(of jid: JID?) async throws -> Element? {
        do {
            let reply = try await client.send(IQ(type: .get, to: jid,
                                                 payload: Element(name: "vCard", namespaceURI: Namespaces.vcardTemp)))
            return reply.payload?.matches(name: "vCard", namespaceURI: Namespaces.vcardTemp) == true ? reply.payload : nil
        } catch let error as StanzaError where error.condition == .itemNotFound
                    || error.condition == .serviceUnavailable {
            return nil
        }
    }
}

/// XEP-0172 User Nickname: the name a person gives themselves, for contacts
/// who have not named them in the roster.
public struct Nicknames: Sendable {

    public struct Change: Sendable, Hashable {
        public var jid: JID
        public var nick: String?
    }

    public static let notifyFeature = Namespaces.nick + "+notify"

    public let client: XMPPClient

    public init(client: XMPPClient) {
        self.client = client
    }

    /// Publishes our nickname; an empty `<nick/>` clears it.
    public func publish(_ nick: String?) async throws {
        let item = Element(name: "item", namespaceURI: Namespaces.pubsub, attributes: ["id": "current"])
            .adding(Element(name: "nick", namespaceURI: Namespaces.nick, text: nick?.nilIfBlank ?? ""))
        _ = try await client.send(IQ(type: .set, payload: Element(name: "pubsub", namespaceURI: Namespaces.pubsub)
            .adding(Element(name: "publish", namespaceURI: Namespaces.pubsub, attributes: ["node": Namespaces.nick])
                .adding(item))))
    }

    /// `jid`'s published nickname (ours with `nil`).
    public func fetch(of jid: JID?) async throws -> String? {
        let items = Element(name: "items", namespaceURI: Namespaces.pubsub, attributes: ["node": Namespaces.nick, "max_items": "1"])
        do {
            let reply = try await client.send(IQ(type: .get, to: jid,
                                                 payload: Element(name: "pubsub", namespaceURI: Namespaces.pubsub)
                                                    .adding(items)))
            return reply.payload?.firstChild(name: "items", namespaceURI: Namespaces.pubsub)?
                .childElements(name: "item", namespaceURI: Namespaces.pubsub).last?
                .firstChild(name: "nick", namespaceURI: Namespaces.nick)?.text.nilIfBlank
        } catch let error as StanzaError where error.condition == .itemNotFound {
            return nil
        }
    }

    public static func change(in message: Message, account: JID) -> Change? {
        guard let items = message.element.firstChild(name: "event", namespaceURI: Namespaces.pubsubEvent)?
                .firstChild(name: "items", namespaceURI: Namespaces.pubsubEvent),
              items["node"] == Namespaces.nick else { return nil }
        let from = message.from ?? account.bare
        guard from.isBare else { return nil }
        let nick = items.childElements(name: "item", namespaceURI: Namespaces.pubsubEvent).last?
            .firstChild(name: "nick", namespaceURI: Namespaces.nick)?.text.nilIfBlank
        return Change(jid: from, nick: nick)
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
