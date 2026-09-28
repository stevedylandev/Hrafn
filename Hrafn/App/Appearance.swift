import SwiftUI
import UIKit

/// How the app looks: light or dark, the accent, the font, and a base16
/// theme for each of light and dark mode. Kept in the App Group's defaults,
/// like the media policy.
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
    /// Hex colour; `nil` takes the theme's, or the system's.
    var accentHex: String?
    /// Base16 schemes by id, for light and dark mode; `nil` keeps the system's.
    var lightTheme: String?
    var darkTheme: String?
    /// Schemes the user made or imported.
    var customSchemes: [Base16Scheme]?

    var accent: Color? { accentHex.flatMap(Color.init(hex:)) }

    var schemes: [Base16Scheme] { Base16Scheme.presets + (customSchemes ?? []) }

    func scheme(id: String?) -> Base16Scheme? {
        id.flatMap { id in schemes.first { $0.id == id } }
    }

    /// The colours for a colour scheme, when a theme was chosen for it.
    func palette(for colorScheme: ColorScheme) -> Palette? {
        scheme(id: colorScheme == .dark ? darkTheme : lightTheme).map(Palette.init)
    }

    var isDefault: Bool { self == Appearance() }
}

/// Puts the palette in the environment and tints with its accent, for the
/// colour scheme in effect.
struct AppTheme: ViewModifier {
    let appearance: Appearance
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let palette = appearance.palette(for: colorScheme)
        let accent = appearance.accent ?? palette?.accent
        content
            .environment(\.palette, palette)
            .environment(\.onAccent, accent.flatMap { palette?.onAccent($0) } ?? .white)
            .tint(accent)
    }
}

/// Puts the theme's background behind a screen's list, form or scroll view,
/// and its text colour on its text. Without a theme, the system's.
private struct Themed: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(palette == nil ? .automatic : .hidden)
            .background { (palette?.background ?? .clear).ignoresSafeArea() }
            .foregroundStyle(palette.map { AnyShapeStyle($0.text) } ?? AnyShapeStyle(.primary))
    }
}

/// A plain list row on the theme's background, so plain lists don't keep
/// the system's cell colour behind their rows.
private struct ThemedRow: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.listRowBackground(palette?.background)
    }
}

/// Grouped form cells on the theme's surface colour. On a `Group` of
/// sections, it reaches every row.
private struct ThemedCells: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.listRowBackground(palette?.surface)
    }
}

/// The theme's surface, or the system's colour when there is no theme.
struct ThemedFill: ShapeStyle {
    enum Level { case surface, raised }
    var level: Level = .surface

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        if let palette = environment.palette {
            return (level == .surface ? palette.surface : palette.raised).resolve(in: environment)
        }
        let system = level == .surface ? UIColor.secondarySystemBackground : .tertiarySystemBackground
        return Color(system).resolve(in: environment)
    }
}

/// Bars over content (composer, banners): the theme's surface, or the
/// system's bar material.
private struct ThemedBar: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        if let palette {
            content.background(palette.surface)
        } else {
            content.background(.bar)
        }
    }
}

extension View {
    func themed() -> some View { modifier(Themed()) }
    func themedRow() -> some View { modifier(ThemedRow()) }
    func themedCells() -> some View { modifier(ThemedCells()) }
    func themedBar() -> some View { modifier(ThemedBar()) }
}

extension ShapeStyle where Self == ThemedFill {
    static var surface: ThemedFill { ThemedFill(level: .surface) }
    static var raised: ThemedFill { ThemedFill(level: .raised) }
}

nonisolated extension Color {
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
