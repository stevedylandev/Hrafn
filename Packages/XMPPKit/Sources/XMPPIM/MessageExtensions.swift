import Foundation
import XMPPCore
import XMPPXML

/// XEP-0085 chat states.
public enum ChatState: String, Sendable, Hashable, CaseIterable {
    case active, composing, paused, inactive, gone
}

// MARK: - Reading

extension Message {

    /// XEP-0359 `<origin-id/>`: the sender's own id, stable across carbons,
    /// archives and MUC reflections.
    public var originID: String? {
        element.firstChild(name: "origin-id", namespaceURI: Namespaces.stableIDs)?["id"]
    }

    /// XEP-0359 `<stanza-id/>` assigned by `by`. Only trust one whose `by` is an
    /// entity that is known to strip forgeries — our own bare JID, or a room
    /// that advertises `urn:xmpp:sid:0` — which the caller decides.
    public func stanzaID(by: JID) -> String? {
        element.childElements(name: "stanza-id", namespaceURI: Namespaces.stableIDs)
            .first { $0["by"].flatMap { try? JID($0) } == by }?["id"]
    }

    /// XEP-0203 delay stamp.
    public var delayStamp: Date? {
        element.firstChild(name: "delay", namespaceURI: Namespaces.delay)?["stamp"].flatMap(XMPPDateTime.parse)
    }

    /// XEP-0184: the sender asks for a receipt.
    public var requestsReceipt: Bool {
        element.firstChild(name: "request", namespaceURI: Namespaces.receipts) != nil
    }

    /// XEP-0184: this is a receipt for the message with this id.
    public var receiptID: String? {
        element.firstChild(name: "received", namespaceURI: Namespaces.receipts)?["id"]
    }

    public var chatState: ChatState? {
        for child in element.elements where child.namespaceURI == Namespaces.chatStates {
            if let state = ChatState(rawValue: child.name) { return state }
        }
        return nil
    }

    /// XEP-0333: the sender wants displayed markers.
    public var isMarkable: Bool {
        element.firstChild(name: "markable", namespaceURI: Namespaces.chatMarkers) != nil
    }

    /// XEP-0333: every message up to and including this id was displayed.
    public var displayedID: String? {
        element.firstChild(name: "displayed", namespaceURI: Namespaces.chatMarkers)?["id"]
    }

    /// XEP-0308: this message replaces the one with this id.
    public var replacedID: String? {
        element.firstChild(name: "replace", namespaceURI: Namespaces.correction)?["id"]
    }

    /// XEP-0424: this message retracts the one with this id.
    public var retractedID: String? {
        element.firstChild(name: "retract", namespaceURI: Namespaces.retraction)?["id"]
    }

    /// XEP-0428: the body is only a fallback for a client that does not
    /// understand the extension named `namespace`.
    public func isFallback(for namespace: String) -> Bool {
        element.childElements(name: "fallback", namespaceURI: Namespaces.fallback).contains { $0["for"] == namespace }
    }

    /// XEP-0334 `<no-store/>` / `<no-permanent-store/>`.
    public var isTransient: Bool {
        element.firstChild(name: "no-store", namespaceURI: Namespaces.hints) != nil
            || element.firstChild(name: "no-permanent-store", namespaceURI: Namespaces.hints) != nil
    }
}

// MARK: - Building

extension Message {

    /// A chat message as Hrafn sends it: `origin-id` equal to `id` (so every
    /// copy of the message carries the same id), an `<active/>` chat state, a
    /// receipt request and a displayed-marker request.
    public static func chat(to: JID, body: String, id: String = StanzaID.make()) -> Message {
        var message = Message(type: .chat, id: id, to: to, body: body)
        message.element.addChild(Element(name: "active", namespaceURI: Namespaces.chatStates))
        message.element.addChild(Element(name: "request", namespaceURI: Namespaces.receipts))
        message.element.addChild(Element(name: "markable", namespaceURI: Namespaces.chatMarkers))
        message.element.addChild(Element(name: "origin-id", namespaceURI: Namespaces.stableIDs, attributes: ["id": id]))
        return message
    }

    /// XEP-0308. `originalID` is the `id` of the first version, never of an
    /// earlier correction (§5).
    public static func correction(of originalID: String, to: JID, body: String,
                                  id: String = StanzaID.make()) -> Message {
        var message = chat(to: to, body: body, id: id)
        message.element.addChild(Element(name: "replace", namespaceURI: Namespaces.correction,
                                         attributes: ["id": originalID]))
        return message
    }

    /// XEP-0424, with the XEP-0428 fallback body for clients that do not know it.
    public static func retraction(of originID: String, to: JID, id: String = StanzaID.make()) -> Message {
        var message = Message(type: .chat, id: id, to: to,
                              body: "This person attempted to retract a previous message, but it's unsupported by your client.")
        message.element.addChild(Element(name: "retract", namespaceURI: Namespaces.retraction,
                                         attributes: ["id": originID]))
        message.element.addChild(Element(name: "fallback", namespaceURI: Namespaces.fallback,
                                         attributes: ["for": Namespaces.retraction]))
        message.element.addChild(Element(name: "store", namespaceURI: Namespaces.hints))
        message.element.addChild(Element(name: "origin-id", namespaceURI: Namespaces.stableIDs, attributes: ["id": id]))
        return message
    }

    /// A standalone chat-state notification; not worth archiving (XEP-0085 §5.5).
    public static func chatState(_ state: ChatState, to: JID) -> Message {
        var message = Message(type: .chat, id: nil, to: to)
        message.element.addChild(Element(name: state.rawValue, namespaceURI: Namespaces.chatStates))
        message.element.addChild(Element(name: "no-store", namespaceURI: Namespaces.hints))
        return message
    }

    /// XEP-0184 receipt. Stored, so a sender who is offline still learns of it.
    public static func receipt(for id: String, to: JID) -> Message {
        var message = Message(type: .chat, id: StanzaID.make(), to: to)
        message.element.addChild(Element(name: "received", namespaceURI: Namespaces.receipts, attributes: ["id": id]))
        message.element.addChild(Element(name: "store", namespaceURI: Namespaces.hints))
        return message
    }

    /// XEP-0333 displayed marker, stored so our other devices (via MAM) and the
    /// sender see it later.
    public static func displayed(_ id: String, to: JID) -> Message {
        var message = Message(type: .chat, id: StanzaID.make(), to: to)
        message.element.addChild(Element(name: "displayed", namespaceURI: Namespaces.chatMarkers, attributes: ["id": id]))
        message.element.addChild(Element(name: "store", namespaceURI: Namespaces.hints))
        return message
    }
}
