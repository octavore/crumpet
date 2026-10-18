#if canImport(AppKit)
  import AppKit
  import SwiftUI
  import XCTest

  @testable import Crumpet

  /// Exercises tables through the real TextKit 1 stack the editor builds, with
  /// the coordinator concealing the source, reserving the table space, and
  /// placing a `TableWidgetView` over it.
  @MainActor
  final class TableLayoutTests: XCTestCase {
    private nonisolated(unsafe) static var coordinatorKey = 0
    private nonisolated(unsafe) static var storageKey = 0

    override func setUp() {
      super.setUp()
      Typography.tablesEnabled = true
    }

    override func tearDown() {
      Typography.tablesEnabled = Typography.defaultTablesEnabled
      super.tearDown()
    }

    private func makeStack(_ markdown: String) -> (NSTextView, TextViewEditor.Coordinator) {
      var backing = markdown
      let binding = Binding(get: { backing }, set: { backing = $0 })
      let coordinator = TextViewEditor.Coordinator(text: binding, commands: EditorCommands())

      let storage = NSTextStorage(string: markdown)
      let layoutManager = EditorLayoutManager()
      storage.addLayoutManager(layoutManager)
      let container = NSTextContainer(
        size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
      container.widthTracksTextView = true
      layoutManager.addTextContainer(container)

      let tv = NSTextView(
        frame: NSRect(x: 0, y: 0, width: 600, height: 800), textContainer: container)
      tv.allowsUndo = true
      storage.delegate = coordinator.highlighter
      layoutManager.delegate = coordinator
      coordinator.textView = tv
      coordinator.storage = storage
      coordinator.highlighter.highlight(storage)
      layoutManager.ensureLayout(for: container)
      coordinator.syncTables()
      // The coordinator and the storage hold each other's only strong refs here.
      objc_setAssociatedObject(tv, &Self.coordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN)
      objc_setAssociatedObject(tv, &Self.storageKey, storage, .OBJC_ASSOCIATION_RETAIN)
      return (tv, coordinator)
    }

    private func index(of needle: String, in tv: NSTextView) -> Int {
      (tv.string as NSString).range(of: needle).location
    }

    private func fragment(_ tv: NSTextView, at location: Int) -> CGRect {
      let manager = tv.layoutManager!
      return manager.lineFragmentRect(
        forGlyphAt: manager.glyphIndexForCharacter(at: location), effectiveRange: nil)
    }

    private func table(_ tv: NSTextView, at location: Int = 0) throws -> TableModel {
      try XCTUnwrap(
        tv.textStorage?.attribute(.tableModel, at: location, effectiveRange: nil) as? TableModel)
    }

    private let markdown = """
      Before
      | Shortcut | Does | Notes |
      | :-- | :-: | --: |
      | B | **bold** | wraps the selection |
      | I | *italic* | one `*` |

      After
      """

    /// The table lays out as one line the height of the table, and the next
    /// line starts immediately below it.
    func testTableReservesItsHeight() throws {
      let (tv, _) = makeStack(markdown)
      let start = index(of: "| Shortcut", in: tv)
      let model = try table(tv, at: start)
      let container = tv.textContainer!
      let geometry = model.geometry(
        maxWidth: container.size.width - 2 * container.lineFragmentPadding)

      let line = fragment(tv, at: start)
      XCTAssertEqual(line.height, geometry.lineHeight, accuracy: 0.5)
      // The blank line after the table.
      let after = fragment(tv, at: index(of: "\n\nAfter", in: tv) + 1)
      XCTAssertEqual(after.minY, line.maxY, accuracy: 0.5, "no space is left by the hidden rows")
      XCTAssertGreaterThan(geometry.contentHeight, 0)
      XCTAssertEqual(geometry.rowHeights.count, 3)
      XCTAssertEqual(geometry.columnWidths.count, 3)
    }

    /// The table source does not draw in the concealing reveal modes, even
    /// with the caret on it.
    func testTableSourceIsConcealed() throws {
      defer { Typography.revealMode = .span }
      for mode in [MarkerRevealMode.span, .line] {
        Typography.revealMode = mode
        let (tv, _) = makeStack(markdown)
        let model = try table(tv, at: index(of: "| Shortcut", in: tv))
        tv.setSelectedRange(NSRange(location: model.range.location + 3, length: 0))
        let manager = tv.layoutManager!
        for location in model.range.location..<NSMaxRange(model.range) {
          let property = manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: location))
          let expected: NSLayoutManager.GlyphProperty =
            location == model.range.location ? .controlCharacter : .null
          XCTAssertEqual(property, expected, "character \(location) in \(mode) mode")
        }
      }
    }

    private func isConcealed(_ tv: NSTextView, at location: Int) -> Bool {
      let manager = tv.layoutManager!
      return manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: location)) == .null
    }

    /// With every marker revealed, tables show as Markdown source too.
    func testAlwaysRevealShowsTableSource() throws {
      Typography.revealMode = .always
      defer { Typography.revealMode = .span }
      let (tv, coordinator) = makeStack(markdown)
      let start = index(of: "| Shortcut", in: tv)
      XCTAssertTrue(coordinator.tableWidgets.isEmpty)
      XCTAssertFalse(isConcealed(tv, at: start + 2))
      XCTAssertGreaterThan(fragment(tv, at: index(of: "| B", in: tv)).height, 0)
    }

    /// "Edit as Markdown" shows one table as source with the caret in the
    /// chosen cell, until the caret leaves the table.
    func testEditAsMarkdownShowsSourceUntilTheCaretLeaves() throws {
      let (tv, coordinator) = makeStack(markdown)
      let start = index(of: "| Shortcut", in: tv)
      let widget = try XCTUnwrap(coordinator.tableWidgets.first)
      coordinator.tableWidget(
        widget, perform: .editMarkdown, at: TableCellPosition(row: 1, column: 1))
      XCTAssertTrue(coordinator.tableWidgets.isEmpty)
      XCTAssertFalse(isConcealed(tv, at: start + 2))
      XCTAssertEqual(
        tv.selectedRange().location, NSMaxRange((tv.string as NSString).range(of: "**bold**")))

      // Typing in the source keeps it shown as source.
      let caret = tv.selectedRange().location
      tv.textStorage!.replaceCharacters(in: NSRange(location: caret, length: 0), with: "!")
      tv.setSelectedRange(NSRange(location: caret + 1, length: 0))
      coordinator.updateRawTable(for: tv.selectedRange())
      XCTAssertEqual(coordinator.rawTableStart, start)

      tv.setSelectedRange(NSRange(location: 0, length: 0))
      coordinator.updateRawTable(for: tv.selectedRange())
      coordinator.syncTables()
      XCTAssertNil(coordinator.rawTableStart)
      XCTAssertEqual(coordinator.tableWidgets.count, 1)
      XCTAssertTrue(isConcealed(tv, at: start + 2))
      XCTAssertEqual(coordinator.tableWidgets.first?.model.text(row: 1, column: 1), "**bold**!")
    }

    /// One widget is placed over the reserved space, showing the cells.
    func testWidgetIsPlacedOverTheTable() throws {
      let (tv, coordinator) = makeStack(markdown)
      XCTAssertEqual(coordinator.tableWidgets.count, 1)
      let widget = try XCTUnwrap(coordinator.tableWidgets.first)
      XCTAssertTrue(widget.superview === tv)
      let line = fragment(tv, at: index(of: "| Shortcut", in: tv))
      XCTAssertEqual(
        widget.frame.minY, tv.textContainerOrigin.y + line.minY + TableGeometry.margin,
        accuracy: 0.5)
      XCTAssertEqual(
        widget.frame.height, widget.geometry.contentHeight + 2 * TableGeometry.border,
        accuracy: 0.5)
      XCTAssertEqual(widget.model.grid[1], ["B", "**bold**", "wraps the selection"])
    }

    /// Removing the table removes its widget.
    func testWidgetIsRemovedWithTheTable() throws {
      let (tv, coordinator) = makeStack(markdown)
      let model = try table(tv, at: index(of: "| Shortcut", in: tv))
      tv.textStorage!.replaceCharacters(in: model.range, with: "plain")
      coordinator.highlighter.flushPendingParse(tv.textStorage!)
      coordinator.syncTables()
      XCTAssertTrue(coordinator.tableWidgets.isEmpty)
    }

    /// A cell edit replaces only that cell's source, and leaves a model that
    /// describes the new text.
    func testCellEditWritesTheSource() throws {
      let (tv, coordinator) = makeStack(markdown)
      let widget = try XCTUnwrap(coordinator.tableWidgets.first)
      coordinator.tableWidget(
        widget, didEditCellAt: TableCellPosition(row: 1, column: 0), text: "Bold | B")
      XCTAssertTrue(tv.string.contains("| Bold \\| B | **bold** |"), tv.string)
      XCTAssertEqual(widget.model.text(row: 1, column: 0), "Bold \\| B")
      XCTAssertTrue(try table(tv, at: index(of: "| Shortcut", in: tv)) === widget.model)

      coordinator.tableWidget(
        widget, didEditCellAt: TableCellPosition(row: 2, column: 2), text: "")
      XCTAssertTrue(tv.string.contains("| I | *italic* |  |"), tv.string)
    }

    /// Tab in the last cell adds a row.
    func testTabInTheLastCellAddsARow() throws {
      let (tv, coordinator) = makeStack(markdown)
      let widget = try XCTUnwrap(coordinator.tableWidgets.first)
      coordinator.tableWidget(
        widget, navigate: .nextCell, from: TableCellPosition(row: 2, column: 2))
      XCTAssertEqual(widget.model.rows.count, 4)
      XCTAssertTrue(
        tv.string.contains("| I | *italic* | one `*` |\n|  |  |  |\n\nAfter"), tv.string)
      XCTAssertTrue(tv.string.contains("| :--- | :---: | ---: |"), "alignments are kept")
    }

    func testColumnOperations() throws {
      let (tv, coordinator) = makeStack("| a | b |\n| - | - |\n| 1 | 2 |")
      let widget = try XCTUnwrap(coordinator.tableWidgets.first)
      coordinator.tableWidget(
        widget, perform: .insertColumnRight, at: TableCellPosition(row: 1, column: 0))
      XCTAssertEqual(widget.model.grid, [["a", "", "b"], ["1", "", "2"]])
      coordinator.tableWidget(
        widget, perform: .alignRight, at: TableCellPosition(row: 0, column: 2))
      XCTAssertEqual(widget.model.alignments, [.none, .none, .right])
      coordinator.tableWidget(
        widget, perform: .deleteColumn, at: TableCellPosition(row: 0, column: 0))
      XCTAssertEqual(widget.model.grid, [["", "b"], ["", "2"]])
      XCTAssertEqual(tv.string, "|  | b |\n| --- | ---: |\n|  | 2 |")
    }

    /// Zero-width cells are empty cells. A row operation keeps their rows.
    func testZeroWidthCellsAreKept() throws {
      let (tv, coordinator) = makeStack(
        "| a | b | c |\n| - | - | - |\n| 1 || 3 |\n||||\n| 4 | 5 | 6 |\n\nAfter")
      let widget = try XCTUnwrap(coordinator.tableWidgets.first)
      XCTAssertEqual(
        widget.model.grid, [["a", "b", "c"], ["1", "", "3"], ["", "", ""], ["4", "5", "6"]])
      coordinator.tableWidget(
        widget, perform: .insertRowBelow, at: TableCellPosition(row: 3, column: 0))
      XCTAssertEqual(
        widget.model.grid,
        [["a", "b", "c"], ["1", "", "3"], ["", "", ""], ["4", "5", "6"], ["", "", ""]])
      XCTAssertTrue(tv.string.hasSuffix("|  |  |  |\n\nAfter"), tv.string)
    }

    func testRowOperations() throws {
      let (tv, coordinator) = makeStack("| a |\n| - |\n| 1 |\n| 2 |\n\nAfter")
      let widget = try XCTUnwrap(coordinator.tableWidgets.first)
      coordinator.tableWidget(
        widget, perform: .insertRowAbove, at: TableCellPosition(row: 2, column: 0))
      XCTAssertEqual(widget.model.grid, [["a"], ["1"], [""], ["2"]])
      coordinator.tableWidget(
        widget, perform: .deleteRow, at: TableCellPosition(row: 1, column: 0))
      XCTAssertEqual(widget.model.grid, [["a"], [""], ["2"]])
      coordinator.tableWidget(
        widget, perform: .deleteTable, at: TableCellPosition(row: 1, column: 0))
      XCTAssertEqual(tv.string, "\nAfter")
      XCTAssertTrue(coordinator.tableWidgets.isEmpty)
    }

    /// Leaving the last row of a table at the end of the document adds a line
    /// to move to.
    func testDownFromTheLastRowAddsALine() throws {
      let (tv, coordinator) = makeStack("| a |\n| - |\n| 1 |")
      let widget = try XCTUnwrap(coordinator.tableWidgets.first)
      coordinator.tableWidget(widget, navigate: .down, from: TableCellPosition(row: 1, column: 0))
      XCTAssertEqual(tv.string, "| a |\n| - |\n| 1 |\n")
      XCTAssertEqual(tv.selectedRange(), NSRange(location: tv.string.utf16.count, length: 0))
    }

    /// A cell edit is undone by the editor undo manager.
    func testCellEditUndoes() throws {
      let original = "| a |\n| - |\n| 1 |"
      let (tv, coordinator) = makeStack(original)
      // A text view gets its undo manager from its window.
      let window = NSWindow(
        contentRect: tv.frame, styleMask: [.titled], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      window.contentView?.addSubview(tv)
      let undo = try XCTUnwrap(tv.undoManager)
      undo.groupsByEvent = false
      let widget = try XCTUnwrap(coordinator.tableWidgets.first)
      undo.beginUndoGrouping()
      coordinator.tableWidget(
        widget, didEditCellAt: TableCellPosition(row: 1, column: 0), text: "12")
      undo.endUndoGrouping()
      XCTAssertEqual(tv.string, "| a |\n| - |\n| 12 |")
      undo.undo()
      XCTAssertEqual(tv.string, original)
      coordinator.syncTables()
      XCTAssertEqual(widget.model.text(row: 1, column: 0), "1")
    }

    /// Renders the editor offscreen and writes a PNG, so the table can be
    /// looked at. Skipped unless `CRUMPET_SNAPSHOT` names a file to write.
    func testRenderSnapshot() throws {
      guard let path = ProcessInfo.processInfo.environment["CRUMPET_SNAPSHOT"] else { return }
      let (tv, _) = makeStack(
        """
        # Tables

        | hello | world |
        | --- | --- |
        | this is rich **text** | i can edit in the table directly, and long text wraps inside its cell |
        | ⌘I | *italic* |

        Text after the table.
        """)
      tv.setEditorBackground(.editorBackground)
      guard let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds) else { return }
      tv.cacheDisplay(in: tv.bounds, to: rep)
      let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: path))
    }
  }
#endif
