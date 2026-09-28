import Foundation
import XMPPCore
import XMPPXML

extension Namespaces {
    /// XEP-0393; also the namespace of `<unstyled/>` (§6).
    public static let styling = "urn:xmpp:styling:0"
}

extension Message {
    /// XEP-0393 §6: the sender asks for the body to be shown as plain text.
    public var isUnstyled: Bool {
        element.firstChild(name: "unstyled", namespaceURI: Namespaces.styling) != nil
    }
}

/// XEP-0393 Message Styling: splits a body into runs of text with the styles
/// that apply to them. The styling directives stay in the output (marked
/// `directive`), so the text reads the same with or without styling and a
/// renderer can show them dimmed.
public enum MessageStyling {

    public struct Attributes: Sendable, Hashable {
        public var strong = false
        public var emphasis = false
        public var strike = false
        /// An inline preformatted span (`` `code` ``).
        public var code = false
        /// Inside a preformatted block (```` ``` ````).
        public var preformatted = false
        /// A styling directive: `*`, `_`, `~`, `` ` ``, ```` ``` ```` or `>`.
        public var directive = false
        /// How many block quotes this is inside.
        public var quoteDepth = 0

        public init() {}
    }

    public struct Run: Sendable, Hashable {
        public var text: String
        public var attributes: Attributes

        public init(_ text: String, _ attributes: Attributes) {
            self.text = text
            self.attributes = attributes
        }
    }

    /// The runs of `text`. Joined, they are `text` again.
    public static func parse(_ text: String) -> [Run] {
        var output = Output()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(Line.init)
        blocks(lines, Attributes(), into: &output)
        return output.runs
    }

    /// Whether `text` has anything to style, so plain messages can skip it.
    public static func hasStyling(_ text: String) -> Bool {
        parse(text).contains { $0.attributes != Attributes() }
    }

    // MARK: - Blocks (§5.1)

    /// A line of the body, and whether a line break followed it.
    private struct Line {
        var text: Substring
        var breaks: Bool

        init(_ text: Substring) {
            self.text = text
            breaks = text.endIndex != text.base.endIndex
        }

        init(text: Substring, breaks: Bool) {
            self.text = text
            self.breaks = breaks
        }
    }

    private static func blocks(_ lines: [Line], _ attributes: Attributes, into output: inout Output) {
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.text.hasPrefix("```") {
                // A preformatted block: to a line that is only "```", or to
                // the end of the enclosing block. Nothing inside is styled.
                var directive = attributes
                directive.preformatted = true
                directive.directive = true
                var content = attributes
                content.preformatted = true
                output.append(line.text, directive)
                output.newline(line, content)
                index += 1
                while index < lines.count {
                    let inner = lines[index]
                    index += 1
                    if inner.text == "```" {
                        output.append(inner.text, directive)
                        output.newline(inner, attributes)
                        break
                    }
                    output.append(inner.text, content)
                    output.newline(inner, content)
                }
            } else if line.text.hasPrefix(">") {
                // A quotation: every following line that starts with ">".
                // What follows the ">" is parsed again as blocks, so quotes
                // nest and may hold preformatted blocks.
                var quoted: [Line] = []
                var directive = attributes
                directive.directive = true
                directive.quoteDepth += 1
                var inner = attributes
                inner.quoteDepth += 1
                while index < lines.count, lines[index].text.hasPrefix(">") {
                    quoted.append(lines[index])
                    index += 1
                }
                // Each quoted line's ">" (and one space after it) is written
                // out before the line's content; the content is parsed as a
                // whole, so the markers are interleaved as it is written.
                var contents: [Line] = []
                var markers: [Substring] = []
                for line in quoted {
                    var rest = line.text.dropFirst()
                    var marker = line.text.prefix(1)
                    if rest.hasPrefix(" ") {
                        marker = line.text.prefix(2)
                        rest = rest.dropFirst()
                    }
                    markers.append(marker)
                    contents.append(Line(text: rest, breaks: line.breaks))
                }
                output.quoteMarkers(markers, directive) {
                    blocks(contents, inner, into: &$0)
                }
            } else {
                spans(line.text, attributes, into: &output)
                output.newline(line, attributes)
                index += 1
            }
        }
    }

    // MARK: - Spans (§5.2)

    private static func style(_ directive: Character) -> WritableKeyPath<Attributes, Bool>? {
        switch directive {
        case "*": \.strong
        case "_": \.emphasis
        case "~": \.strike
        case "`": \.code
        default: nil
        }
    }

    /// Styles one line (or the inside of a span). Opening directives come at
    /// the start, after whitespace, or after another opening directive, and
    /// are not followed by whitespace; the first matching directive not
    /// preceded by whitespace closes the span, which may not be empty.
    private static func spans(_ text: Substring, _ attributes: Attributes, into output: inout Output) {
        var plainStart = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard let keyPath = style(character), !attributes[keyPath: keyPath],
                  index == text.startIndex || text[text.index(before: index)].isWhitespace,
                  let close = closing(character, in: text, openingAt: index)
            else {
                index = text.index(after: index)
                continue
            }
            output.append(text[plainStart..<index], attributes)
            var styled = attributes
            styled[keyPath: keyPath] = true
            var directive = styled
            directive.directive = true
            output.append(text[index...index], directive)
            let inner = text[text.index(after: index)..<close]
            if character == "`" {
                // Nothing is styled inside a preformatted span.
                output.append(inner, styled)
            } else {
                spans(inner, styled, into: &output)
            }
            output.append(text[close...close], directive)
            index = text.index(after: close)
            plainStart = index
        }
        output.append(text[plainStart..<text.endIndex], attributes)
    }

    private static func closing(_ directive: Character, in text: Substring,
                                openingAt open: Substring.Index) -> Substring.Index? {
        let first = text.index(after: open)
        guard first < text.endIndex, !text[first].isWhitespace else { return nil }
        var index = text.index(after: first)
        while index < text.endIndex {
            if text[index] == directive, !text[text.index(before: index)].isWhitespace { return index }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - Output

    private struct Output {
        var runs: [Run] = []
        /// Per open quote, outermost first: the markers of its lines not yet
        /// written, each written as its line starts.
        var markerQueue: [[Substring]] = []
        var markerAttributes: [Attributes] = []
        var atLineStart = true

        mutating func append(_ text: Substring, _ attributes: Attributes) {
            guard !text.isEmpty else { return }
            writeMarkersIfNeeded()
            atLineStart = false
            if let last = runs.last, last.attributes == attributes {
                runs[runs.count - 1].text += text
            } else {
                runs.append(Run(String(text), attributes))
            }
        }

        mutating func newline(_ line: Line, _ attributes: Attributes) {
            // An empty quoted line still shows its ">".
            writeMarkersIfNeeded()
            guard line.breaks else { return }
            append("\n", attributes)
            atLineStart = true
        }

        /// Runs `body` with `markers` written, one per line, as lines start.
        mutating func quoteMarkers(_ markers: [Substring], _ attributes: Attributes, _ body: (inout Output) -> Void) {
            markerQueue.append(markers)
            markerAttributes.append(attributes)
            body(&self)
            markerQueue.removeLast()
            markerAttributes.removeLast()
        }

        private mutating func writeMarkersIfNeeded() {
            guard atLineStart, !markerQueue.isEmpty else { return }
            atLineStart = false
            // Outer quotes first: each level took its marker off this line.
            for level in markerQueue.indices where !markerQueue[level].isEmpty {
                let marker = markerQueue[level].removeFirst()
                let attributes = markerAttributes[level]
                if let last = runs.last, last.attributes == attributes {
                    runs[runs.count - 1].text += marker
                } else {
                    runs.append(Run(String(marker), attributes))
                }
            }
        }
    }
}
