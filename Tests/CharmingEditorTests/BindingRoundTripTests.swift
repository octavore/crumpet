import SwiftUI
import XCTest

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@testable import CharmingEditor

/// The editor pushes styling up through an `AttributedString` binding
/// (`text = AttributedString(storage)`) and rebuilds the text view from it
/// (`NSAttributedString(text)`). If that round-trip drops the highlighter's
/// fonts, the rendered text reverts to unstyled even though `highlight` was
/// correct. This isolates that conversion.
@MainActor
final class BindingRoundTripTests: XCTestCase {

  private func isMono(_ s: NSAttributedString, at loc: Int) -> Bool {
    let f = s.attribute(.font, at: loc, effectiveRange: nil) as? PlatformFont
    return f?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false
  }

  private func size(_ s: NSAttributedString, at loc: Int) -> CGFloat {
    (s.attribute(.font, at: loc, effectiveRange: nil) as? PlatformFont)?.pointSize ?? 0
  }

  func testInlineCodeSurvivesBindingRoundTrip() {
    let md = "a `code` b"
    let storage = NSTextStorage(string: md)
    MarkdownHighlighter().highlight(storage)
    let code = (md as NSString).range(of: "code").location
    XCTAssertTrue(isMono(storage, at: code), "precondition: highlighter styled the code span")

    // The exact round-trip the editor performs.
    let roundTripped = NSAttributedString(AttributedString(storage))
    XCTAssertTrue(
      isMono(roundTripped, at: code),
      "code span must stay monospaced through the AttributedString binding round-trip")
  }

  func testHeadingSurvivesBindingRoundTrip() {
    let md = "# Title"
    let storage = NSTextStorage(string: md)
    MarkdownHighlighter().highlight(storage)
    let loc = (md as NSString).range(of: "Title").location
    XCTAssertEqual(size(storage, at: loc), 28, "precondition: highlighter styled the heading")

    let roundTripped = NSAttributedString(AttributedString(storage))
    XCTAssertEqual(
      size(roundTripped, at: loc), 28,
      "heading size must survive the AttributedString binding round-trip")
  }
}
