import SwiftUI
import Testing
@testable import Hrafn

@MainActor
struct ThemeTests {

    @Test func presetsHaveSixteenColours() {
        for scheme in Base16Scheme.presets {
            #expect(scheme.colors.count == 16, "\(scheme.name)")
            #expect(scheme.colors.allSatisfy { Color(hex: $0) != nil }, "\(scheme.name)")
        }
        #expect(Set(Base16Scheme.presets.map(\.id)).count == Base16Scheme.presets.count)
    }

    @Test func presetsHaveLightAndDark() {
        #expect(Base16Scheme.presets.first { $0.id == "nord" }?.isDark == true)
        #expect(Base16Scheme.presets.first { $0.id == "catppuccin-latte" }?.isDark == false)
    }

    @Test func parsesClassicYAML() throws {
        let yaml = """
        scheme: "Nord"
        author: "arcticicestudio"
        base00: "2E3440" # background
        base01: "3B4252"
        base02: "434C5E"
        base03: "4C566A"
        base04: "D8DEE9"
        base05: "E5E9F0"
        base06: "ECEFF4"
        base07: "8FBCBB"
        base08: "BF616A"
        base09: "D08770"
        base0A: "EBCB8B"
        base0B: "A3BE8C"
        base0C: "88C0D0"
        base0D: "81A1C1"
        base0E: "B48EAD"
        base0F: "5E81AC"
        """
        let scheme = try #require(Base16Scheme.parse(yaml: yaml))
        #expect(scheme.name == "Nord")
        #expect(scheme.colors.first == "#2E3440")
        #expect(scheme.colors[13] == "#81A1C1")
        #expect(scheme.isDark)
    }

    @Test func parsesTintedThemingYAML() throws {
        let yaml = """
        system: "base16"
        name: "Catppuccin Latte"
        variant: "light"
        palette:
          base00: "#eff1f5"
          base01: "#e6e9ef"
          base02: "#ccd0da"
          base03: "#bcc0cc"
          base04: "#acb0be"
          base05: "#4c4f69"
          base06: "#dc8a78"
          base07: "#7287fd"
          base08: "#d20f39"
          base09: "#fe640b"
          base0A: "#df8e1d"
          base0B: "#40a02b"
          base0C: "#179299"
          base0D: "#1e66f5"
          base0E: "#8839ef"
          base0F: "#dd7878"
        """
        let scheme = try #require(Base16Scheme.parse(yaml: yaml))
        #expect(scheme.name == "Catppuccin Latte")
        #expect(scheme.colors[5] == "#4C4F69")
        #expect(!scheme.isDark)
    }

    @Test func rejectsIncompleteYAML() {
        #expect(Base16Scheme.parse(yaml: "scheme: \"Half\"\nbase00: \"000000\"") == nil)
        #expect(Base16Scheme.parse(yaml: "hello") == nil)
    }

    @Test func yamlRoundTrips() throws {
        let nord = Base16Scheme.presets[0]
        let parsed = try #require(Base16Scheme.parse(yaml: nord.yaml))
        #expect(parsed.name == nord.name)
        #expect(parsed.colors == nord.colors)
    }

    @Test func paletteFollowsModes() {
        var appearance = Appearance()
        appearance.lightTheme = "catppuccin-latte"
        appearance.darkTheme = "nord"
        #expect(appearance.palette(for: .light)?.scheme.id == "catppuccin-latte")
        #expect(appearance.palette(for: .dark)?.scheme.id == "nord")
        #expect(Appearance().palette(for: .dark) == nil)
    }

    @Test func oldSettingsStillDecode() throws {
        let old = ##"{"mode":"dark","font":"system","darkBackgroundHex":"#101010"}"##
        let appearance = try JSONDecoder().decode(Appearance.self, from: Data(old.utf8))
        #expect(appearance.mode == .dark)
        #expect(appearance.darkTheme == nil)
    }
}
