import SwiftUI
import XCTest

@testable import CharmingEditor

final class EditorColorSchemeTests: XCTestCase {
  /// Slack's export order: Column BG, Menu BG Hover, Active Item, Active Item
  /// Text, Hover Item, Text Color, Active Presence, Mention Badge.
  private let slackTheme = [
    "#1A1D21", "#222529", "#1164A3", "#D1D2D3", "#350D36", "#E8E8E8",
    "#2BAC76", "#CD2553",
  ]

  func testParsesEightColorSlackTheme() throws {
    let strings = EditorColorScheme.splitThemeString(slackTheme.joined(separator: ","))
    let scheme = try XCTUnwrap(EditorColorScheme(themeStrings: strings))

    XCTAssertEqual(scheme.background, Color(hex: "#1A1D21"))
    XCTAssertEqual(scheme.heading, Color(hex: "#1164A3"))
    XCTAssertEqual(scheme.bold, Color(hex: "#D1D2D3"))
    XCTAssertEqual(scheme.text, Color(hex: "#E8E8E8"))
    XCTAssertEqual(scheme.italic, Color(hex: "#2BAC76"))
    XCTAssertEqual(scheme.code, Color(hex: "#CD2553"))
  }

  func testParsesTenColorSlackTheme() throws {
    let tenColor = slackTheme + ["#101112", "#F5F5F5"]
    let scheme = try XCTUnwrap(EditorColorScheme(themeStrings: tenColor))

    XCTAssertEqual(scheme.background, Color(hex: "#1A1D21"))
    XCTAssertEqual(scheme.code, Color(hex: "#CD2553"))
  }

  func testRejectsSixColorString() {
    XCTAssertNil(EditorColorScheme(themeStrings: Array(slackTheme.prefix(6))))
  }

  func testParsesNineColorString() throws {
    let scheme = try XCTUnwrap(EditorColorScheme(themeStrings: slackTheme + ["#101112"]))
    XCTAssertEqual(scheme.background, Color(hex: "#1A1D21"))
    XCTAssertEqual(scheme.code, Color(hex: "#CD2553"))
  }

  func testHexIgnoresExtraTrailingDigits() {
    XCTAssertEqual(Color(hex: "#1A1D21FFABCD"), Color(hex: "#1A1D21FF"))
    XCTAssertEqual(Color(hex: "1A1D219"), Color(hex: "1A1D21"))
  }

  func testHexRejectsTooFewDigits() {
    XCTAssertNil(Color(hex: "#1A"))
    XCTAssertNil(Color(hex: ""))
  }

  func testRejectsUnparseableEntry() {
    var bad = slackTheme
    bad[3] = "nope"
    XCTAssertNil(EditorColorScheme(themeStrings: bad))
  }

  func testSplitAcceptsWhitespaceAndCommas() {
    let strings = EditorColorScheme.splitThemeString(slackTheme.joined(separator: " , "))
    XCTAssertEqual(strings, slackTheme)
  }
}
