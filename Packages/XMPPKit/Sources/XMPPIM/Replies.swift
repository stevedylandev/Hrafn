import Foundation
import XMPPCore
import XMPPXML

extension Namespaces {
    /// XEP-0461.
    public static let reply = "urn:xmpp:reply:0"
}

/// XEP-0461: the message this one answers.
public struct MessageReply: Sendable, Hashable {
    /// The original's id: its sender's id in a one-to-one chat, the room's
    /// `stanza-id` in a group chat.
    public var id: String
    /// Who wrote the original (a bare JID in a chat, an occupant JID in a
    /// room), when the sender says.
    public var to: JID?

    public init(id: String, to: JID?) {
        self.id = id
        self.to = to
    }
}

extension Message {

    public var reply: MessageReply? {
        guard let element = element.firstChild(name: "reply", namespaceURI: Namespaces.reply),
              let id = element["id"], !id.isEmpty else { return nil }
        return MessageReply(id: id, to: element["to"].flatMap { try? JID($0) })
    }

    /// The body with the XEP-0428 fallback ranges for `namespace` cut out,
    /// and the text that was cut. Ranges count Unicode code points (§4 of
    /// XEP-0428, XEP-0426). Only ranged fallbacks are removed: a fallback
    /// without a range means the whole body, which a reply cannot be.
    public func body(strippingFallbackFor namespace: String) -> (body: String, fallback: String)? {
        guard let body else { return nil }
        let scalars = Array(body.unicodeScalars)
        var ranges: [Range<Int>] = []
        for fallback in element.childElements(name: "fallback", namespaceURI: Namespaces.fallback)
        where fallback["for"] == namespace {
            for range in fallback.childElements(name: "body", namespaceURI: Namespaces.fallback) {
                guard let start = range["start"].flatMap(Int.init), let end = range["end"].flatMap(Int.init),
                      start >= 0, start < end, end <= scalars.count else { continue }
                ranges.append(start..<end)
            }
        }
        guard !ranges.isEmpty else { return (body, "") }
        var kept = String.UnicodeScalarView()
        var cut = String.UnicodeScalarView()
        for (offset, scalar) in scalars.enumerated() {
            if ranges.contains(where: { $0.contains(offset) }) { cut.append(scalar) } else { kept.append(scalar) }
        }
        return (String(kept), String(cut))
    }

    /// Makes this message a reply to `reply`: the `<reply/>` element, and
    /// `quote` put in front of the body as a quotation for clients that do
    /// not know replies, marked as their fallback.
    public mutating func setReply(_ reply: MessageReply, quoting quote: String?) {
        var element = Element(name: "reply", namespaceURI: Namespaces.reply, attributes: ["id": reply.id])
        element["to"] = reply.to?.description
        self.element.addChild(element)
        guard let quote = quote.map(Self.quotation), !quote.isEmpty else { return }
        let text = quote + (body ?? "")
        self.element.removeChildren(name: "body", namespaceURI: Namespaces.client)
        self.element.children.insert(.element(Element(name: "body", namespaceURI: Namespaces.client, text: text)), at: 0)
        let length = quote.unicodeScalars.count
        self.element.addChild(Element(name: "fallback", namespaceURI: Namespaces.fallback,
                                      attributes: ["for": Namespaces.reply])
            .adding(Element(name: "body", namespaceURI: Namespaces.fallback,
                            attributes: ["start": "0", "end": String(length)])))
    }

    /// `text` as a XEP-0393 quotation: each line after "> ", ending with a
    /// line break. Long quotes are shortened; the reply only needs context.
    static func quotation(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if text.count > 200 { text = String(text.prefix(200)) + "…" }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }
            .joined(separator: "\n") + "\n"
    }

    /// The quoted text of a fallback, without its "> " markers: what to show
    /// for the original when it is not stored here.
    public static func unquote(_ fallback: String) -> String {
        fallback.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard line.hasPrefix(">") else { return line }
                let rest = line.dropFirst()
                return rest.hasPrefix(" ") ? rest.dropFirst() : rest
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
