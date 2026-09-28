import Foundation
import XMPPClient
import XMPPCore
import XMPPXML

extension Namespaces {
    /// XEP-0425 0.3 and later.
    public static let moderation = "urn:xmpp:message-moderate:1"
    /// XEP-0425 0.2, still all Prosody's mod_muc_moderation offers.
    public static let moderationLegacy = "urn:xmpp:message-moderate:0"
    /// XEP-0424 0.3, which XEP-0425 0.2 builds on.
    public static let retractionLegacy = "urn:xmpp:message-retract:0"
    /// XEP-0422, the wrapper XEP-0425 0.2 uses.
    public static let fastening = "urn:xmpp:fasten:0"
}

extension RoomInfo {
    /// Which XEP-0425 version the room speaks, newest first; `nil` if none.
    public var moderationNamespace: String? {
        if features.contains(Namespaces.moderation) { return Namespaces.moderation }
        if features.contains(Namespaces.moderationLegacy) { return Namespaces.moderationLegacy }
        return nil
    }
}

/// XEP-0425: a room moderator took an occupant's message down. The room
/// announces it, and its archive keeps a tombstone in place of the message.
public struct Moderation: Sendable, Hashable {
    /// The room's `stanza-id` for the message taken down.
    public var target: String
    /// The moderator's nickname, when the room says.
    public var moderator: String?
    public var reason: String?

    public init(target: String, moderator: String?, reason: String?) {
        self.target = target
        self.moderator = moderator
        self.reason = reason
    }

    /// The room's announcement, in either version. Only the room itself
    /// (its bare JID) may send one: an occupant could otherwise take down
    /// anyone's message.
    public init?(_ message: Message, room: JID) {
        guard message.type == .groupchat, let from = message.from, from == room.bare else { return nil }
        let element = message.element
        // 0.3: <retract id='…' xmlns='…retract:1'><moderated by='…' xmlns='…moderate:1'/><reason/></retract>
        if let retract = element.firstChild(name: "retract", namespaceURI: Namespaces.retraction),
           let id = retract["id"],
           let moderated = retract.firstChild(name: "moderated", namespaceURI: Namespaces.moderation) {
            self.init(target: id, moderator: Self.nick(moderated["by"]), reason: Self.reason(in: retract))
            return
        }
        // 0.2: <apply-to id='…' xmlns='…fasten:0'><moderated by='…'><retract/><reason/></moderated></apply-to>
        if let applyTo = element.firstChild(name: "apply-to", namespaceURI: Namespaces.fastening),
           let id = applyTo["id"],
           let moderated = applyTo.firstChild(name: "moderated", namespaceURI: Namespaces.moderationLegacy),
           moderated.firstChild(name: "retract", namespaceURI: Namespaces.retractionLegacy) != nil {
            self.init(target: id, moderator: Self.nick(moderated["by"]),
                      reason: moderated.firstChild(name: "reason", namespaceURI: Namespaces.moderationLegacy)?.text.nilIfBlank)
            return
        }
        return nil
    }

    /// What an archive keeps in place of a moderated message: who and why.
    /// The target is the archived message's own id.
    public static func tombstone(in message: Message) -> (moderator: String?, reason: String?)? {
        let element = message.element
        if let retracted = element.firstChild(name: "retracted", namespaceURI: Namespaces.retraction),
           let moderated = retracted.firstChild(name: "moderated", namespaceURI: Namespaces.moderation) {
            return (nick(moderated["by"]), reason(in: retracted))
        }
        if let moderated = element.firstChild(name: "moderated", namespaceURI: Namespaces.moderationLegacy),
           moderated.firstChild(name: "retracted", namespaceURI: Namespaces.retractionLegacy) != nil {
            return (nick(moderated["by"]),
                    moderated.firstChild(name: "reason", namespaceURI: Namespaces.moderationLegacy)?.text.nilIfBlank)
        }
        return nil
    }

    /// 0.3's `<reason/>` sits in `<retract/>`: the XEP's example leaves it in
    /// the retraction namespace, ejabberd puts it in the moderation one.
    private static func reason(in element: Element) -> String? {
        (element.firstChild(name: "reason", namespaceURI: Namespaces.retraction)
            ?? element.firstChild(name: "reason", namespaceURI: Namespaces.moderation))?.text.nilIfBlank
    }

    /// `by` is the moderator's occupant JID.
    private static func nick(_ by: String?) -> String? {
        by.flatMap { try? JID($0) }?.resourcepart
    }

    /// The request a moderator sends the room, in the version it speaks
    /// (`namespace` from `RoomInfo.moderationNamespace`).
    public static func request(_ target: String, in room: JID, reason: String?, namespace: String) -> IQ {
        if namespace == Namespaces.moderationLegacy {
            var moderate = Element(name: "moderate", namespaceURI: Namespaces.moderationLegacy)
                .adding(Element(name: "retract", namespaceURI: Namespaces.retractionLegacy))
            if let reason { moderate.addChild(Element(name: "reason", namespaceURI: Namespaces.moderationLegacy, text: reason)) }
            let applyTo = Element(name: "apply-to", namespaceURI: Namespaces.fastening, attributes: ["id": target])
                .adding(moderate)
            return IQ(type: .set, to: room.bare, payload: applyTo)
        }
        var moderate = Element(name: "moderate", namespaceURI: Namespaces.moderation, attributes: ["id": target])
            .adding(Element(name: "retract", namespaceURI: Namespaces.retraction))
        if let reason { moderate.addChild(Element(name: "reason", namespaceURI: Namespaces.moderation, text: reason)) }
        return IQ(type: .set, to: room.bare, payload: moderate)
    }
}

extension MultiUserChat {
    /// XEP-0425: asks the room to take down the message it knows as
    /// `stanzaID`. Needs the moderator role; the room answers `forbidden`
    /// otherwise, and `feature-not-implemented` without support.
    public func moderate(_ stanzaID: String, in room: JID, reason: String? = nil, info: RoomInfo) async throws {
        guard let namespace = info.moderationNamespace else { throw StanzaError(.featureNotImplemented) }
        _ = try await client.send(Moderation.request(stanzaID, in: room, reason: reason, namespace: namespace))
    }
}
