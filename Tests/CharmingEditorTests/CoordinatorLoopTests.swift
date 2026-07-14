import SwiftUI
import XCTest

#if canImport(AppKit)
  import AppKit
#endif

@testable import CharmingEditor

/// Reproduces the *entire* macOS editing loop: a real NSTextView wired to the
/// real `Coordinator` as its delegate, typing through `insertText` (which fires
/// `textDidChange`), then running what `updateNSView` does when SwiftUI reacts
/// to the binding the coordinator just wrote. This is the one path the
/// storage-only and highlighter-only tests don't cover.
@MainActor
final class CoordinatorLoopTests: XCTestCase {
  #if canImport(AppKit)
    /// Mirrors the body of `TextViewEditor.updateNSView` for a given coordinator
    /// + text view, so we can run the SwiftUI side of the loop in a test.
    private func runUpdate(_ coordinator: TextViewEditor.Coordinator, _ tv: NSTextView) {
      // While the text view's binding sync is pending, updateNSView is a no-op.
      if coordinator.isSyncingFromTextView { return }
      guard let storage = tv.textStorage else { return }
      coordinator.applyExternalText(coordinator.text, to: storage, in: tv)
    }

    private func isMono(_ storage: NSTextStorage, at loc: Int) -> Bool {
      let f = storage.attribute(.font, at: loc, effectiveRange: nil) as? PlatformFont
      return f?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false
    }

    func testTypingThroughCoordinatorLoopStylesCode() {
      var backing = ""
      let binding = Binding(get: { backing }, set: { backing = $0 })
      let coordinator = TextViewEditor.Coordinator(text: binding, commands: EditorCommands())

      let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
      tv.isRichText = true
      tv.typingAttributes = TextStyle.body.attributes
      tv.delegate = coordinator
      tv.textStorage?.delegate = coordinator.highlighter
      coordinator.textView = tv

      let storage = tv.textStorage!
      let md = "a `code` b"
      for ch in md {
        // Each keystroke restyles `storage` synchronously via the storage
        // delegate; the binding write is coalesced and stays pending.
        tv.insertText(String(ch), replacementRange: tv.selectedRange())
      }
      // Close the edit cycle as the app does when typing settles: flush the
      // coalesced binding write, then let SwiftUI react to it.
      coordinator.flushBindingSync()
      runUpdate(coordinator, tv)

      let code = (storage.string as NSString).range(of: "code").location
      XCTAssertTrue(
        code != NSNotFound && isMono(storage, at: code),
        "after the full coordinator loop, code span should be monospaced; "
          + "storage=\(storage.string.debugDescription)")
    }
  #endif
}
