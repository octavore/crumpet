import XCTest

@testable import Crumpet

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
final class ReplayDebugTests: XCTestCase {
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

  private enum Edit {
    case insert(String, Int)
    case delete(Int, Int)
  }

  func testReplay() {
    let edits: [Edit] = [
      .insert("a>", 0), .delete(2, 0), .insert("\n-", 0), .insert("~", 1), .insert("\n#", 3),
      .insert("\n`~", 1), .insert(">", 4), .delete(2, 2), .delete(2, 4), .insert("~", 2),
      .insert("*1`", 0), .insert("-*", 3), .insert("1  ", 1), .delete(2, 10), .insert("*`\n", 0),
      .delete(1, 1),
    ]
    let storage = NSTextStorage(string: "")
    let highlighter = MarkdownHighlighter()
    storage.delegate = highlighter

    for edit in edits {
      switch edit {
      case .insert(let s, let at):
        storage.replaceCharacters(in: NSRange(location: at, length: 0), with: s)
      case .delete(let n, let at):
        storage.replaceCharacters(in: NSRange(location: at, length: n), with: "")
      }
    }

    highlighter.flushPendingParse(storage)
    let fresh = NSTextStorage(string: storage.string)
    MarkdownHighlighter().highlight(fresh)
    XCTAssertEqual(map(storage), map(fresh))
  }
}
