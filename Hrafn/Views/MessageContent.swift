import SwiftUI
import HrafnStore
import XMPPIM

// MARK: - Styled text (XEP-0393)

/// A message body with XEP-0393 styling: bold, italic, strikethrough and
/// code, preformatted blocks and quotes. The directives stay visible, dimmed,
/// as the XEP intends, so nothing the sender typed disappears. Web addresses
/// are links, underlined so they stand out on either bubble.
struct StyledText: View {
    @Environment(\.onAccent) private var onAccent
    let text: String
    let isOutgoing: Bool
    var unstyled = false
    /// Off where the text sits inside a button of its own (a reply's quote).
    var linked = true

    var body: some View {
        // Links take the tint, which is an outgoing bubble's background.
        content.tint(isOutgoing ? onAccent : nil)
    }

    private var content: Text {
        let styled = !unstyled && text.contains(where: { "*_~`>".contains($0) })
        let links = linked ? Self.links(in: text) : []
        if !styled, links.isEmpty { return Text(text) }
        var result = styled ? Self.attributed(text, isOutgoing: isOutgoing, onAccent: onAccent)
                            : AttributedString(text)
        Self.addLinks(links, to: &result)
        return Text(result)
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The web (and mail) addresses in `text`.
    static func links(in text: String) -> [(range: NSRange, url: URL)] {
        guard let detector, text.contains(where: { $0 == "." || $0 == ":" }) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            match.url.map { (match.range, $0) }
        }
    }

    /// Links the detected ranges; styling keeps the text character for character.
    static func addLinks(_ links: [(range: NSRange, url: URL)], to text: inout AttributedString) {
        for link in links {
            guard let range = Range(link.range, in: text) else { continue }
            text[range].link = link.url
            text[range].underlineStyle = .single
        }
    }

    static func attributed(_ text: String, isOutgoing: Bool, onAccent: Color = .white) -> AttributedString {
        var result = AttributedString()
        for run in MessageStyling.parse(text) {
            var piece = AttributedString(run.text)
            let style = run.attributes
            var intent: InlinePresentationIntent = []
            if style.strong { intent.insert(.stronglyEmphasized) }
            if style.emphasis { intent.insert(.emphasized) }
            if style.strike { intent.insert(.strikethrough) }
            if style.code { intent.insert(.code) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if style.preformatted { piece.font = .body.monospaced() }
            if style.directive {
                piece.foregroundColor = isOutgoing ? onAccent.opacity(0.85) : .secondary
            } else if style.quoteDepth > 0 {
                piece.foregroundColor = isOutgoing ? onAccent.opacity(0.8) : .secondary
            }
            result += piece
        }
        return result
    }
}

// MARK: - Replies (XEP-0461)

/// The message a reply answers, above the reply's text: who wrote it and the
/// start of what they wrote. Tapping it shows the original.
struct ReplyQuote: View {
    @Environment(\.onAccent) private var onAccent
    let author: String
    let text: String
    let isOutgoing: Bool
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isOutgoing ? AnyShapeStyle(onAccent.opacity(0.7)) : AnyShapeStyle(.tint))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(author).font(.caption.bold())
                    StyledText(text: text, isOutgoing: isOutgoing, linked: false).font(.caption).lineLimit(2)
                }
                .foregroundStyle(isOutgoing ? AnyShapeStyle(onAccent.opacity(0.85)) : AnyShapeStyle(.secondary))
                .multilineTextAlignment(.leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reply to \(author): \(text)")
        .accessibilityIdentifier("message.quote")
    }
}

// MARK: - Reactions (XEP-0444)

/// The reactions under a message; tapping one adds or takes away our own.
struct ReactionBar: View {
    let reactions: [ReactionCount]
    let isOutgoing: Bool
    let toggle: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions) { reaction in
                Button {
                    toggle(reaction.emoji)
                } label: {
                    HStack(spacing: 2) {
                        Text(reaction.emoji)
                        if reaction.count > 1 { Text("\(reaction.count)").font(.caption.monospacedDigit()) }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(reaction.includesMe ? AnyShapeStyle(.tint.opacity(0.2))
                                       : AnyShapeStyle(.raised))
                    )
                    .overlay(Capsule().stroke(reaction.includesMe ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                              lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.label(reaction))
                .accessibilityIdentifier("reaction.\(reaction.emoji)")
            }
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
    }

    static func label(_ reaction: ReactionCount) -> String {
        var label = String(localized: "\(reaction.emoji), \(reaction.count)")
        if reaction.includesMe { label = String(localized: "\(label), including you") }
        if !reaction.senders.isEmpty {
            label = String(localized: "\(label): \(reaction.senders.formatted(.list(type: .and)))")
        }
        return label
    }

    /// What the context menu offers: the first three in a row, the rest below.
    static let quick = ["👍", "❤️", "😂"]
    static let more = ["😮", "😢", "🙏", "🎉", "🔥", "👎"]
}
