#if canImport(AppKit)
  import AppKit
  import SwiftUI
  import XCTest

  @testable import Crumpet

  /// Checks `.span` reveal through the real TextKit 1 stack after edits that
  /// shift a marker without restyling its paragraph.
  @MainActor
  final class HeadingConcealmentTests: XCTestCase {
    private nonisolated(unsafe) static var coordinatorKey = 0
    private nonisolated(unsafe) static var storageKey = 0

    override func setUp() {
      super.setUp()
      Typography.revealMode = .span
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
      tv.delegate = coordinator
      coordinator.textView = tv
      coordinator.highlighter.highlight(storage)
      layoutManager.ensureLayout(for: container)
      // The coordinator and the storage hold each other's only strong refs here.
      objc_setAssociatedObject(tv, &Self.coordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN)
      objc_setAssociatedObject(tv, &Self.storageKey, storage, .OBJC_ASSOCIATION_RETAIN)
      return tv
    }

    private func isConcealed(_ tv: NSTextView, at charIndex: Int) -> Bool {
      let manager = tv.layoutManager!
      manager.ensureLayout(for: tv.textContainer!)
      return manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: charIndex)) == .null
    }

    /// Moving the caret down off a heading conceals its `#` prefix again.
    func testMovingDownOffHeadingConcealsPrefix() {
      let markdown = "# Welcome\n\nSome text.\n\n## Try it\n\n- item one"
      let tv = makeStack(markdown)
      let headingStart = (markdown as NSString).range(of: "## Try it").location
      for column in [0, 3, 9] {
        tv.setSelectedRange(NSRange(location: headingStart + column, length: 0))
        XCTAssertFalse(isConcealed(tv, at: headingStart), "revealed on the heading")
        tv.moveDown(nil)
        XCTAssertTrue(
          isConcealed(tv, at: headingStart),
          "caret at \(tv.selectedRange()) after Down from column \(column)")
      }
    }

    /// Deleting text above a heading shifts it without restyling it. The reveal
    /// span has to shift with it, or it ends up covering the next line.
    func testEditAboveHeadingKeepsSpanInPlace() {
      let markdown = "# Welcome\n\nSome text here.\n\n## Try it\n\n- item one"
      let tv = makeStack(markdown)
      tv.textStorage!.replaceCharacters(in: (markdown as NSString).range(of: "here"), with: "")
      let headingStart = (tv.string as NSString).range(of: "## Try it").location
      tv.setSelectedRange(NSRange(location: headingStart + 4, length: 0))
      XCTAssertFalse(isConcealed(tv, at: headingStart), "revealed on the heading")
      tv.moveDown(nil)
      XCTAssertTrue(isConcealed(tv, at: headingStart), "caret at \(tv.selectedRange())")
    }

    /// The same for an emphasis span in a paragraph below the edit.
    func testEditAboveEmphasisKeepsSpanInPlace() {
      let markdown = "Some text here.\n\nA **bold** word\nnext line"
      let tv = makeStack(markdown)
      tv.textStorage!.replaceCharacters(in: (markdown as NSString).range(of: "here"), with: "")
      let source = tv.string as NSString
      let open = source.range(of: "**").location
      tv.setSelectedRange(NSRange(location: open + 3, length: 0))
      XCTAssertFalse(isConcealed(tv, at: open), "revealed inside the span")
      tv.setSelectedRange(NSRange(location: source.range(of: "word").location + 2, length: 0))
      XCTAssertTrue(isConcealed(tv, at: open), "caret at \(tv.selectedRange())")
    }
  }
#endif
