import SwiftUI
import XCTest

@testable import Crumpet

final class EditorColorSchemeTests: XCTestCase {
  func testHexIgnoresExtraTrailingDigits() {
    XCTAssertEqual(Color(hex: "#1A1D21FFABCD"), Color(hex: "#1A1D21FF"))
    XCTAssertEqual(Color(hex: "1A1D219"), Color(hex: "1A1D21"))
  }

  func testHexRejectsTooFewDigits() {
    XCTAssertNil(Color(hex: "#1A"))
    XCTAssertNil(Color(hex: ""))
  }

  private let tintedYAML = """
    system: "base16"
    name: "Example"
    variant: "dark"
    palette:
      base00: "#181818"
      base01: "#282828"
      base05: "d8d8d8" # default foreground
      base08: "ab4642"
      base09: 'dc9656'
      base0B: "a1b56c"
      base0C: "86c1b9"
      base0D: "7cafc2"
      base0E: "ba8baf"
    """

  func testParsesTintedYAML() throws {
    let scheme = try XCTUnwrap(EditorColorScheme(tintedYAML: tintedYAML))

    XCTAssertEqual(scheme.background, Color(hex: "#181818"))
    XCTAssertEqual(scheme.text, Color(hex: "#d8d8d8"))
    XCTAssertEqual(scheme.heading, Color(hex: "#7cafc2"))
    XCTAssertEqual(scheme.code, Color(hex: "#a1b56c"))
    XCTAssertEqual(scheme.bold, Color(hex: "#dc9656"))
    XCTAssertEqual(scheme.italic, Color(hex: "#ba8baf"))
    XCTAssertEqual(scheme.link, Color(hex: "#86c1b9"))
    XCTAssertEqual(scheme.listBullet, Color(hex: "#ab4642"))
  }

  func testTintedPaletteKeysAreCaseInsensitive() {
    let palette = [
      "BASE00": "#000000", "base05": "#ffffff", "Base0D": "#0000ff", "base0B": "#00ff00",
      "base09": "#ff8800", "base0E": "#ff00ff", "base0C": "#00ffff", "base08": "#ff0000",
    ]
    XCTAssertNotNil(EditorColorScheme(tintedPalette: palette))
  }

  func testRejectsTintedPaletteMissingSlot() {
    var palette = [
      "base00": "#000000", "base05": "#ffffff", "base0D": "#0000ff", "base0B": "#00ff00",
      "base09": "#ff8800", "base0E": "#ff00ff", "base0C": "#00ffff", "base08": "#ff0000",
    ]
    palette["base0C"] = nil
    XCTAssertNil(EditorColorScheme(tintedPalette: palette))
  }

  func testRejectsTintedYAMLWithBadColor() {
    XCTAssertNil(
      EditorColorScheme(tintedYAML: tintedYAML.replacingOccurrences(of: "ab4642", with: "nope")))
  }

  private let tinted8YAML = """
    scheme:
      system: "tinted8"
      name: "Example"
    variant: "dark"
    palette:
      black: "#181818"
      red: "#ab4642"
      green: "#a1b56c"
      cyan: "#86c1b9"
      blue: "#7cafc2"
      magenta: "#ba8baf"
      white: "#d8d8d8" # foreground
      orange: 'dc9656'
    syntax:
      black: "#000000"
    ui:
      highlight:
        white: "#ffffff"
    """

  func testParsesTinted8YAML() throws {
    let scheme = try XCTUnwrap(EditorColorScheme(tintedYAML: tinted8YAML))

    XCTAssertEqual(scheme.background, Color(hex: "#181818"))
    XCTAssertEqual(scheme.text, Color(hex: "#d8d8d8"))
    XCTAssertEqual(scheme.heading, Color(hex: "#7cafc2"))
    XCTAssertEqual(scheme.code, Color(hex: "#a1b56c"))
    XCTAssertEqual(scheme.bold, Color(hex: "#dc9656"))
    XCTAssertEqual(scheme.italic, Color(hex: "#ba8baf"))
    XCTAssertEqual(scheme.link, Color(hex: "#86c1b9"))
    XCTAssertEqual(scheme.listBullet, Color(hex: "#ab4642"))
  }

  func testTinted8LightVariantSwapsBackgroundAndText() throws {
    let yaml = tinted8YAML.replacingOccurrences(of: "variant: \"dark\"", with: "variant: \"light\"")
    let scheme = try XCTUnwrap(EditorColorScheme(tintedYAML: yaml))

    XCTAssertEqual(scheme.background, Color(hex: "#d8d8d8"))
    XCTAssertEqual(scheme.text, Color(hex: "#181818"))
  }

  func testRejectsTinted8YAMLMissingColor() {
    XCTAssertNil(
      EditorColorScheme(
        tintedYAML: tinted8YAML.replacingOccurrences(of: "magenta:", with: "purple:")))
  }

  func testEveryPresetParses() {
    for preset in EditorColorPreset.allCases {
      XCTAssertNotNil(preset.loadScheme(), preset.displayName)
      XCTAssertNotEqual(EditorColorScheme(preset), .standard, preset.displayName)
    }
  }

  func testEveryFamilyPairsALightAndADarkBackground() {
    for family in EditorColorPreset.Family.allCases where family.hasLightAndDark {
      let light = EditorColorScheme(family.light)
      let dark = EditorColorScheme(family.dark)
      XCTAssertNotEqual(light.background, dark.background, family.displayName)
    }
  }

  func testSingleVariantFamilyUsesOnePreset() {
    XCTAssertFalse(EditorColorPreset.Family.dracula.hasLightAndDark)
    XCTAssertEqual(EditorColorPreset.Family.dracula.preset(for: .light), .dracula)
    XCTAssertEqual(EditorColorPreset.Family.nord.preset(for: .light), .nordLight)
    XCTAssertEqual(EditorColorPreset.Family.nord.preset(for: .dark), .nord)
  }

  func testAppearanceResolves() {
    XCTAssertEqual(EditorAppearance.system.resolved(.dark), .dark)
    XCTAssertEqual(EditorAppearance.system.resolved(.light), .light)
    XCTAssertEqual(EditorAppearance.light.resolved(.dark), .light)
    XCTAssertEqual(EditorAppearance.dark.resolved(.light), .dark)
  }

  func testThemeRawValueRoundTrips() {
    let themes: [EditorTheme] =
      [.system, .custom] + EditorColorPreset.Family.allCases.map { .preset($0) }
    for theme in themes {
      XCTAssertEqual(EditorTheme(rawValue: theme.rawValue), theme)
    }
    XCTAssertNil(EditorTheme(rawValue: "nope"))
  }

  func testThemeColorScheme() {
    XCTAssertEqual(EditorTheme.system.colorScheme(for: .dark), .standard)
    XCTAssertEqual(
      EditorTheme.preset(.nord).colorScheme(for: .light), EditorColorScheme(.nordLight))
    XCTAssertEqual(
      EditorTheme.custom.colorScheme(for: .dark, customColors: EditorCustomColors(.init(.nord))),
      EditorColorScheme(.nord))
    XCTAssertFalse(EditorTheme.preset(.dracula).followsAppearance)
    XCTAssertTrue(EditorTheme.custom.followsAppearance)
  }

  func testTinted8SyntaxScopesOverridePaletteSlots() throws {
    let yaml = """
      scheme:
        system: "tinted8"
      variant: "dark"
      palette:
        black: "#000000"
        white: "#ffffff"
        red: "#ff0000"
        orange: "#ff8800"
        green: "#00ff00"
        cyan: "#00ffff"
        blue: "#0000ff"
        magenta: "#ff00ff"
        gray: "#888888"
      syntax:
        keyword: "#111111"
        constant.numeric: "#222222"
      """
    let scheme = try XCTUnwrap(EditorColorScheme(tintedYAML: yaml))
    XCTAssertEqual(scheme.syntax.keyword, Color(hex: "#111111"))
    XCTAssertEqual(scheme.syntax.number, Color(hex: "#222222"))
    XCTAssertEqual(scheme.syntax.comment, Color(hex: "#888888"))
    XCTAssertEqual(scheme.syntax.string, Color(hex: "#00ff00"))
    XCTAssertEqual(scheme.syntax.function, Color(hex: "#0000ff"))
  }

  func testCustomColorsRawValueRoundTrips() throws {
    var colors = EditorCustomColors()
    colors.heading = "#FF0000FF"
    let decoded = try XCTUnwrap(EditorCustomColors(rawValue: colors.rawValue))
    XCTAssertEqual(decoded, colors)
    XCTAssertEqual(EditorCustomColors(rawValue: "{}"), EditorCustomColors())
  }

  func testPresetMapsSlots() {
    let scheme = EditorColorScheme(.nord)
    XCTAssertEqual(scheme.background, Color(hex: "#2e3440"))
    XCTAssertEqual(scheme.heading, Color(hex: "#81a1c1"))
  }
}
