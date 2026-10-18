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

  /// A `-` line under a list item's text (an empty nested bullet) parses as a
  /// setext underline, but must not turn the item into a heading.
  func testEmptyNestedBulletDoesNotMakeListItemHeading() {
    let md = "- Toggle bold\n    - \n- Change the block style\n"
    let storage = styled(md)

    XCTAssertEqual(
      font(storage, at: 2).pointSize, TextStyle.body.font.pointSize,
      "a list item followed by an empty nested bullet should stay body text")
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

  /// Deep block nesting parses on the first render and after an edit. Up to
  /// about 1000 levels the scanner state fits in its buffer and the blocks
  /// close. Deeper nesting loses scanner state but does not crash.
  func testDeeplyNestedBlocksParse() {
    for depth in [300, 1000, 2000] {
      let md = String(repeating: ">", count: depth) + " deep\n\n# After"
      let storage = styled(md)
      let highlighter = MarkdownHighlighter()
      highlighter.highlight(storage)
      storage.delegate = highlighter
      storage.replaceCharacters(in: NSRange(location: depth, length: 0), with: " very")
      highlighter.flushPendingParse(storage)

      guard depth <= 1000 else { continue }
      XCTAssertEqual(
        font(storage, at: index(of: "After", in: storage.string)).pointSize, 28,
        "depth \(depth)")
    }
  }

  func testFencedCodeBlockIsMonospaced() {
    let md = "```\nlet x = 1\n```"
    let storage = styled(md)
    let loc = index(of: "let x", in: md)
    XCTAssertTrue(isMonospaced(font(storage, at: loc)), "fenced code block should be monospaced")
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

  private func model(_ storage: NSTextStorage, at location: Int) -> TableModel? {
    storage.attribute(.tableModel, at: location, effectiveRange: nil) as? TableModel
  }

  func testPipeTableModelHasCellsAndAlignments() throws {
    let md = "Intro\n\n| a | **b** |\n| :-- | --: |\n| 1 | 2 |\n|x|  |\n\nAfter"
    let storage = styled(md)
    let table = try XCTUnwrap(model(storage, at: index(of: "| a", in: md)))
    XCTAssertEqual(table.grid, [["a", "**b**"], ["1", "2"], ["x", ""]])
    XCTAssertEqual(table.alignments, [.left, .right])
    XCTAssertEqual(table.range.location, index(of: "| a", in: md))
    XCTAssertEqual(NSMaxRange(table.range), index(of: "\n\nAfter", in: md))
    let empty = table.rows[2].cells[1]
    XCTAssertEqual(empty.range.length, 0)
    XCTAssertEqual(empty.range.location, index(of: "|  |", in: md) + 2)
  }

  /// The model covers every character of the table, delimiter row included,
  /// and nothing outside it. A blank line ends the table. A line directly
  /// after it would be another row.
  func testPipeTableModelCoversOnlyTheTable() throws {
    let md = "Intro\n| a | b |\n| - | - |\n| 1 | 2 |\n\nAfter"
    let storage = styled(md)
    let table = try XCTUnwrap(model(storage, at: index(of: "| a", in: md)))
    for location in table.range.location..<NSMaxRange(table.range) {
      XCTAssertTrue(model(storage, at: location) === table, "character \(location) is in the table")
    }
    XCTAssertNil(model(storage, at: index(of: "Intro", in: md)))
    XCTAssertNil(model(storage, at: index(of: "After", in: md)))
    XCTAssertNil(model(storage, at: NSMaxRange(table.range)), "the final line break is not")
  }

  /// A short row reports blank cells up to the table column count.
  func testPipeTableShortRowIsPadded() throws {
    let md = "| a | b | c |\n| - | - | - |\n| 1 |"
    let table = try XCTUnwrap(model(styled(md), at: 0))
    XCTAssertEqual(table.columnCount, 3)
    XCTAssertEqual(table.grid[1], ["1", "", ""])
    XCTAssertEqual(table.rows[1].cells.count, 1)
  }

  /// With the experimental flag off a table is left as plain text with no
  /// model. Cell contents still get emphasis.
  func testPipeTableDisabledLeavesPlainText() {
    Typography.tablesEnabled = false
    defer { Typography.tablesEnabled = true }
    let md = "| a | b |\n| - | - |\n| **x** | 2 |"
    let storage = styled(md)
    XCTAssertNil(model(storage, at: 0), "a disabled table should carry no model")
    XCTAssertTrue(isBold(font(storage, at: index(of: "x", in: md))), "**x** in a cell still bolds")
  }

  /// An edit inside a table reparses immediately, so the model already
  /// describes the edited text when the edit returns.
  func testPipeTableModelIsFreshAfterAKeystroke() throws {
    let storage = NSTextStorage(string: "| a | b |\n| - | - |\n| 1 | 2 |\n\nAfter")
    let highlighter = MarkdownHighlighter()
    highlighter.highlight(storage)
    storage.delegate = highlighter

    let one = index(of: "1", in: storage.string)
    storage.replaceCharacters(in: NSRange(location: one + 1, length: 0), with: "23")
    let table = try XCTUnwrap(model(storage, at: 0))
    XCTAssertEqual(table.grid[1], ["123", "2"])
    XCTAssertEqual(NSMaxRange(table.range), index(of: "\n\nAfter", in: storage.string))
    XCTAssertTrue(model(storage, at: NSMaxRange(table.range) - 1) === table)
  }

  func testTableMarkdownRoundTrips() throws {
    let markdown = TableModel.markdown(
      cells: [["a", "b"], ["1 | 2", ""]], alignments: [.center, .none])
    XCTAssertEqual(markdown, "| a | b |\n| :---: | --- |\n| 1 \\| 2 |  |")
    let table = try XCTUnwrap(model(styled(markdown), at: 0))
    XCTAssertEqual(table.grid, [["a", "b"], ["1 \\| 2", ""]])
    XCTAssertEqual(table.alignments, [.center, .none])
  }

  func testTableEscapingKeepsEscapedPipes() {
    XCTAssertEqual(TableModel.escaped("a|b"), "a\\|b")
    XCTAssertEqual(TableModel.escaped("a\\|b"), "a\\|b")
    XCTAssertEqual(TableModel.escaped("a\nb"), "a b")
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

  func testInlineCodeInHeadingScalesWithHeading() {
    let md = "# a `code` b"
    let expected = (font(styled(md), at: 2).pointSize * Typography.codeRatio).rounded()
    for storage in [styled(md), typed(md)] {
      let f = font(storage, at: index(of: "code", in: md))
      XCTAssertTrue(isMonospaced(f))
      XCTAssertEqual(f.pointSize, expected, "code in a heading should scale with the heading")
    }
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

  /// Setext headings (`===`, `---` underlines) are not styled, only ATX ones.
  func testSetextHeadingsAreNotStyled() {
    for md in ["Title\n=====\n\nbody", "Title\n-----\n\nbody"] {
      let storage = styled(md)

      XCTAssertEqual(
        font(storage, at: 0).pointSize, TextStyle.body.font.pointSize,
        "a setext heading should stay body text")
    }
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
