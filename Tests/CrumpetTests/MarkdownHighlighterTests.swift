import XCTest

@testable import Crumpet

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Exercises `MarkdownHighlighter` directly against an `NSTextStorage`, both for
/// a one-shot parse and for the incremental "type a character at a time" path the
/// editor actually uses.
@MainActor
final class MarkdownHighlighterTests: XCTestCase {

  // Table rendering is opt-in (experimental); the table cases below assume it on.
  override func setUp() {
    super.setUp()
    Typography.tablesEnabled = true
  }

  override func tearDown() {
    Typography.tablesEnabled = Typography.defaultTablesEnabled
    super.tearDown()
  }

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

  func testPipeTableIsMonospaced() {
    let md = "| a | b |\n| - | - |\n| 1 | 2 |"
    let storage = styled(md)
    XCTAssertTrue(
      isMonospaced(font(storage, at: index(of: "1", in: md))), "table body should be monospaced")
    XCTAssertTrue(
      isMonospaced(font(storage, at: index(of: "a", in: md))), "table header should be monospaced")
  }

  func testPipeTableHeaderIsBold() {
    let md = "| a | b |\n| - | - |\n| 1 | 2 |"
    let storage = styled(md)
    XCTAssertTrue(isBold(font(storage, at: index(of: "a", in: md))), "header cell should be bold")
    XCTAssertFalse(
      isBold(font(storage, at: index(of: "1", in: md))), "body cell should not be bold")
  }

  func testPipeTableEmphasisInCell() {
    let md = "| a | b |\n| - | - |\n| **x** | y |"
    let storage = styled(md)
    XCTAssertTrue(
      isBold(font(storage, at: index(of: "x", in: md))), "**x** in a cell should be bold")
  }

  func testPipeTableStyledWhileTyping() {
    let storage = typed("| a | b |\n| - | - |\n| 1 | 2 |")
    let s = storage.string
    XCTAssertTrue(isMonospaced(font(storage, at: index(of: "1", in: s))))
    XCTAssertTrue(isBold(font(storage, at: index(of: "a", in: s))))
  }

  // MARK: List bullets

  func testUnorderedBulletCharacterIsTagged() {
    let md = "- one\n* two\n+ three\n1. four"
    let storage = styled(md)
    for marker in ["-", "*", "+"] {
      let loc = index(of: marker, in: md)
      XCTAssertNotNil(
        storage.attribute(.listBulletMarker, at: loc, effectiveRange: nil),
        "\(marker) bullet should be tagged")
    }
    // The ordered marker's digit is left alone.
    XCTAssertNil(
      storage.attribute(.listBulletMarker, at: index(of: "1. four", in: md), effectiveRange: nil))
  }

  func testBulletTagOnlyCoversTheMarker() {
    let md = "- item"
    let storage = styled(md)
    XCTAssertNil(
      storage.attribute(.listBulletMarker, at: index(of: "item", in: md), effectiveRange: nil))
  }

  /// An enlarged marker glyph (a scaled `ListBulletStyle`) must not leak its
  /// font onto the item's text. The marker font is layered in the inline pass
  /// so `stampBlockBase` never records it as the item's block base and smears
  /// it across every character the next keystroke restyles.
  func testScaledMarkerFontStaysOnTheMarker() {
    let previous = Typography.listBulletStyle
    Typography.listBulletStyle = .disc
    defer { Typography.listBulletStyle = previous }

    // Type the item, let the whole-document parse settle, then type one more
    // character: the keystroke restyles the paragraph from its recorded block
    // base, which is where a marker font would have leaked in.
    let storage = typed("- hello")
    storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "x")

    let content = index(of: "hello", in: "- hellox")
    XCTAssertEqual(
      font(storage, at: content).pointSize, TextStyle.body.font.pointSize,
      "item text should keep the body font size after a keystroke")
    XCTAssertEqual(
      font(storage, at: storage.length - 1).pointSize, TextStyle.body.font.pointSize,
      "the just-typed character should be the body font size")
    XCTAssertNil(
      storage.attribute(.baselineOffset, at: content, effectiveRange: nil),
      "the marker's baseline offset should not reach the item text")
  }

  // MARK: Tables

  /// Every `|` in `md` carries the attribute that hides it, and no other
  /// character does (outside the delimiter row, which is hidden whole).
  private func hiddenPipes(_ storage: NSTextStorage) -> Bool {
    let source = storage.string as NSString
    for index in 0..<source.length where source.character(at: index) == 0x7C {
      // The delimiter row's pipes go with the rest of that row, which is hidden
      // by being drawn in no colour rather than by null glyphs.
      let row = storage.attribute(.tableRow, at: index, effectiveRange: nil) as? TableRowStyle
      if row?.isDelimiter == true { continue }
      if storage.attribute(.tableHidden, at: index, effectiveRange: nil) == nil { return false }
    }
    return true
  }

  private func row(_ storage: NSTextStorage, at location: Int) -> TableRowStyle? {
    storage.attribute(.tableRow, at: location, effectiveRange: nil) as? TableRowStyle
  }

  /// The rendered extent of the column containing `location`: the width the
  /// cell's glyphs actually occupy, padding included. Measured from the text,
  /// not from the arithmetic that produced the padding.
  private func columnExtent(_ storage: NSTextStorage, at location: Int) -> CGFloat {
    let source = storage.string as NSString
    let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
    var end = paragraph.location + paragraph.length
    while end > paragraph.location, source.character(at: end - 1) == 0x0A { end -= 1 }
    let line = NSRange(location: paragraph.location, length: end - paragraph.location)
    let spans = MarkdownHighlighter.columnSpans(in: line, source: source).spans
    guard let span = spans.first(where: { NSLocationInRange(location, $0) }) else { return 0 }
    let piece = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: span))
    // Drop what renders as nothing (a cell's `**`), but keep the `.kern` that
    // pads the cell: the padding is what's under test.
    var concealed: [NSRange] = []
    piece.enumerateAttribute(.markdownMarker, in: NSRange(location: 0, length: piece.length)) {
      value, range, _ in
      if value != nil { concealed.append(range) }
    }
    for range in concealed.reversed() { piece.deleteCharacters(in: range) }
    return piece.size().width
  }

  func testPipeTableHidesItsPipes() {
    let md = "| a | b |\n| - | - |\n| 1 | 2 |"
    XCTAssertTrue(hiddenPipes(styled(md)), "every table pipe should be hidden")
  }

  /// With the experimental flag off a table is left as plain text: no hidden
  /// pipes, no row layout, no bold header. Cell contents still get emphasis.
  func testPipeTableDisabledLeavesPlainText() {
    Typography.tablesEnabled = false
    defer { Typography.tablesEnabled = true }
    let md = "| a | b |\n| - | - |\n| **x** | 2 |"
    let storage = styled(md)
    XCTAssertNil(
      storage.attribute(.tableHidden, at: index(of: "|", in: md), effectiveRange: nil),
      "a disabled table should not hide its pipes")
    XCTAssertNil(
      storage.attribute(.tableRow, at: index(of: "a", in: md), effectiveRange: nil),
      "a disabled table should carry no row layout")
    XCTAssertFalse(isBold(font(storage, at: index(of: "a", in: md))), "header stays unbolded")
    XCTAssertTrue(isBold(font(storage, at: index(of: "x", in: md))), "**x** in a cell still bolds")
  }

  func testPipeTableHidesTheDelimiterRow() {
    let md = "| a | b |\n| - | - |\n| 1 | 2 |"
    let storage = styled(md)
    let dashes = index(of: "-", in: md)
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: dashes, effectiveRange: nil) as? PlatformColor,
      PlatformColor.clear, "the delimiter row should be drawn in no colour")
    XCTAssertEqual(row(storage, at: dashes)?.isDelimiter, true)
    XCTAssertEqual(row(storage, at: index(of: "a", in: md))?.isHeader, true)
    XCTAssertEqual(row(storage, at: index(of: "1", in: md))?.isDelimiter, false)
  }

  /// The point of the padding: a column occupies the same width in every row,
  /// however differently its cells are written.
  func testPipeTableColumnsShareOneWidth() {
    let md = "| a | b |\n| - | - |\n| longer cell | 2 |\n|x| y |"
    let storage = styled(md)
    let first = columnExtent(storage, at: index(of: "a", in: md))
    XCTAssertGreaterThan(first, 0)
    XCTAssertEqual(
      first, columnExtent(storage, at: index(of: "longer cell", in: md)), accuracy: 0.5)
    XCTAssertEqual(first, columnExtent(storage, at: index(of: "x", in: md)), accuracy: 0.5)
  }

  /// A cell's concealed `**` take no width, so they must not push the column
  /// out by the width they'd have had if they were drawn.
  func testPipeTableEmphasisDoesNotSkewColumnWidth() {
    let plain = "| a | b |\n| - | - |\n| xx | y |"
    let bold = "| a | b |\n| - | - |\n| **xx** | y |"
    let width = { (md: String) in
      self.columnExtent(self.styled(md), at: self.index(of: "xx", in: md))
    }
    XCTAssertEqual(width(plain), width(bold), accuracy: 0.5)
  }

  /// The regression the plan review found: the per-keystroke path resets a
  /// paragraph to its block attributes, which don't include the row's padding
  /// or its hidden pipes. Without an explicit re-apply the row would collapse
  /// on every keystroke and only come back on the 600ms debounce.
  func testPipeTableRowSurvivesAKeystroke() {
    let storage = NSTextStorage(string: "| a | b |\n| - | - |\n| 1 | 2 |")
    let highlighter = MarkdownHighlighter()
    highlighter.highlight(storage)
    storage.delegate = highlighter

    let before = columnExtent(storage, at: index(of: "1", in: storage.string))
    // Type into the last cell, then look *before* the deferred parse runs.
    storage.replaceCharacters(in: NSRange(location: storage.length - 3, length: 0), with: "3")
    XCTAssertTrue(hiddenPipes(storage), "typing should not reveal the row's pipes")
    XCTAssertEqual(
      columnExtent(storage, at: index(of: "1", in: storage.string)), before, accuracy: 0.5,
      "typing should not collapse the row's padding")
  }

  /// A wider cell widens its whole column, once the deferred parse re-measures.
  func testPipeTableColumnWidensForWiderContent() {
    let storage = NSTextStorage(string: "| a | b |\n| - | - |\n| 1 | 2 |")
    let highlighter = MarkdownHighlighter()
    highlighter.highlight(storage)
    storage.delegate = highlighter

    let before = columnExtent(storage, at: index(of: "a", in: storage.string))
    storage.replaceCharacters(in: NSRange(location: 3, length: 0), with: "bcdefgh")
    highlighter.flushPendingParse(storage)
    let header = columnExtent(storage, at: index(of: "abcdefgh", in: storage.string))
    XCTAssertGreaterThan(header, before)
    XCTAssertEqual(
      header, columnExtent(storage, at: index(of: "1", in: storage.string)), accuracy: 0.5,
      "the body cell should widen with its column")
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

  /// Types `insert` at `location` into an already-highlighted `md` and returns
  /// the storage without settling the deferred parse: the mid-keystroke state
  /// the user actually sees, which is where a paragraph read out of context
  /// flashes.
  private func midKeystroke(_ md: String, insert: String, at location: Int) -> NSTextStorage {
    let storage = NSTextStorage(string: md)
    let highlighter = MarkdownHighlighter()
    highlighter.highlight(storage)
    storage.delegate = highlighter
    storage.replaceCharacters(in: NSRange(location: location, length: 0), with: insert)
    return storage
  }

  /// A `#` line inside a fence is not a heading, but parsed alone it is
  /// exactly one, since the fence is in another paragraph. The keystroke path
  /// has to take the enclosing code block from the previous tree.
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

  /// Inline markup is still styled on the keystroke itself: it's decidable
  /// from the paragraph alone, so there is nothing to defer.
  func testInlineMarkupStyledOnKeystroke() {
    let md = "a **bold* b"
    let storage = midKeystroke(md, insert: "*", at: index(of: " b", in: md))

    XCTAssertTrue(
      isBold(font(storage, at: index(of: "bold", in: md))),
      "closing an emphasis span should bold it without waiting for the deferred parse")
  }

  /// Typing a block marker still takes effect as you type it: the edit lands in the
  /// line's marker run, which skips the debounce and runs the real parse at once.
  /// No flush here: this is the keystroke itself.
  func testTypedHeadingMarkerAppliesOnKeystroke() {
    let storage = midKeystroke("Hello", insert: "# ", at: 0)

    XCTAssertEqual(
      font(storage, at: 2).pointSize, 28, "typing `# ` should make the line a heading immediately")
  }

  /// The `## ` prefix is tagged for concealment, and the tag survives a
  /// keystroke in the heading text before the deferred parse runs.
  func testHeadingMarkerSurvivesAKeystroke() {
    let md = "## Title"
    let storage = NSTextStorage(string: md)
    let highlighter = MarkdownHighlighter()
    highlighter.highlight(storage)
    storage.delegate = highlighter

    for location in 0..<3 {
      XCTAssertNotNil(storage.attribute(.markdownMarker, at: location, effectiveRange: nil))
    }
    XCTAssertNil(storage.attribute(.markdownMarker, at: 3, effectiveRange: nil))

    storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "x")
    for location in 0..<3 {
      XCTAssertNotNil(
        storage.attribute(.markdownMarker, at: location, effectiveRange: nil),
        "typing in the heading should keep its prefix concealable")
    }
    XCTAssertNil(storage.attribute(.markdownMarker, at: 3, effectiveRange: nil))
  }

  /// The heading's reveal span ends at the end of its text, not at the start
  /// of the next line, so a caret moved down off the heading re-conceals it.
  func testHeadingRevealSpanExcludesLineTerminator() {
    let md = "## Title\n\nbody"
    let storage = NSTextStorage(string: md)
    MarkdownHighlighter().highlight(storage)

    let value = storage.attribute(.markdownMarker, at: 0, effectiveRange: nil) as? NSValue
    let span = value.map { MarkerSpan.span(from: $0, markerStart: 0) }
    XCTAssertEqual(span, NSRange(location: 0, length: 8))
  }

  /// And deleting it takes it away again, on the keystroke.
  func testDeletedHeadingMarkerRevertsOnKeystroke() {
    let md = "# Hello"
    let storage = NSTextStorage(string: md)
    let highlighter = MarkdownHighlighter()
    highlighter.highlight(storage)
    storage.delegate = highlighter

    storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
    XCTAssertEqual(
      font(storage, at: index(of: "Hello", in: md) - 1).pointSize, TextStyle.body.font.pointSize,
      "deleting the `#` should drop the line back to body immediately")
  }

  /// The detector is a trigger, not a decision. A `#` typed at the start of a
  /// line inside a fence trips it exactly like a real heading marker would,
  /// and the parse it triggers correctly leaves the line as code.
  func testTypedHashInsideFenceIsNotPromoted() {
    let md = "```\nfoo\n```"
    let loc = index(of: "foo", in: md)
    let storage = midKeystroke(md, insert: "# ", at: loc)

    let f = font(storage, at: loc + 2)
    XCTAssertTrue(isMonospaced(f), "a `#` typed inside a fence is code, not a heading")
    XCTAssertEqual(f.pointSize, TextStyle.body.font.pointSize)
  }

  /// A line typed fresh into an existing fence is text the last full parse
  /// never saw, so it has no recorded block style; it still has to come out
  /// as code.
  func testNewLineInsideFenceIsCode() {
    let md = "```\nlet x = 1\n```"
    let storage = midKeystroke(md, insert: "y", at: index(of: "\n```", in: md))

    XCTAssertTrue(
      isMonospaced(font(storage, at: index(of: "let x", in: md) + 9)),
      "text typed inside a fence should be monospaced immediately")
  }

  // MARK: Incremental vs. full parse

  /// A compact, comparable description of a character's styling.
  private func signature(_ storage: NSTextStorage, at location: Int) -> String {
    let f = font(storage, at: location)
    return
      "\(Int(f.pointSize))/\(isMonospaced(f) ? "m" : "-")/\(isBold(f) ? "b" : "-")/\(isItalic(f) ? "i" : "-")"
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
