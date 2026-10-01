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

    // MARK: Typing a bullet

    /// Types `characters` one at a time through the text view, as the keyboard
    /// would, and returns the resulting text and caret.
    private func type(_ characters: String, into text: String, caret: Int? = nil)
      -> (text: String, caret: Int)
    {
      let (coord, tv) = makeEditor(text, caret: caret)
      tv.delegate = coord
      for character in characters {
        tv.insertText(String(character), replacementRange: tv.selectedRange())
      }
      return (tv.string, tv.selectedRange().location)
    }

    func testDashOnEmptyLineAddsNoSpace() {
      let r = type("-", into: "")
      XCTAssertEqual(r.text, "-")
      XCTAssertEqual(r.caret, 1)
      XCTAssertEqual(type("-", into: "x\n  ").text, "x\n  -")
    }

    func testThreeDashesStayARule() {
      XCTAssertEqual(type("---", into: "").text, "---")
    }

    // MARK: Backspace on a marker

    private func backspace(_ text: String, caret: Int? = nil) -> (text: String, caret: Int) {
      let (coord, tv) = makeEditor(text, caret: caret)
      tv.delegate = coord
      tv.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
      return (tv.string, tv.selectedRange().location)
    }

    func testBackspaceDeletesMarkerAndSpace() {
      let r = backspace("- ")
      XCTAssertEqual(r.text, "")
      XCTAssertEqual(r.caret, 0)
      XCTAssertEqual(backspace("x\n  * ").text, "x\n  ")
      XCTAssertEqual(backspace("1. ").text, "")
      XCTAssertEqual(backspace("- abc", caret: 2).text, "abc")
    }

    func testBackspaceElsewhereDeletesOneCharacter() {
      XCTAssertEqual(backspace("- a").text, "- ")
      XCTAssertEqual(backspace("-").text, "")
      XCTAssertEqual(backspace("  ").text, " ")
      XCTAssertEqual(backspace("a- ").text, "a-")
    }

    // MARK: Tab and Shift-Tab

    private func shift(
      _ text: String, caret: Int? = nil, selection: NSRange? = nil, outdent: Bool,
      indent: Int = 2
    ) -> (handled: Bool, text: String, selection: NSRange) {
      let (coord, tv) = makeEditor(text, caret: caret)
      coord.listIndent = indent
      if let selection { tv.setSelectedRange(selection) }
      let handled = coord.shiftListIndent(outdent: outdent)
      return (handled, tv.string, tv.selectedRange())
    }

    func testTabIndentsListItem() {
      let r = shift("- item", outdent: false)
      XCTAssertTrue(r.handled)
      XCTAssertEqual(r.text, "  - item")
      XCTAssertEqual(r.selection, NSRange(location: 8, length: 0))
    }

    /// The bullet keeps its rendered marker tag after being indented, and the
    /// inserted spaces do not inherit it.
    func testTabKeepsBulletMarkerTag() {
      for text in ["- item", "- a\n- b"] {
        let (coord, tv) = makeEditor(text, caret: 0)
        coord.listIndent = 2
        XCTAssertTrue(coord.shiftListIndent(outdent: false))
        let storage = tv.textStorage!
        coord.highlighter.flushPendingParse(storage)
        XCTAssertNil(storage.attribute(.listBulletMarker, at: 0, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.listBulletMarker, at: 1, effectiveRange: nil))
        XCTAssertNotNil(storage.attribute(.listBulletMarker, at: 2, effectiveRange: nil), text)
      }
    }

    func testTabUsesConfiguredIndent() {
      XCTAssertEqual(shift("1. item", outdent: false, indent: 4).text, "    1. item")
    }

    func testShiftTabDedents() {
      let r = shift("    - item", outdent: true)
      XCTAssertTrue(r.handled)
      XCTAssertEqual(r.text, "  - item")
      XCTAssertEqual(r.selection, NSRange(location: 8, length: 0))
    }

    func testShiftTabRemovesOnlyWhatIsThere() {
      let r = shift(" - item", outdent: true, indent: 4)
      XCTAssertEqual(r.text, "- item")
    }

    func testShiftTabAtTopLevelIsHandledAndUnchanged() {
      let r = shift("- item", outdent: true)
      XCTAssertTrue(r.handled)
      XCTAssertEqual(r.text, "- item")
    }

    func testShiftTabRemovesLeadingTab() {
      XCTAssertEqual(shift("\t- item", outdent: true).text, "- item")
    }

    func testTabOutsideListFallsThrough() {
      XCTAssertFalse(shift("plain", outdent: false).handled)
      XCTAssertFalse(shift("plain", outdent: true).handled)
    }

    func testTabIndentsEverySelectedListLine() {
      let text = "- a\n- b\nplain\n- c"
      let r = shift(text, selection: NSRange(location: 0, length: 12), outdent: false)
      XCTAssertEqual(r.text, "  - a\n  - b\nplain\n- c")
      XCTAssertEqual(r.selection, NSRange(location: 2, length: 14))
    }

    func testSelectionEndingAtLineStartExcludesThatLine() {
      let r = shift("- a\n- b", selection: NSRange(location: 0, length: 4), outdent: false)
      XCTAssertEqual(r.text, "  - a\n- b")
    }
  #endif
}
