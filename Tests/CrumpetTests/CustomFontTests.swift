import Testing

@testable import Crumpet

@MainActor
@Suite(.serialized)
struct CustomFontTests {
  @Test func customFontReplacesTypefaceAndCode() {
    Typography.customFontName = "Courier"
    defer { Typography.customFontName = nil }

    #expect(TextStyle.body.font.fontName == "Courier")
    #expect(TextStyle.title.font.fontName == "Courier")
    #expect(Typography.codeFont(ofSize: 14).fontName == "Courier")
  }

  @Test func unknownCustomFontFallsBackToTypeface() {
    Typography.customFontName = "No Such Font"
    defer { Typography.customFontName = nil }

    #expect(TextStyle.body.font.fontName != "No Such Font")
  }

  @Test func noCustomFontKeepsSystemFonts() {
    Typography.customFontName = nil

    #expect(TextStyle.body.font.fontName != "Courier")
  }
}
