import Foundation
import XMPPClient
import XMPPCore
import XMPPXML

extension Namespaces {
    /// XEP-0490: the PEP node and the payload namespace.
    public static let displayedSync = "urn:xmpp:mds:displayed:0"
}

/// XEP-0490 Message Displayed Synchronization: how far the user has read each
/// conversation, kept in PEP so every one of their devices agrees.
public struct DisplayedSync: Sendable {

    /// One conversation's read position.
    public struct Marker: Sendable, Hashable {
        /// The conversation: a contact's or a room's bare JID (the item id).
        public var conversation: JID
        /// The `stanza-id` of the last message displayed.
        public var stanzaID: String
        /// Who assigned it: our own account for a chat, the room for a group chat.
        public var by: JID

        public init(conversation: JID, stanzaID: String, by: JID) {
            self.conversation = conversation.bare
            self.stanzaID = stanzaID
            self.by = by.bare
        }

        /// A PubSub `<item id='conversation'>` carrying a `<displayed/>`.
        public init?(item: Element) {
            guard let conversation = item["id"].flatMap({ try? JID($0) }), conversation.isBare,
                  let stanzaID = item.firstChild(name: "displayed", namespaceURI: Namespaces.displayedSync)?
                    .firstChild(name: "stanza-id", namespaceURI: Namespaces.stableIDs),
                  let id = stanzaID["id"], !id.isEmpty,
                  let by = stanzaID["by"].flatMap({ try? JID($0) }) else { return nil }
            self.init(conversation: conversation, stanzaID: id, by: by)
        }

        /// Only ids assigned by our own archive (a chat) or by the room
        /// itself (a group chat) name a message we can find.
        public func isValid(account: JID) -> Bool {
            by == account.bare || by == conversation
        }

        var item: Element {
            Element(name: "item", namespaceURI: Namespaces.pubsub, attributes: ["id": conversation.description])
                .adding(Element(name: "displayed", namespaceURI: Namespaces.displayedSync)
                    .adding(Element(name: "stanza-id", namespaceURI: Namespaces.stableIDs,
                                    attributes: ["id": stanzaID, "by": by.description])))
        }
    }

    /// §4: advertise this to receive other devices' markers as they move.
    public static let notifyFeature = Namespaces.displayedSync + "+notify"

    public let client: XMPPClient

    public init(client: XMPPClient) {
        self.client = client
    }

    /// Every conversation's marker; none when the node does not exist yet.
    public func fetch() async throws -> [Marker] {
        guard let account = await client.jid?.bare else { throw ClientError.notConnected }
        let pubsub = Element(name: "pubsub", namespaceURI: Namespaces.pubsub)
            .adding(Element(name: "items", namespaceURI: Namespaces.pubsub, attributes: ["node": Namespaces.displayedSync]))
        do {
            let reply = try await client.send(IQ(type: .get, payload: pubsub))
            return reply.payload?.firstChild(name: "items", namespaceURI: Namespaces.pubsub)?
                .childElements(name: "item", namespaceURI: Namespaces.pubsub)
                .compactMap(Marker.init(item:))
                .filter { $0.isValid(account: account) } ?? []
        } catch let error as StanzaError where error.condition == .itemNotFound {
            return []
        }
    }

    /// §3: moves one conversation's marker, with the node options that keep
    /// it private and one item per conversation.
    public func publish(_ marker: Marker) async throws {
        _ = try await client.send(IQ(type: .set, payload: Self.publish(marker)))
    }

    static func publish(_ marker: Marker) -> Element {
        let options = DataForm(type: .submit, fields: [
            .init(variable: "FORM_TYPE", type: "hidden", values: [Namespaces.publishOptions]),
            .init(variable: "pubsub#persist_items", values: ["true"]),
            .init(variable: "pubsub#max_items", values: ["max"]),
            .init(variable: "pubsub#send_last_published_item", values: ["never"]),
            .init(variable: "pubsub#access_model", values: ["whitelist"]),
        ])
        return Element(name: "pubsub", namespaceURI: Namespaces.pubsub)
            .adding(Element(name: "publish", namespaceURI: Namespaces.pubsub, attributes: ["node": Namespaces.displayedSync])
                .adding(marker.item))
            .adding(Element(name: "publish-options", namespaceURI: Namespaces.pubsub).adding(options.element))
    }

    /// The markers in a PEP notification, or `nil` when the message is not
    /// one. Only our own account's notifications count.
    public static func changes(in message: Message, account: JID) -> [Marker]? {
        guard let items = message.element.firstChild(name: "event", namespaceURI: Namespaces.pubsubEvent)?
                .firstChild(name: "items", namespaceURI: Namespaces.pubsubEvent),
              items["node"] == Namespaces.displayedSync else { return nil }
        guard message.from == nil || message.from == account.bare else { return [] }
        return items.childElements(name: "item", namespaceURI: Namespaces.pubsubEvent)
            .compactMap(Marker.init(item:))
            .filter { $0.isValid(account: account) }
    }
}
