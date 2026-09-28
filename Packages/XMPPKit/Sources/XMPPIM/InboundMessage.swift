import Foundation
import XMPPCore
import XMPPXML

/// A message as the conversation sees it: carbons and archive results
/// unwrapped, direction and peer worked out, and the ids used for
/// deduplication collected.
public struct InboundMessage: Sendable, Hashable {

    public enum Source: Sendable, Hashable {
        /// Delivered to this session.
        case live
        /// A XEP-0280 copy of a message another of our sessions sent or received.
        case carbon
        /// A XEP-0313 result from the user's archive.
        case archive
    }

    /// The message itself, not the wrapper it arrived in.
    public let message: Message
    public let source: Source
    /// Sent by this account — from another device, or as recorded by the archive.
    public let isOutgoing: Bool
    /// The conversation this message belongs to: the other party's bare JID,
    /// or for a private message through a room the occupant JID.
    public let peer: JID
    /// The other party's full address, as the message gives it.
    public let counterpart: JID
    /// When the server says the message was sent; `nil` for "just now".
    public let timestamp: Date?
    /// The id in the account's own archive (XEP-0359 `stanza-id` by our bare
    /// JID, or the XEP-0313 result id). The strongest deduplication key.
    public let archiveID: String?

    public init(message: Message, source: Source, isOutgoing: Bool, peer: JID,
                timestamp: Date?, archiveID: String?, counterpart: JID? = nil) {
        self.message = message
        self.source = source
        self.isOutgoing = isOutgoing
        self.peer = peer
        self.counterpart = counterpart ?? peer
        self.timestamp = timestamp
        self.archiveID = archiveID
    }

    /// The same message as a private message through a room (XEP-0045
    /// §7.5): the conversation is with the occupant, `room@service/nick`,
    /// not with the room. `nil` when the other party has no nickname.
    public func throughRoom() -> InboundMessage? {
        guard counterpart.isFull, message.type != .groupchat else { return nil }
        return InboundMessage(message: message, source: source, isOutgoing: isOutgoing, peer: counterpart,
                              timestamp: timestamp, archiveID: archiveID, counterpart: counterpart)
    }

    /// The sender's id for this message: `origin-id`, else `id`.
    public var senderID: String? { message.originID ?? message.id }

    /// Unwraps and classifies a message delivered live to `account` (a full
    /// or bare JID). Returns `nil` for what is not a conversation message: a
    /// forged carbon, or one with no usable address.
    public init?(live outer: Message, account: JID) {
        let account = account.bare
        if let carbon = outer.element.elements.first(where: {
            $0.namespaceURI == Namespaces.carbons && ($0.name == "received" || $0.name == "sent")
        }) {
            // XEP-0280 §11: only our own server may send us carbons; anyone
            // else could inject "sent" messages into our history.
            guard outer.from == nil || outer.from == account else { return nil }
            guard let forwarded = carbon.firstChild(name: "forwarded", namespaceURI: Namespaces.forward),
                  let inner = forwarded.firstChild(name: "message", namespaceURI: Namespaces.client).flatMap(Message.init)
            else { return nil }
            let sent = carbon.name == "sent"
            guard let counterpart = sent ? inner.to : inner.from else { return nil }
            let stamp = forwarded.firstChild(name: "delay", namespaceURI: Namespaces.delay)?["stamp"]
                .flatMap(XMPPDateTime.parse) ?? inner.delayStamp
            // A note to self is ours whichever way the copy says it went.
            self.init(message: inner, source: .carbon, isOutgoing: sent || counterpart.bare == account,
                      peer: counterpart.bare,
                      timestamp: stamp, archiveID: inner.stanzaID(by: account), counterpart: counterpart)
            return
        }

        guard let from = outer.from else { return nil }
        // A note to self comes back from our own address: one we sent, here
        // or on another device, not a reply.
        self.init(message: outer, source: .live, isOutgoing: from.bare == account, peer: from.bare,
                  timestamp: outer.delayStamp, archiveID: outer.stanzaID(by: account), counterpart: from)
    }

    /// Classifies a message taken from the account's own archive.
    public init?(archived inner: Message, id: String, timestamp: Date?, account: JID) {
        let account = account.bare
        let outgoing = inner.from?.bare == account
        guard let counterpart = outgoing ? inner.to : inner.from else { return nil }
        self.init(message: inner, source: .archive, isOutgoing: outgoing, peer: counterpart.bare,
                  timestamp: timestamp ?? inner.delayStamp, archiveID: id, counterpart: counterpart)
    }
}
