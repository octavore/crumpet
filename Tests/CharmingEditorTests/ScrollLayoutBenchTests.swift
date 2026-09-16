#if canImport(AppKit)
  import AppKit
  import SwiftUI
  import XCTest

  @testable import CharmingEditor

  /// Times the work a scroll frame actually pays for. With non-contiguous
  /// layout, scrolling into text that hasn't been laid out yet generates its
  /// glyphs on that frame, which runs the coordinator's `shouldGenerateGlyphs`
  /// concealment pass. That pass must cost what the newly exposed range is
  /// worth, not what the document is worth, or scrolling a long file stutters.
  @MainActor
  final class ScrollLayoutBenchTests: XCTestCase {

    /// Prose the way a real doc reads: mostly unmarked, with the occasional
    /// bold or code span. The unmarked stretches are the case that matters —
    /// a lookup that extends the *longest* run of "no marker here" walks the
    /// rest of the file, and the longer those stretches are, the further it
    /// walks.
    private func document(paragraphs: Int) -> String {
      let plain = "The quick brown fox jumps over the lazy dog and keeps on going.\n"
      let marked = "Some **bold** text and `code` here.\n"
      return String(
        repeating: String(repeating: plain, count: 6) + marked + "\n", count: paragraphs)
    }

    /// A text view wired the way `makeNSView` wires one: the highlighter as
    /// storage delegate, and (unless `conceal` is false, for an A/B against the
    /// bare AppKit cost) the coordinator as layout-manager delegate.
    private func makeStack(text: String, conceal: Bool) -> NSTextView {
      var backing = text
      let binding = Binding(get: { backing }, set: { backing = $0 })
      let coordinator = TextViewEditor.Coordinator(text: binding, commands: EditorCommands())
      let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
      tv.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
      tv.textContainer?.widthTracksTextView = true
      tv.textStorage?.setAttributedString(NSAttributedString(string: text))
      tv.textStorage?.delegate = coordinator.highlighter
      if conceal { tv.layoutManager?.delegate = coordinator }
      // Match a scroll view's lazy layout, so laying out a window in the middle
      // of the document doesn't drag every preceding character in with it.
      tv.layoutManager?.allowsNonContiguousLayout = true
      coordinator.textView = tv
      coordinator.highlighter.highlight(tv.textStorage!)
      // The coordinator holds the only strong reference the delegates need.
      objc_setAssociatedObject(tv, &Self.coordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN)
      return tv
    }

    private nonisolated(unsafe) static var coordinatorKey = 0

    /// Lays out a fixed window mid-document across a 16x range of document
    /// sizes, with and without concealment. Concealment's share must stay
    /// roughly flat; when it tracks the document length instead, the
    /// `shouldGenerateGlyphs` attribute lookup has gone back to scanning the
    /// whole file per character.
    func testConcealmentCostIsIndependentOfDocumentLength() {
      // A fresh stack per trial (layout is cached, so a range can only be laid
      // out once) and the best of several, since a single trial on a warming
      // process swings wider than the effect being measured.
      func best(paragraphs: Int, conceal: Bool) -> Duration {
        (0..<5).map { _ in
          let tv = makeStack(text: document(paragraphs: paragraphs), conceal: conceal)
          let range = NSRange(location: (tv.string as NSString).length / 2, length: 3_000)
          return ContinuousClock().measure {
            tv.layoutManager!.ensureLayout(forCharacterRange: range)
          }
        }.min()!
      }

      for paragraphs in [200, 800, 3_200] {
        let timings = [
          false: best(paragraphs: paragraphs, conceal: false),
          true: best(paragraphs: paragraphs, conceal: true),
        ]
        let overhead = timings[true]! - timings[false]!
        print(
          "doc \(paragraphs * 7) lines: layout \(timings[false]!.ms), "
            + "with concealment \(timings[true]!.ms) (+\(overhead.ms))")
      }
    }
  }

  extension Duration {
    fileprivate var ms: String {
      String(
        format: "%.2f ms",
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
    }
  }
#endif
