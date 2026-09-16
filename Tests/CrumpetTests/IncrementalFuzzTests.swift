import XCTest

@testable import Crumpet

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Property test: after any random sequence of edits, the incrementally-parsed
/// styling must equal a fresh one-shot parse of the same text. A divergence
/// means the incremental tree (the "as we type" path) is wrong.
@MainActor
final class IncrementalFuzzTests: XCTestCase {

  private func signature(_ storage: NSTextStorage, at location: Int) -> String {
    let f =
      storage.attribute(.font, at: location, effectiveRange: nil) as? PlatformFont
      ?? TextStyle.body.font
    let mono = f.fontDescriptor.symbolicTraits.contains(.monoSpace)
    return "\(Int(f.pointSize))/\(mono ? "m" : "-")/\(f.traits.contains(.boldTrait) ? "b" : "-")"
  }

  private func map(_ storage: NSTextStorage) -> [String] {
    let n = (storage.string as NSString).length
    return (0..<n).map { signature(storage, at: $0) }
  }

  func testRandomEditsMatchFullParse() {
    // Markdown-flavored alphabet so edits frequently create/destroy spans.
    let alphabet = Array("ab1 #`*~_->\n")
    var rng = SystemRandomNumberGenerator()

    for trial in 0..<400 {
      let storage = NSTextStorage(string: "")
      let highlighter = MarkdownHighlighter()
      storage.delegate = highlighter
      var log: [String] = []

      let steps = Int.random(in: 1...18, using: &rng)
      for _ in 0..<steps {
        let len = (storage.string as NSString).length
        // Bias toward insertion so documents grow.
        let insert = len == 0 || Bool.random(using: &rng)
        if insert {
          let at = Int.random(in: 0...len, using: &rng)
          let count = Int.random(in: 1...3, using: &rng)
          let str = String((0..<count).map { _ in alphabet.randomElement(using: &rng)! })
          storage.replaceCharacters(in: NSRange(location: at, length: 0), with: str)
          log.append("insert \(str.debugDescription) @\(at)")
        } else {
          let at = Int.random(in: 0..<len, using: &rng)
          let count = Int.random(in: 1...min(3, len - at), using: &rng)
          storage.replaceCharacters(in: NSRange(location: at, length: count), with: "")
          log.append("delete \(count) @\(at)")
        }
      }

      // The per-keystroke path styles only the edited paragraph; the
      // whole-document reparse is debounced. Settle it before comparing.
      highlighter.flushPendingParse(storage)
      let incremental = map(storage)
      let full = map(styledFresh(storage.string))
      if incremental != full {
        XCTFail(
          """
          trial \(trial): incremental styling diverged from full parse
          text: \(storage.string.debugDescription)
          edits: \(log)
          incremental: \(incremental)
          full:        \(full)
          """)
        return
      }
    }
  }

  private func styledFresh(_ string: String) -> NSTextStorage {
    let s = NSTextStorage(string: string)
    MarkdownHighlighter().highlight(s)
    return s
  }
}
