import XCTest

@testable import Crumpet

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Isolates the per-keystroke costs on a large (~1.1M character, "Moby
/// Dick"-sized) document to see where the latency actually is:
///   - `testIncrementalEditLatency` times one character edit going through the
///     storage delegate: now just the local paragraph parse, since the
///     whole-document reparse is debounced off the keystroke path.
///   - `testDeferredFullParseLatency` times that debounced whole-document
///     reparse, the length-proportional work that now runs only once per pause.
///   - `testBindingSyncLatency` times what the coordinator now pushes through the
///     binding once typing settles: the Markdown source, no attribute conversion.
///   - `testUpdatePassLatency` times the no-diff check every SwiftUI update pass
///     runs against the binding, which is the one that used to rebuild the whole
///     document as an `NSAttributedString` only to throw it away.
@MainActor
final class PerformanceTests: XCTestCase {

  /// ~1.1M characters of realistic hard-wrapped prose: ~6 wrapped lines per
  /// paragraph, blank line between paragraphs (as Project Gutenberg text is), so
  /// tree-sitter sees many bounded paragraphs rather than one giant block.
  private func bigDocument() -> String {
    let line = "The quick brown fox **jumps** over the lazy dog. `code` here.\n"
    let paragraph = String(repeating: line, count: 6) + "\n"
    return String(repeating: paragraph, count: 3_000)
  }

  func testIncrementalEditLatency() {
    let storage = NSTextStorage(string: bigDocument())
    let highlighter = MarkdownHighlighter()
    storage.delegate = highlighter
    highlighter.highlight(storage)  // initial full parse

    // Edit near the end: the worst case for any length-proportional work. The
    // whole-document reparse is debounced, so this measures only the immediate
    // per-keystroke work (the local paragraph parse), which is what gates typing.
    let at = (storage.string as NSString).length - 5
    measure {
      storage.replaceCharacters(in: NSRange(location: at, length: 0), with: "x")
    }
  }

  /// The cost of the debounced whole-document reparse that runs once typing
  /// pauses. This is length-proportional (it's the work we moved *off* the
  /// keystroke path); it should fire at most once per typing burst, not per key.
  func testDeferredFullParseLatency() {
    let storage = NSTextStorage(string: bigDocument())
    let highlighter = MarkdownHighlighter()
    storage.delegate = highlighter
    highlighter.highlight(storage)

    let at = (storage.string as NSString).length - 5
    measure {
      storage.replaceCharacters(in: NSRange(location: at, length: 0), with: "x")
      highlighter.flushPendingParse(storage)
    }
  }

  /// Worst case for paragraph-granularity restyling: one enormous markdown
  /// paragraph (no blank lines), edited in the middle. Each keystroke re-parses
  /// and re-styles the whole containing paragraph's inline content, so if this is
  /// far slower than `testIncrementalEditLatency` the paragraph size is the cost.
  func testIncrementalEditInLargeParagraph() {
    // ~120k characters, all one paragraph (single space-joined run, no newlines).
    let paragraph = String(repeating: "word **bold** and `code` here ", count: 4_000)
    let storage = NSTextStorage(string: paragraph)
    let highlighter = MarkdownHighlighter()
    storage.delegate = highlighter
    highlighter.highlight(storage)

    let at = (storage.string as NSString).length / 2
    measure {
      storage.replaceCharacters(in: NSRange(location: at, length: 0), with: "x")
    }
  }

  /// Prints a per-phase breakdown of one keystroke on the large line-wrapped
  /// document, so we can see which phase (line index, parse, changed ranges,
  /// restyle) carries the cost. Not a `measure` test: runs the edit once.
  func testEditPhaseBreakdown() {
    let storage = NSTextStorage(string: bigDocument())
    let highlighter = MarkdownHighlighter()
    storage.delegate = highlighter
    highlighter.highlight(storage)

    highlighter.debugTiming = true
    let at = (storage.string as NSString).length - 5
    storage.replaceCharacters(in: NSRange(location: at, length: 0), with: "x")
    // Force the debounced reparse so its phase breakdown prints too.
    highlighter.flushPendingParse(storage)
    highlighter.debugTiming = false
  }

  func testBindingSyncLatency() {
    let storage = NSTextStorage(string: bigDocument())
    let highlighter = MarkdownHighlighter()
    storage.delegate = highlighter
    highlighter.highlight(storage)

    measure {
      _ = storage.string
    }
  }

  func testUpdatePassLatency() {
    let storage = NSTextStorage(string: bigDocument())
    let highlighter = MarkdownHighlighter()
    storage.delegate = highlighter
    highlighter.highlight(storage)
    let published = storage.string as NSString

    // Every SwiftUI update pass re-delivers the text the editor itself published,
    // so this equal-and-bail path is the one that has to be cheap.
    measure {
      _ = TextDiff.between(storage.mutableString, and: published)
    }
  }
}
