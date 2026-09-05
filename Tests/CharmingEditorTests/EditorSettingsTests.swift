import XCTest

@testable import CharmingEditor

/// `EditorSettings` is both `Codable` and `RawRepresentable` (so it can back an
/// `@AppStorage`). Guards that its `rawValue` round-trip encodes the stored
/// properties directly rather than recursing through the standard library's
/// `RawRepresentable` conformance, which previously overflowed the stack.
final class EditorSettingsTests: XCTestCase {
  func testRawValueRoundTrips() {
    var settings = EditorSettings()
    settings.font = .serif
    settings.fontSize = 20
    settings.titleRatio = 1.9
    settings.markerRevealMode = .always
    settings.experimentalTables = true
    settings.listBullet = .square

    let restored = EditorSettings(rawValue: settings.rawValue)
    XCTAssertEqual(restored, settings)
  }

  func testDefaultRawValueDoesNotRecurse() {
    // A plain getter access is enough to trip the old infinite recursion.
    XCTAssertFalse(EditorSettings().rawValue.isEmpty)
  }

  func testUnparseableRawValueReturnsNil() {
    XCTAssertNil(EditorSettings(rawValue: "not json"))
  }

  func testMissingKeysFallBackToDefaults() throws {
    let partial = #"{"fontSize": 24}"#
    let settings = try XCTUnwrap(EditorSettings(rawValue: partial))
    XCTAssertEqual(settings.fontSize, 24)
    XCTAssertEqual(settings.font, EditorSettings().font)
    XCTAssertEqual(settings.markerRevealMode, EditorSettings().markerRevealMode)
    XCTAssertEqual(settings.listBullet, EditorSettings().listBullet)
  }
}
