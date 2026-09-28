import SwiftUI
import UIKit

/// How the app looks: light or dark, the accent, the font, and the
/// background and text colours. Kept in the App Group's defaults, like the
/// media policy.
struct Appearance: Codable, Hashable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case automatic, light, dark

        var id: Self { self }

        var colorScheme: ColorScheme? {
            switch self {
            case .automatic: nil
            case .light: .light
            case .dark: .dark
            }
        }

        var label: String {
            switch self {
            case .automatic: String(localized: "Automatic")
            case .light: String(localized: "Light")
            case .dark: String(localized: "Dark")
            }
        }
    }

    enum FontStyle: String, Codable, CaseIterable, Identifiable {
        case system, monospaced, serif, rounded

        var id: Self { self }

        var design: Font.Design {
            switch self {
            case .system: .default
            case .monospaced: .monospaced
            case .serif: .serif
            case .rounded: .rounded
            }
        }

        var label: String {
            switch self {
            case .system: String(localized: "System")
            case .monospaced: String(localized: "Monospaced")
            case .serif: String(localized: "Serif")
            case .rounded: String(localized: "Rounded")
            }
        }
    }

    var mode: Mode = .automatic
    var font: FontStyle = .system
    /// Hex colours; `nil` keeps the system's.
    var accentHex: String?
    var lightBackgroundHex: String?
    var darkBackgroundHex: String?
    var lightTextHex: String?
    var darkTextHex: String?

    var accent: Color? { accentHex.flatMap(Color.init(hex:)) }

    /// The background for a colour scheme, when one was chosen.
    func background(for scheme: ColorScheme) -> Color? {
        (scheme == .dark ? darkBackgroundHex : lightBackgroundHex).flatMap(Color.init(hex:))
    }

    /// The text colour for a colour scheme, when one was chosen.
    func text(for scheme: ColorScheme) -> Color? {
        (scheme == .dark ? darkTextHex : lightTextHex).flatMap(Color.init(hex:))
    }

    var isDefault: Bool { self == Appearance() }
}

/// Puts the chosen background behind a screen's list, form or scroll view,
/// and the chosen text colour on its text. Without choices, the system's.
private struct Themed: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let background = app.appearance.background(for: colorScheme)
        content
            .scrollContentBackground(background == nil ? .automatic : .hidden)
            .background { (background ?? .clear).ignoresSafeArea() }
            .foregroundStyle(app.appearance.text(for: colorScheme).map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
    }
}

/// A list row on the chosen background, so plain lists don't keep the
/// system's cell colour behind their rows.
private struct ThemedRow: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.listRowBackground(app.appearance.background(for: colorScheme))
    }
}

extension View {
    func themed() -> some View { modifier(Themed()) }
    func themedRow() -> some View { modifier(ThemedRow()) }
}

extension Color {
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let rgb = UInt64(digits, radix: 16) else { return nil }
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }

    var hex: String? {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        let clamp = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }
}

/// A colour setting that may be left to the system: picking one stores it.
extension Binding where Value == String? {
    func color(default fallback: Color) -> Binding<Color> {
        Binding<Color>(get: { wrappedValue.flatMap(Color.init(hex:)) ?? fallback },
                       set: { wrappedValue = $0.hex })
    }
}
