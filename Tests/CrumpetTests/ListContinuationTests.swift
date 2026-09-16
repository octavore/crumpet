import SwiftUI
import XCTest

@testable import Crumpet

#if canImport(AppKit)
  import AppKit
#endif

/// Exercises the list-aware Return handling (`Coordinator.handleListNewline`)
/// against a real text view: place the caret at the end of a line, press Return,
/// and check the resulting text and caret.
@MainActor
final class ListContinuationTests: XCTestCase {
  #if canImport(AppKit)
    /// Builds a coordinator wired to an NSTextView holding `text`, with the caret
    /// at `caret` (default: end of text).
    private func makeEditor(_ text: String, caret: Int? = nil)
      -> (TextViewEditor.Coordinator, NSTextView)
    {
      var stored = ""
      let binding = Binding(get: { stored }, set: { stored = $0 })
      let coord = TextViewEditor.Coordinator(text: binding, commands: EditorCommands())
      let tv = NSTextView(frame: .zero)
      tv.typingAttributes = TextStyle.body.attributes
      tv.textStorage?.delegate = coord.highlighter
      coord.textView = tv
      tv.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
      let loc = caret ?? (text as NSString).length
      tv.setSelectedRange(NSRange(location: loc, length: 0))
      return (coord, tv)
    }

    /// Presses Return and returns whether it was handled, plus the resulting text
    /// and caret location.
    @discardableResult
    private func pressReturn(_ text: String, caret: Int? = nil)
      -> (handled: Bool, text: String, caret: Int)
    {
      let (coord, tv) = makeEditor(text, caret: caret)
      let handled = coord.handleListNewline()
      return (handled, tv.string, tv.selectedRange().location)
    }

    func testUnorderedContinues() {
      let r = pressReturn("- item")
      XCTAssertTrue(r.handled)
      XCTAssertEqual(r.text, "- item\n- ")
      XCTAssertEqual(r.caret, 9)
    }

    func testOrderedIncrements() {
      let r = pressReturn("1. item")
      XCTAssertTrue(r.handled)
      XCTAssertEqual(r.text, "1. item\n2. ")
    }

    func testOrderedIncrementsFromArbitraryNumber() {
      XCTAssertEqual(pressReturn("3. item").text, "3. item\n4. ")
    }

    func testOrderedParenDelimiterPreserved() {
      XCTAssertEqual(pressReturn("2) item").text, "2) item\n3) ")
    }

    func testStarAndPlusBullets() {
      XCTAssertEqual(pressReturn("* item").text, "* item\n* ")
      XCTAssertEqual(pressReturn("+ item").text, "+ item\n+ ")
    }

    func testNestedIndentationPreserved() {
      XCTAssertEqual(pressReturn("  - item").text, "  - item\n  - ")
      XCTAssertEqual(pressReturn("  1. item").text, "  1. item\n  2. ")
    }

    func testTaskItemContinuesUnchecked() {
      XCTAssertEqual(pressReturn("- [ ] todo").text, "- [ ] todo\n- [ ] ")
      XCTAssertEqual(pressReturn("- [x] done").text, "- [x] done\n- [ ] ")
    }

    /// Enter on an empty item ends the list: the marker is removed.
    func testEmptyItemEndsList() {
      let r = pressReturn("- ")
      XCTAssertTrue(r.handled)
      XCTAssertEqual(r.text, "")
      XCTAssertEqual(r.caret, 0)
    }

    func testEmptyOrderedItemEndsList() {
      XCTAssertEqual(pressReturn("1. ").text, "")
    }

    func testEmptyItemAfterContentEndsListOnlyForEmptyLine() {
      // Second line is an empty bullet; Enter there removes just that marker.
      let r = pressReturn("- one\n- ", caret: 8)
      XCTAssertEqual(r.text, "- one\n")
      XCTAssertEqual(r.caret, 6)
    }

    /// A non-list line is left to the text view's own newline handling.
    func testPlainLineNotHandled() {
      let r = pressReturn("hello")
      XCTAssertFalse(r.handled)
      XCTAssertEqual(r.text, "hello")
    }

    /// A thematic break and a hyphenated word must not read as bullets.
    func testHyphenNotMistakenForBullet() {
      XCTAssertFalse(pressReturn("---").handled)
      XCTAssertFalse(pressReturn("-word").handled)
    }

    /// Splitting mid-item carries the trailing text onto the new marker's line.
    func testCaretMidItemSplits() {
      let r = pressReturn("- abcdef", caret: 5)  // caret after "- abc"
      XCTAssertEqual(r.text, "- abc\n- def")
      XCTAssertEqual(r.caret, 8)  // right after the new "- "
    }
  #endif
}
