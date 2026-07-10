import XCTest

#if canImport(AppKit)
  import AppKit
#endif

@testable import CharmingEditor

/// Drives a *real* NSTextView the way a person types: each keystroke goes
/// through `insertText` (which uses `typingAttributes`) and then the highlighter,
/// exactly like the editor's `textDidChange`. Catches anything the storage-only
/// tests miss about the live text view.
@MainActor
final class TypingDiagnosticsTests: XCTestCase {
  #if canImport(AppKit)
    private func type(_ markdown: String) -> (tv: NSTextView, storage: NSTextStorage) {
      let tv = NSTextView(frame: .zero)
      tv.typingAttributes = TextStyle.body.attributes
      let highlighter = MarkdownHighlighter()
      let storage = tv.textStorage!
      storage.delegate = highlighter
      for ch in markdown {
        tv.insertText(String(ch), replacementRange: tv.selectedRange())
      }
      // Settle the debounced reparse so a fenced block spanning lines is styled.
      highlighter.flushPendingParse(storage)
      return (tv, storage)
    }

    private func isMono(_ storage: NSTextStorage, at loc: Int) -> Bool {
      let f = storage.attribute(.font, at: loc, effectiveRange: nil) as? PlatformFont
      return f?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false
    }

    func testInlineCodeViaTextView() {
      let md = "a `code` b"
      let (_, storage) = type(md)
      let code = (md as NSString).range(of: "code").location
      let plain = (md as NSString).range(of: "b").location
      XCTAssertTrue(isMono(storage, at: code), "code span should be monospaced")
      XCTAssertFalse(isMono(storage, at: plain), "trailing text should not be monospaced")
    }

    func testFencedCodeViaTextView() {
      let md = "```\nhi\n```\nplain"
      let (_, storage) = type(md)
      XCTAssertTrue(isMono(storage, at: (md as NSString).range(of: "hi").location))
      XCTAssertFalse(isMono(storage, at: (md as NSString).range(of: "plain").location))
    }

    /// After highlighting restyles the storage, the text view's
    /// `typingAttributes` are left untouched, so the *next* character types
    /// with the previous run's style for one keystroke before the highlighter
    /// corrects it. Documents the only "as we type" artifact reproduced here.
    func testTypingAttributesNotSyncedToCaretStyle() {
      let (tv, storage) = type("# Title")
      let titleSize =
        (storage.attribute(.font, at: 2, effectiveRange: nil) as? PlatformFont)?.pointSize ?? 0
      let typingSize = (tv.typingAttributes[.font] as? PlatformFont)?.pointSize ?? 0
      XCTAssertEqual(titleSize, 28, "the heading text is styled correctly in storage")
      XCTAssertEqual(
        typingSize, 17,
        "typingAttributes stay at body size, so the next keystroke is briefly mis-styled")
    }
  #endif
}
