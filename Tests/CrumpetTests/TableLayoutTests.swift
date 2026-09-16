#if canImport(AppKit)
  import AppKit
  import SwiftUI
  import XCTest

  @testable import Crumpet

  /// Exercises a table through the real TextKit 1 stack the editor builds:
  /// `EditorLayoutManager`, with the coordinator concealing glyphs and
  /// collapsing the delimiter row. The highlighter tests check the attributes;
  /// these check what the layout does with them, which is where the grid's one
  /// real assumption lives — that a column's padded text occupies exactly the
  /// width the grid is stroked at.
  @MainActor
  final class TableLayoutTests: XCTestCase {
    private nonisolated(unsafe) static var coordinatorKey = 0

    // Table rendering is opt-in (experimental); this whole suite assumes it on.
    override func setUp() {
      super.setUp()
      Typography.tablesEnabled = true
    }

    override func tearDown() {
      Typography.tablesEnabled = Typography.defaultTablesEnabled
      super.tearDown()
    }

    private func makeStack(_ markdown: String) -> NSTextView {
      var backing = markdown
      let binding = Binding(get: { backing }, set: { backing = $0 })
      let coordinator = TextViewEditor.Coordinator(text: binding, commands: EditorCommands())

      let storage = NSTextStorage(string: markdown)
      let layoutManager = EditorLayoutManager()
      storage.addLayoutManager(layoutManager)
      let container = NSTextContainer(
        size: NSSize(width: 900, height: CGFloat.greatestFiniteMagnitude))
      container.widthTracksTextView = true
      layoutManager.addTextContainer(container)

      let tv = NSTextView(
        frame: NSRect(x: 0, y: 0, width: 900, height: 800), textContainer: container)
      storage.delegate = coordinator.highlighter
      layoutManager.delegate = coordinator
      coordinator.textView = tv
      coordinator.highlighter.highlight(storage)
      layoutManager.ensureLayout(for: container)
      // The coordinator and the storage hold each other's only strong refs here.
      objc_setAssociatedObject(tv, &Self.coordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN)
      objc_setAssociatedObject(tv, &Self.storageKey, storage, .OBJC_ASSOCIATION_RETAIN)
      return tv
    }

    private nonisolated(unsafe) static var storageKey = 0

    private func paragraphs(_ tv: NSTextView) -> [NSRange] {
      let source = tv.string as NSString
      var result: [NSRange] = []
      var location = 0
      while location < source.length {
        let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
        result.append(paragraph)
        location = paragraph.location + paragraph.length
      }
      return result
    }

    private func fragmentHeight(_ tv: NSTextView, of paragraph: NSRange) -> CGFloat {
      let manager = tv.layoutManager!
      let glyphs = manager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
      return manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).height
    }

    private let table = """
      | Shortcut | Does | Notes |
      | :-- | :-: | --: |
      | B | **bold** | wraps the selection |
      | I | *italic* | one `*` |
      """

    /// The grid's boundaries are drawn at the running total of the measured
    /// column widths. That is only right if a row's padded text actually lands
    /// there, so check it where the layout puts each `|`, which is the boundary
    /// the drawn line replaces.
    func testColumnBoundariesMatchTheDrawnGrid() {
      let tv = makeStack(table)
      let manager = tv.layoutManager!
      let source = tv.string as NSString
      let storage = tv.textStorage!

      var checked = 0
      for paragraph in paragraphs(tv) {
        guard
          let row = storage.attribute(.tableRow, at: paragraph.location, effectiveRange: nil)
            as? TableRowStyle, !row.isDelimiter
        else { continue }

        var boundaries: [CGFloat] = []
        var running: CGFloat = 0
        for width in row.columns.widths {
          running += width
          boundaries.append(running)
        }

        // Every `|` after the first closes a column, in order. Positions are
        // measured from the row's own left edge, which sits one
        // `lineFragmentPadding` inside the line fragment.
        let padding = tv.textContainer!.lineFragmentPadding
        var index = paragraph.location
        var column = 0
        while index < paragraph.location + paragraph.length {
          defer { index += 1 }
          guard source.character(at: index) == 0x7C else { continue }
          let glyph = manager.glyphIndexForCharacter(at: index)
          let x = manager.location(forGlyphAt: glyph).x - padding
          // The row's opening `|` is skipped: it's the first glyph of its line
          // fragment, and a null glyph there has no location worth reading. It
          // closes no column either — the boundaries under test are the ones the
          // grid draws.
          if column > 0, column <= boundaries.count {
            XCTAssertEqual(
              x, boundaries[column - 1], accuracy: 0.5,
              "column \(column - 1) should end where the grid line is drawn")
            checked += 1
          }
          column += 1
        }
      }
      XCTAssertGreaterThan(checked, 4, "the table should have contributed several boundaries")
    }

    /// The `|---|` row leaves the visible layout entirely, in every reveal mode:
    /// the grid is what it means, and the grid is drawn, not typed.
    func testDelimiterRowCollapses() {
      for mode in [MarkerRevealMode.span, .line, .always] {
        Typography.revealMode = mode
        let tv = makeStack(table)
        let rows = paragraphs(tv)
        XCTAssertLessThanOrEqual(
          fragmentHeight(tv, of: rows[1]), 2,
          "the delimiter row should collapse to a hairline in \(mode) mode")
        XCTAssertGreaterThan(
          fragmentHeight(tv, of: rows[0]), 2,
          "the header row should keep its height in \(mode) mode")
      }
      Typography.revealMode = .span
    }

    /// Renders the editor offscreen and writes a PNG, so the grid can be looked
    /// at rather than only asserted about. Skipped unless `CRUMPET_SNAPSHOT`
    /// names a file to write.
    func testRenderSnapshot() throws {
      guard let path = ProcessInfo.processInfo.environment["CRUMPET_SNAPSHOT"] else { return }
      let markdown = """
        # Tables

        | Shortcut | Does | Notes |
        | :-- | :-: | --: |
        | ⌘B | **bold** | wraps the selection |
        | ⌘I | *italic* | one `*` |
        | ⌥⌘1 | title | the whole line |

        Text after the table.
        """
      let tv = makeStack(markdown)
      tv.setEditorBackground(.editorBackground)
      guard let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds) else { return }
      tv.cacheDisplay(in: tv.bounds, to: rep)
      let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: path))
    }

    /// A table's pipes never reveal, even with the caret on them and the reveal
    /// mode set to never conceal anything: a pipe given its advance back would
    /// pull every column off the line drawn at its boundary.
    func testPipesStayHiddenWhateverTheRevealMode() {
      Typography.revealMode = .always
      defer { Typography.revealMode = .span }
      let tv = makeStack(table)
      tv.setSelectedRange(NSRange(location: 0, length: 0))
      let manager = tv.layoutManager!
      let glyph = manager.glyphIndexForCharacter(at: 0)
      XCTAssertEqual(
        manager.propertyForGlyph(at: glyph), .null, "a table pipe should never draw")
    }
  }
#endif
