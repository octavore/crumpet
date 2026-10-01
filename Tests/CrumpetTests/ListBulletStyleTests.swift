#if canImport(AppKit)
  import AppKit
  import SwiftUI
  import XCTest

  @testable import Crumpet

  /// Switching `ListBulletStyle` at runtime has to take effect on the live
  /// document without an edit. The glyph swap is a glyph-generation decision,
  /// but a scaled style also stamps real font, kern, and baseline attributes on
  /// the marker character, so `applyListBulletStyle` must restyle, not just
  /// invalidate glyphs.
  @MainActor
  final class ListBulletStyleTests: XCTestCase {
    private nonisolated(unsafe) static var coordinatorKey = 0
    private nonisolated(unsafe) static var storageKey = 0

    override func tearDown() {
      Typography.listBulletStyle = Typography.defaultListBulletStyle
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
      objc_setAssociatedObject(tv, &Self.coordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN)
      objc_setAssociatedObject(tv, &Self.storageKey, storage, .OBJC_ASSOCIATION_RETAIN)
      return tv
    }

    private func coordinator(_ tv: NSTextView) -> TextViewEditor.Coordinator {
      objc_getAssociatedObject(tv, &Self.coordinatorKey) as! TextViewEditor.Coordinator
    }

    /// A scaled style enlarges the marker font the moment it is applied, with no
    /// edit to the document. Before the restyle was added this only took effect
    /// on the next keystroke that re-styled the item's paragraph.
    func testScaledStyleEnlargesTheMarkerImmediately() {
      let tv = makeStack("- item")
      let storage = tv.textStorage!
      let markerFont = storage.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
      XCTAssertEqual(markerFont.pointSize, TextStyle.body.font.pointSize)

      coordinator(tv).applyListBulletStyle(.disc)

      let enlarged = storage.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
      XCTAssertGreaterThan(
        enlarged.pointSize, TextStyle.body.font.pointSize,
        "the marker font should scale up as soon as the style changes")
      XCTAssertNotNil(
        storage.attribute(.listBulletMarker, at: 0, effectiveRange: nil),
        "the marker tag should still be in place")
    }

    /// Tab on a bullet, including an empty one (the grammar reports that as an
    /// error node), leaves it drawn as the disc.
    func testIndentedBulletKeepsItsGlyph() {
      let cases = [
        ("- item", 0), ("- a\n- b", 4), ("- a\n  - b\n- c", 4), ("- a\n- ", 4), ("- ", 0),
      ]
      for (text, line) in cases {
        let tv = makeStack(text)
        let coord = coordinator(tv)
        coord.applyListBulletStyle(.disc)
        let lm = tv.layoutManager!
        lm.ensureLayout(for: tv.textContainer!)
        let before = lm.cgGlyph(at: lm.glyphIndexForCharacter(at: 0))
        tv.setSelectedRange(NSRange(location: tv.string.count, length: 0))
        XCTAssertTrue(coord.shiftListIndent(outdent: false))
        lm.ensureLayout(for: tv.textContainer!)
        let string = tv.string as NSString
        let dashIndex = string.range(
          of: "-", range: NSRange(location: line, length: string.length - line)
        ).location
        let after = lm.cgGlyph(at: lm.glyphIndexForCharacter(at: dashIndex))
        XCTAssertEqual(after, before, text)
        XCTAssertNotNil(
          tv.textStorage!.attribute(.listBulletMarker, at: dashIndex, effectiveRange: nil), text)
      }
    }

    /// A bullet character with no space after it is not drawn as a bullet.
    func testDashWithoutSpaceIsNotTagged() {
      for (text, dash) in [("-", 0), ("a\n\n-", 3), ("- a\n  -", 6)] {
        let tv = makeStack(text)
        XCTAssertNil(
          tv.textStorage!.attribute(.listBulletMarker, at: dash, effectiveRange: nil),
          text.debugDescription)
      }
    }

    /// An empty nested item under an item's text parses as a continuation of
    /// that text, and still gets the bullet tag. A `- ` in a code block does not.
    func testEmptyNestedItemIsTagged() {
      for (text, dash) in [("- a\n    - ", 8), ("- a\n  - ", 6), ("- a\n  -  \n", 6)] {
        let tv = makeStack(text)
        XCTAssertNotNil(
          tv.textStorage!.attribute(.listBulletMarker, at: dash, effectiveRange: nil),
          text.debugDescription)
      }
      let code = makeStack("```\n- \n```")
      XCTAssertNil(code.textStorage!.attribute(.listBulletMarker, at: 4, effectiveRange: nil))
    }

    /// Return at the end of a nested item tags the new item's bullet at once,
    /// without waiting for the deferred full parse.
    func testReturnOnNestedItemTagsNewBulletImmediately() {
      for text in ["- a\n  - b", "- a\n    - b"] {
        let tv = makeStack(text)
        let coord = coordinator(tv)
        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        XCTAssertTrue(coord.handleListNewline())
        let string = tv.string as NSString
        let dash = string.range(of: "-", options: .backwards).location
        XCTAssertNotNil(
          tv.textStorage!.attribute(.listBulletMarker, at: dash, effectiveRange: nil),
          text.debugDescription)
      }
    }

    /// Typing into an item indented four or more spaces keeps its bullet tag.
    /// The keystroke path parses the edited line alone, where that much
    /// indentation would otherwise read as an indented code block.
    func testTypingIntoDeeplyIndentedItemKeepsTag() {
      for text in ["- a\n- b", "- a\n- "] {
        let tv = makeStack(text)
        let coord = coordinator(tv)
        coord.listIndent = 4
        coord.applyListBulletStyle(.disc)
        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        XCTAssertTrue(coord.shiftListIndent(outdent: false))
        for character in ["x", "y", "z"] {
          tv.insertText(character, replacementRange: tv.selectedRange())
          XCTAssertNotNil(
            tv.textStorage!.attribute(.listBulletMarker, at: 8, effectiveRange: nil),
            "\(text.debugDescription) after typing \(character)")
        }
      }
    }

    /// Going back to `.asTyped` strips the scaled font again, also without an
    /// edit.
    func testReturningToAsTypedRestoresTheMarkerFont() {
      let tv = makeStack("- item")
      let storage = tv.textStorage!
      coordinator(tv).applyListBulletStyle(.disc)
      coordinator(tv).applyListBulletStyle(.asTyped)

      let restored = storage.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
      XCTAssertEqual(
        restored.pointSize, TextStyle.body.font.pointSize,
        "the marker font should return to body size")
      XCTAssertNil(storage.attribute(.baselineOffset, at: 0, effectiveRange: nil))
    }
  }
#endif
