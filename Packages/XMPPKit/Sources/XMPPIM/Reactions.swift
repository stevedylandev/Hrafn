import Foundation
import XMPPCore
import XMPPXML

extension Namespaces {
    /// XEP-0444.
    public static let reactions = "urn:xmpp:reactions:0"
}

/// XEP-0444: one sender's complete set of reactions to one message. Each
/// new set replaces the sender's previous one; an empty set removes them all.
public struct MessageReactions: Sendable, Hashable {
    /// The message reacted to: its sender's id in a one-to-one chat, the
    /// room's `stanza-id` in a group chat (§4).
    public var id: String
    public var emojis: [String]

    public init(id: String, emojis: [String]) {
        self.id = id
        self.emojis = emojis
    }

    /// Whether `reaction` is one emoji, as §3 asks. Anything else (text,
    /// several emojis in one element) is ignored on receipt.
    public static func isEmoji(_ reaction: String) -> Bool {
        guard reaction.count == 1, let character = reaction.first else { return false }
        let scalars = character.unicodeScalars
        // Digits, `#` and `*` are "emoji" on their own only as keycaps.
        if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
        return scalars.count > 1 && scalars.first?.properties.isEmoji == true
    }
}

extension Message {

    /// XEP-0444 `<reactions/>`, with duplicates and anything that is not a
    /// single emoji dropped.
    public var reactions: MessageReactions? {
        guard let element = element.firstChild(name: "reactions", namespaceURI: Namespaces.reactions),
              let id = element["id"], !id.isEmpty else { return nil }
        var seen: Set<String> = []
        let emojis = element.childElements(name: "reaction", namespaceURI: Namespaces.reactions)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { MessageReactions.isEmoji($0) && seen.insert($0).inserted }
        return MessageReactions(id: id, emojis: emojis)
    }

    /// Our full set of reactions to `messageID`, replacing any earlier set.
    /// No body: clients that do not know reactions show nothing, which is
    /// what they would show for a reaction anyway. Stored (§5.2) so our
    /// other devices and an offline recipient see it.
    public static func reactions(_ emojis: [String], to messageID: String, peer: JID, type: Kind = .chat,
                                 id: String = StanzaID.make()) -> Message {
        var message = Message(type: type, id: id, to: type == .groupchat ? peer.bare : peer)
        var reactions = Element(name: "reactions", namespaceURI: Namespaces.reactions, attributes: ["id": messageID])
        for emoji in emojis {
            reactions.addChild(Element(name: "reaction", namespaceURI: Namespaces.reactions, text: emoji))
        }
        message.element.addChild(reactions)
        message.element.addChild(Element(name: "store", namespaceURI: Namespaces.hints))
        message.element.addChild(Element(name: "origin-id", namespaceURI: Namespaces.stableIDs, attributes: ["id": id]))
        return message
    }
}
