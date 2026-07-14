import XCTest

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@testable import CharmingEditor

/// Replays the *exact* keystroke sequence from the live-app repro: an empty
/// initial highlight (the load path), then "# hello\n" followed by "a `code` b"
/// typed one character at a time through a single incremental highlighter.
///
/// The two constructs settle at different moments, by design. A code span is
/// decidable from the paragraph the cursor is in, so it styles on the keystroke.
/// A heading is not — the same `# hello` line is verbatim text inside a fence —
/// so the block style waits for the deferred whole-document parse rather than
/// being guessed at and flashed into place.
@MainActor
final class AppSequenceTests: XCTestCase {
  func testAppRepro() {
    let storage = NSTextStorage(string: "")
    let highlighter = MarkdownHighlighter()
    storage.delegate = highlighter  // restyle on every character edit, as the app does

    let md = "# hello\na `code` b"
    for ch in md {
      storage.replaceCharacters(
        in: NSRange(location: storage.length, length: 0), with: String(ch))
    }

    let heading = (md as NSString).range(of: "hello").location
    let code = (md as NSString).range(of: "code").location

    let cFont = storage.attribute(.font, at: code, effectiveRange: nil) as? PlatformFont
    XCTAssertTrue(
      cFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false,
      "code span should be styled on the keystroke, with no deferred parse")

    highlighter.flushPendingParse(storage)
    let hFont = storage.attribute(.font, at: heading, effectiveRange: nil) as? PlatformFont
    XCTAssertEqual(hFont?.pointSize, 28, "heading should be styled once the deferred parse runs")
  }
}
