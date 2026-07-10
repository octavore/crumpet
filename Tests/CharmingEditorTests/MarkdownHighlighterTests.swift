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
