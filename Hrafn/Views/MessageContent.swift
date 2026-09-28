import SwiftUI
import HrafnStore
import XMPPIM

// MARK: - Styled text (XEP-0393)

/// A message body with XEP-0393 styling: bold, italic, strikethrough and
/// code, preformatted blocks and quotes. The directives stay visible, dimmed,
/// as the XEP intends, so nothing the sender typed disappears.
struct StyledText: View {
    let text: String
    let isOutgoing: Bool
    var unstyled = false

    var body: some View {
        if unstyled || !text.contains(where: { "*_~`>".contains($0) }) {
            Text(text)
        } else {
            Text(Self.attributed(text, isOutgoing: isOutgoing))
        }
    }

    static func attributed(_ text: String, isOutgoing: Bool) -> AttributedString {
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
                piece.foregroundColor = isOutgoing ? .white.opacity(0.85) : .secondary
            } else if style.quoteDepth > 0 {
                piece.foregroundColor = isOutgoing ? .white.opacity(0.8) : .secondary
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
                    .fill(isOutgoing ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tint))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(author).font(.caption.bold())
                    StyledText(text: text, isOutgoing: isOutgoing).font(.caption).lineLimit(2)
                }
                .foregroundStyle(isOutgoing ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
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
                                       : AnyShapeStyle(Color(.tertiarySystemBackground)))
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
