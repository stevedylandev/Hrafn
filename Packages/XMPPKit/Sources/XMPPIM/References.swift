import Foundation
import XMPPCore
import XMPPXML

extension Namespaces {
    /// XEP-0372.
    public static let references = "urn:xmpp:reference:0"
}

/// XEP-0372: a `type='mention'` reference — someone named in the body, by
/// `xmpp:` URI, over a range of the body counted in Unicode code points.
public struct Mention: Sendable, Hashable {
    /// Who is mentioned: an account (bare JID) or a room occupant
    /// (`room@service/nick`).
    public var jid: JID
    /// Code point offsets in the body; `nil` when the sender gave none.
    public var range: Range<Int>?

    public init(jid: JID, range: Range<Int>?) {
        self.jid = jid
        self.range = range
    }

    var element: Element {
        var attributes = ["type": "mention", "uri": "xmpp:" + jid.description]
        if let range {
            attributes["begin"] = String(range.lowerBound)
            attributes["end"] = String(range.upperBound)
        }
        return Element(name: "reference", namespaceURI: Namespaces.references, attributes: attributes)
    }

    /// Where `nicks` appear in `body` as whole words (any case), from code
    /// point `start` on: "@romeo", "Romeo:" and "romeo," count, "romeos"
    /// does not. Longer nicks win where they overlap ("Romeo" in "Romeo Jr").
    public static func find(_ nicks: [String], in body: String, from start: Int = 0) -> [(nick: String, range: Range<Int>)] {
        let scalars = Array(body.unicodeScalars)
        func isWordScalar(_ index: Int) -> Bool {
            guard index >= 0, index < scalars.count else { return false }
            let properties = scalars[index].properties
            return properties.isAlphabetic || properties.numericType != nil
        }
        var found: [(nick: String, range: Range<Int>)] = []
        for nick in nicks.filter({ !$0.isEmpty }).sorted(by: { $0.unicodeScalars.count > $1.unicodeScalars.count }) {
            let needle = Array(nick.lowercased().unicodeScalars)
            guard needle.count <= scalars.count - start else { continue }
            var index = start
            while index + needle.count <= scalars.count {
                let candidate = String(String.UnicodeScalarView(scalars[index..<index + needle.count])).lowercased()
                let range = index..<index + needle.count
                if Array(candidate.unicodeScalars) == needle, !isWordScalar(index - 1), !isWordScalar(range.upperBound),
                   !found.contains(where: { $0.range.overlaps(range) }) {
                    found.append((nick, range))
                    index = range.upperBound
                } else {
                    index += 1
                }
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}

extension Message {

    /// The XEP-0372 mentions this message carries.
    public var mentions: [Mention] {
        element.childElements(name: "reference", namespaceURI: Namespaces.references).compactMap { reference in
            guard reference["type"] == "mention", let uri = reference["uri"], uri.hasPrefix("xmpp:"),
                  let jid = try? JID(String(uri.dropFirst(5)).components(separatedBy: "?")[0]) else { return nil }
            var range: Range<Int>?
            if let begin = reference["begin"].flatMap(Int.init), let end = reference["end"].flatMap(Int.init),
               begin >= 0, begin < end {
                range = begin..<end
            }
            return Mention(jid: jid, range: range)
        }
    }

    /// Marks up the room occupants named in the body (outside a reply's
    /// quoted fallback) as XEP-0372 mentions of their occupant JIDs.
    public func mentioningOccupants(_ nicks: [String], in room: JID) -> Message {
        guard let body else { return self }
        let quoted = element.childElements(name: "fallback", namespaceURI: Namespaces.fallback)
            .filter { $0["for"] == Namespaces.reply }
            .flatMap { $0.childElements(name: "body", namespaceURI: Namespaces.fallback) }
            .compactMap { $0["end"].flatMap(Int.init) }
            .max() ?? 0
        var copy = self
        for (nick, range) in Mention.find(nicks, in: body, from: quoted) {
            guard let occupant = try? room.bare.withResource(nick) else { continue }
            copy.element.addChild(Mention(jid: occupant, range: range).element)
        }
        return copy
    }
}
