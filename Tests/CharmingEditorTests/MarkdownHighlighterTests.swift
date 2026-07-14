import XCTest

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@testable import CharmingEditor

/// Exercises `MarkdownHighlighter` directly against an `NSTextStorage`, both for
/// a one-shot parse and for the incremental "type a character at a time" path the
/// editor actually uses.
@MainActor
final class MarkdownHighlighterTests: XCTestCase {

  // MARK: Helpers

  /// Highlights `markdown` in a fresh storage (the one-shot / first-render path).
  private func styled(_ markdown: String) -> NSTextStorage {
    let storage = NSTextStorage(string: markdown)
    MarkdownHighlighter().highlight(storage)
    return storage
  }

  /// Builds `markdown` one appended character at a time through the incremental
  /// path: the highlighter is the storage's delegate, so each insertion drives
  /// `didProcessEditing` exactly as the live text view does while you type.
  private func typed(_ markdown: String) -> NSTextStorage {
    let storage = NSTextStorage(string: "")
    let highlighter = MarkdownHighlighter()
    storage.delegate = highlighter
    for ch in markdown {
      storage.replaceCharacters(
        in: NSRange(location: storage.length, length: 0), with: String(ch))
    }
    // Settle the debounced whole-document reparse so multi-paragraph structure
    // (a code fence) reaches the same state the live editor shows once idle.
    highlighter.flushPendingParse(storage)
    return storage
  }

  private func font(_ storage: NSTextStorage, at location: Int) -> PlatformFont {
    let value = storage.attribute(.font, at: location, effectiveRange: nil)
    return value as? PlatformFont ?? TextStyle.body.font
  }

  private func isMonospaced(_ font: PlatformFont) -> Bool {
    font.fontDescriptor.symbolicTraits.contains(.monoSpace)
  }

  private func isBold(_ font: PlatformFont) -> Bool {
    font.traits.contains(.boldTrait)
  }

  private func isItalic(_ font: PlatformFont) -> Bool {
    font.traits.contains(.italicTrait)
  }

  /// Index of the first character of `needle` within `haystack`.
  private func index(of needle: String, in haystack: String) -> Int {
    (haystack as NSString).range(of: needle).location
  }

  // MARK: Block-level

  func testHeadingIsTitleFont() {
    let md = "# Hello"
    let storage = styled(md)
    XCTAssertEqual(font(storage, at: index(of: "Hello", in: md)).pointSize, 28)
  }

  func testFencedCodeBlockIsMonospaced() {
    let md = "```\nlet x = 1\n```"
    let storage = styled(md)
    let loc = index(of: "let x", in: md)
    XCTAssertTrue(isMonospaced(font(storage, at: loc)), "fenced code block should be monospaced")
  }

  private func headIndent(_ storage: NSTextStorage, at location: Int) -> CGFloat {
    let value = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil)
    return (value as? NSParagraphStyle)?.headIndent ?? 0
  }

  // MARK: Lists

  func testUnorderedListItemHangsIndent() {
    let md = "- item"
    let storage = styled(md)
    XCTAssertGreaterThan(
      headIndent(storage, at: index(of: "item", in: md)), 0,
      "an unordered list item should hang-indent its wrapped lines")
  }

  func testOrderedListItemHangsIndent() {
    let md = "1. item"
    let storage = styled(md)
    XCTAssertGreaterThan(
      headIndent(storage, at: index(of: "item", in: md)), 0,
      "an ordered list item should hang-indent its wrapped lines")
  }

  /// A wider marker (`10.` vs `1.`) yields a wider hanging indent.
  func testWiderMarkerHangsFurther() {
    let one = styled("1. item")
    let ten = styled("10. item")
    XCTAssertGreaterThan(
      headIndent(ten, at: index(of: "item", in: "10. item")),
      headIndent(one, at: index(of: "item", in: "1. item")))
  }

  /// A nested item indents further than the item that contains it.
  func testNestedListIndentsDeeper() {
    let md = "- outer\n  - inner"
    let storage = styled(md)
    XCTAssertGreaterThan(
      headIndent(storage, at: index(of: "inner", in: md)),
      headIndent(storage, at: index(of: "outer", in: md)),
      "a nested list item should hang further than its parent")
  }

  func testUnorderedListItemHangsIndent_typed() {
    let md = "- item"
    let storage = typed(md)
    XCTAssertGreaterThan(
      headIndent(storage, at: index(of: "item", in: md)), 0,
      "a list item typed character by character should still hang-indent")
  }

  /// Deleting the marker demotes the item back to a plain body paragraph with no
  /// hanging indent.
  func testDeletingMarkerRemovesIndent() {
    let storage = NSTextStorage(string: "")
    let highlighter = MarkdownHighlighter()
    storage.delegate = highlighter
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "- item")
    storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "")  // drop "- "
    highlighter.flushPendingParse(storage)
    XCTAssertEqual(
      headIndent(storage, at: index(of: "item", in: "item")), 0,
      "a paragraph that is no longer a list item should lose its hanging indent")
  }

  // MARK: Inline (one-shot)

  func testInlineCodeSpanIsMonospaced_oneShot() {
    let md = "a `code` b"
    let storage = styled(md)
    let loc = index(of: "code", in: md)
    XCTAssertTrue(
      isMonospaced(font(storage, at: loc)),
      "inline code span should be monospaced on a one-shot parse")
  }

  func testBoldIsBold_oneShot() {
    let md = "a **bold** b"
    let storage = styled(md)
    XCTAssertTrue(isBold(font(storage, at: index(of: "bold", in: md))))
  }

  func testItalicIsItalic_oneShot() {
    let md = "a *slanted* b"
    let storage = styled(md)
    XCTAssertTrue(isItalic(font(storage, at: index(of: "slanted", in: md))))
  }

  // MARK: Inline (typed incrementally, "as we type")

  func testInlineCodeSpanIsMonospaced_typed() {
    let md = "a `code` b"
    let storage = typed(md)
    let loc = index(of: "code", in: md)
    XCTAssertTrue(
      isMonospaced(font(storage, at: loc)),
      "inline code span should be monospaced after typing it character by character")
  }

  func testBoldIsBold_typed() {
    let md = "a **bold** b"
    let storage = typed(md)
    XCTAssertTrue(isBold(font(storage, at: index(of: "bold", in: md))))
  }

  func testFencedCodeBlockIsMonospaced_typed() {
    let md = "```\nlet x = 1\n```"
    let storage = typed(md)
    let loc = index(of: "let x", in: md)
    XCTAssertTrue(isMonospaced(font(storage, at: loc)))
  }

  // MARK: Context-dependent paragraphs (transient styling)

  /// Types `insert` at `location` into an already-highlighted `md` and returns the
  /// storage *without* settling the deferred parse — the mid-keystroke state the
  /// user actually sees, which is where a paragraph read out of context flashes.
  private func midKeystroke(_ md: String, insert: String, at location: Int) -> NSTextStorage {
    let storage = NSTextStorage(string: md)
    let highlighter = MarkdownHighlighter()
    highlighter.highlight(storage)
    storage.delegate = highlighter
    storage.replaceCharacters(in: NSRange(location: location, length: 0), with: insert)
    return storage
  }

  /// A `#` line inside a fence is not a heading, but parsed alone it is exactly
  /// one — the fence is in another paragraph. The keystroke path has to take the
  /// enclosing code block from the previous tree.
  func testEditingHashLineInsideFenceStaysCode() {
    let md = "```\n# foo\n```"
    let loc = index(of: "# foo", in: md)
    let storage = midKeystroke(md, insert: "d", at: loc + 5)

    let f = font(storage, at: loc)
    XCTAssertTrue(isMonospaced(f), "a # line inside a fence should stay monospaced while typing")
    XCTAssertEqual(
      f.pointSize, TextStyle.body.font.pointSize,
      "a # line inside a fence should not be sized as a heading while typing")
  }

  /// The mirror case: a setext heading's underline sits *below* the text, so the
  /// text line parsed alone is a plain paragraph. Widening to the enclosing block
  /// keeps it a heading while you edit it.
  func testEditingSetextHeadingStaysHeading() {
    let md = "Title\n=====\n\nbody"
    let storage = midKeystroke(md, insert: "s", at: index(of: "\n", in: md))

    XCTAssertEqual(
      font(storage, at: 0).pointSize, 28,
      "a setext h1's text should stay title-sized while typing")
  }

  /// Widening is capped: a block past the budget falls back to a paragraph-local
  /// parse rather than reparsing an unbounded region on every keystroke. The
  /// styling still has to be right for the paragraph itself.
  func testHugeBlockFallsBackToParagraphParse() {
    let md = "```\n" + String(repeating: "x\n", count: 4000) + "```\n\n# Heading"
    let loc = index(of: "# Heading", in: md)
    let storage = midKeystroke(md, insert: "s", at: loc + 9)

    XCTAssertEqual(
      font(storage, at: loc).pointSize, 28,
      "a heading outside the oversized fence should still be styled")
    XCTAssertTrue(
      isMonospaced(font(storage, at: 6)), "the oversized fence should still be code")
  }

  // MARK: Incremental vs. full parse

  /// A compact, comparable description of a character's styling.
  private func signature(_ storage: NSTextStorage, at location: Int) -> String {
    let f = font(storage, at: location)
    return "\(Int(f.pointSize))/\(isMonospaced(f) ? "m" : "-")/\(isBold(f) ? "b" : "-")/\(isItalic(f) ? "i" : "-")"
  }

  /// Applies `edits` (each replaces `range` with a string) to a storage,
  /// re-highlighting after each one, then asserts every character ends up with
  /// the same style a fresh one-shot parse of the final text produces.
  private func assertIncrementalMatchesFull(
    _ edits: [(NSRange, String)], file: StaticString = #filePath, line: UInt = #line
  ) {
    let storage = NSTextStorage(string: "")
    let highlighter = MarkdownHighlighter()
    storage.delegate = highlighter
    for (range, replacement) in edits {
      storage.replaceCharacters(in: range, with: replacement)
    }
    highlighter.flushPendingParse(storage)
    let full = styled(storage.string)
    let md = storage.string
    for i in 0..<(md as NSString).length {
      XCTAssertEqual(
        signature(storage, at: i), signature(full, at: i),
        "char \(i) (\((md as NSString).substring(with: NSRange(location: i, length: 1)).debugDescription)) "
          + "differs between incremental and full parse of \(md.debugDescription)",
        file: file, line: line)
    }
  }

  /// Wrapping an existing word in backticks by inserting the closing then the
  /// opening backtick: the caret moves left, the classic "select word, add
  /// code formatting" motion.
  func testWrapWordInBackticks() {
    let start = "a code b"
    assertIncrementalMatchesFull([
      (NSRange(location: 0, length: 0), start),  // "a code b"
      (NSRange(location: 6, length: 0), "`"),  // "a code` b"
      (NSRange(location: 2, length: 0), "`"),  // "a `code` b"
    ])
  }

  /// Inserting a code span in the middle of a finished paragraph.
  func testInsertCodeSpanInMiddle() {
    assertIncrementalMatchesFull([
      (NSRange(location: 0, length: 0), "before  after"),
      (NSRange(location: 7, length: 0), "`code`"),  // "before `code` after"
    ])
  }

  /// Turning an existing body line into a heading by typing "# " in front.
  func testPromoteLineToHeading() {
    assertIncrementalMatchesFull([
      (NSRange(location: 0, length: 0), "Hello"),
      (NSRange(location: 0, length: 0), "#"),
      (NSRange(location: 1, length: 0), " "),  // "# Hello"
    ])
  }

  /// Removing a backtick should *unstyle* the former code span.
  func testDeletingBacktickUnstyles() {
    assertIncrementalMatchesFull([
      (NSRange(location: 0, length: 0), "a `code` b"),
      (NSRange(location: 7, length: 1), ""),  // "a `code b", no longer a span
    ])
  }
}
