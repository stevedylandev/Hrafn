import SwiftUI
import UIKit

/// A base16 colour scheme (https://github.com/tinted-theming/home): sixteen
/// colours, `base00`–`base0F`, from background to accents.
nonisolated struct Base16Scheme: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    /// Sixteen hex colours, `base00` first.
    var colors: [String]

    /// A light scheme has a light background.
    var isDark: Bool { (Color.luminance(hex: colors[0]) ?? 0) < 0.5 }

    subscript(_ index: Int) -> Color { Color(hex: colors[index]) ?? .gray }

    /// What each slot is used for here, for the editor.
    static let roles = [
        "Background", "Surfaces", "Selection", "Faint text",
        "Secondary text", "Text", "Light text", "Lightest",
        "Red", "Orange", "Yellow", "Green",
        "Cyan", "Accent", "Purple", "Brown",
    ]

    /// Reads a base16 YAML file, in either the classic form
    /// (`scheme: "Nord"`, `base00: "2E3440"`) or the tinted-theming one
    /// (`name: "Nord"`, `palette:` with `base00: "#2E3440"`).
    static func parse(yaml: String) -> Base16Scheme? {
        var name: String?
        var colors = [String?](repeating: nil, count: 16)
        for line in yaml.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if key == "scheme" || key == "name" {
                name = name ?? value
            } else if key.hasPrefix("base0"), key.count == 6, let index = Int(key.suffix(1), radix: 16) {
                let hex = value.hasPrefix("#") ? value : "#" + value
                guard Color(hex: hex) != nil else { return nil }
                colors[index] = hex.uppercased()
            }
        }
        let found = colors.compactMap { $0 }
        guard found.count == 16 else { return nil }
        let title = name?.isEmpty == false ? name! : String(localized: "Custom")
        return Base16Scheme(id: "custom-" + UUID().uuidString, name: title, colors: found)
    }

    var yaml: String {
        var lines = ["scheme: \"\(name)\""]
        for (index, hex) in colors.enumerated() {
            lines.append(String(format: "base0%X: \"%@\"", index, hex.replacingOccurrences(of: "#", with: "")))
        }
        return lines.joined(separator: "\n")
    }
}

nonisolated extension Base16Scheme {
    private init(_ id: String, _ name: String, _ colors: String) {
        self.init(id: id, name: name, colors: colors.split(separator: " ").map { "#" + $0.uppercased() })
    }

    static let presets: [Base16Scheme] = [
        Base16Scheme("nord", "Nord",
                     "2e3440 3b4252 434c5e 4c566a d8dee9 e5e9f0 eceff4 8fbcbb bf616a d08770 ebcb8b a3be8c 88c0d0 81a1c1 b48ead 5e81ac"),
        Base16Scheme("catppuccin-mocha", "Catppuccin Mocha",
                     "1e1e2e 181825 313244 45475a 585b70 cdd6f4 f5e0dc b4befe f38ba8 fab387 f9e2af a6e3a1 94e2d5 89b4fa cba6f7 f2cdcd"),
        Base16Scheme("catppuccin-macchiato", "Catppuccin Macchiato",
                     "24273a 1e2030 363a4f 494d64 5b6078 cad3f5 f4dbd6 b7bdf8 ed8796 f5a97f eed49f a6da95 8bd5ca 8aadf4 c6a0f6 f0c6c6"),
        Base16Scheme("catppuccin-frappe", "Catppuccin Frappé",
                     "303446 292c3c 414559 51576d 626880 c6d0f5 f2d5cf babbf1 e78284 ef9f76 e5c890 a6d189 81c8be 8caaee ca9ee6 eebebe"),
        Base16Scheme("catppuccin-latte", "Catppuccin Latte",
                     "eff1f5 e6e9ef ccd0da bcc0cc acb0be 4c4f69 dc8a78 7287fd d20f39 fe640b df8e1d 40a02b 179299 1e66f5 8839ef dd7878"),
        Base16Scheme("gruvbox-dark", "Gruvbox Dark",
                     "282828 3c3836 504945 665c54 bdae93 d5c4a1 ebdbb2 fbf1c7 fb4934 fe8019 fabd2f b8bb26 8ec07c 83a598 d3869b d65d0e"),
        Base16Scheme("gruvbox-light", "Gruvbox Light",
                     "fbf1c7 ebdbb2 d5c4a1 bdae93 665c54 504945 3c3836 282828 9d0006 af3a03 b57614 79740e 427b58 076678 8f3f71 d65d0e"),
        Base16Scheme("tokyo-night", "Tokyo Night",
                     "1a1b26 16161e 2f3549 444b6a 787c99 a9b1d6 cbccd1 d5d6db c0caf5 a9b1d6 0db9d7 9ece6a b4f9f8 2ac3de bb9af7 f7768e"),
        Base16Scheme("rose-pine", "Rosé Pine",
                     "191724 1f1d2e 26233a 6e6a86 908caa e0def4 e0def4 524f67 eb6f92 f6c177 ebbcba 31748f 9ccfd8 c4a7e7 f6c177 524f67"),
        Base16Scheme("rose-pine-dawn", "Rosé Pine Dawn",
                     "faf4ed fffaf3 f2e9de 9893a5 797593 575279 575279 cecacd b4637a ea9d34 d7827e 286983 56949f 907aa9 ea9d34 cecacd"),
        Base16Scheme("solarized-dark", "Solarized Dark",
                     "002b36 073642 586e75 657b83 839496 93a1a1 eee8d5 fdf6e3 dc322f cb4b16 b58900 859900 2aa198 268bd2 6c71c4 d33682"),
        Base16Scheme("solarized-light", "Solarized Light",
                     "fdf6e3 eee8d5 93a1a1 839496 657b83 586e75 073642 002b36 dc322f cb4b16 b58900 859900 2aa198 268bd2 6c71c4 d33682"),
    ]
}

/// The colours screens draw with, from a scheme. `nil` in the environment
/// means the system's.
nonisolated struct Palette {
    let scheme: Base16Scheme
    /// base00
    var background: Color { scheme[0] }
    /// base01: form cells, message bubbles, the composer.
    var surface: Color { scheme[1] }
    /// base02: reactions, placeholders.
    var raised: Color { scheme[2] }
    /// base05
    var text: Color { scheme[5] }
    /// base0D
    var accent: Color { scheme[13] }

    /// Text on the accent, dark or light, whichever reads better.
    func onAccent(_ accent: Color) -> Color {
        let (light, dark) = scheme.isDark ? (scheme[5], scheme[0]) : (scheme[0], scheme[5])
        guard let fill = accent.luminance, let l = light.luminance, let d = dark.luminance else { return .white }
        // WCAG contrast ratio.
        let contrast = { (a: Double, b: Double) in (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        return contrast(fill, l) >= contrast(fill, d) ? light : dark
    }
}

nonisolated extension EnvironmentValues {
    @Entry var palette: Palette?
    /// Text on outgoing bubbles and other accent fills.
    @Entry var onAccent: Color = .white
}

nonisolated extension Color {
    /// Relative luminance, 0 (black) to 1 (white).
    var luminance: Double? {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        let linear = { (c: CGFloat) -> Double in
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    static func luminance(hex: String) -> Double? { Color(hex: hex)?.luminance }
}
