#if canImport(AppKit)
  import AppKit
  import SwiftUI
  import XCTest

  @testable import CharmingEditor

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
