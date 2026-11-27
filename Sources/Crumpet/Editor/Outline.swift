import Foundation
import SwiftTreeSitter
import TreeSitterMarkdown

/// One ATX heading in a document, as returned by ``MarkdownOutline/items(in:)``.
public struct OutlineItem: Identifiable, Hashable, Sendable {
  /// Position among the document's headings, in document order.
  public let id: Int
  /// Heading level, from 1 for `#` to 6 for `######`.
  public let level: Int
  /// Heading text without the `#` prefix or closing `#` characters.
  public let title: String
  /// Heading from its `#` prefix to the end of the line in UTF-16 units,
  /// excluding the line break.
  public let range: NSRange

  public init(id: Int, level: Int, title: String, range: NSRange) {
    self.id = id
    self.level = level
    self.title = title
    self.range = range
  }
}

/// Heading outline of a Markdown document.
public enum MarkdownOutline {
  /// ATX headings in `text`, in document order. Lines that start with `#`
  /// inside code blocks are not headings. Setext headings are not included,
  /// since the editor does not style them.
  public static func items(in text: String) -> [OutlineItem] {
    let parser = Parser()
    do {
      try parser.setLanguage(Language(tree_sitter_markdown()))
    } catch {
      return []
    }
    guard let root = parser.parse(text)?.rootNode else { return [] }

    let source = text as NSString
    var items: [OutlineItem] = []
    var stack = [root]
    // Depth-first in document order. Children are pushed in reverse.
    while let node = stack.popLast() {
      if node.nodeType == "atx_heading" {
        if let item = makeItem(from: node, id: items.count, in: source) {
          items.append(item)
        }
        continue
      }
      for index in stride(from: node.childCount - 1, through: 0, by: -1) {
        if let child = node.child(at: index) { stack.append(child) }
      }
    }
    return items
  }

  private static func makeItem(from node: Node, id: Int, in source: NSString) -> OutlineItem? {
    var level: Int?
    for index in 0..<node.childCount {
      guard let type = node.child(at: index)?.nodeType,
        type.hasPrefix("atx_h"), type.hasSuffix("_marker")
      else { continue }
      level = Int(type.dropFirst("atx_h".count).prefix(1))
      break
    }
    guard let level else { return nil }

    // Tree-sitter byte offsets are two per UTF-16 unit.
    let start = min(Int(node.byteRange.lowerBound) / 2, source.length)
    var contentsEnd = 0
    source.getLineStart(
      nil, end: nil, contentsEnd: &contentsEnd,
      for: NSRange(location: start, length: 0))
    // Starts at the node, so a container prefix such as `> ` is excluded.
    let range = NSRange(location: start, length: max(0, contentsEnd - start))
    return OutlineItem(
      id: id, level: level, title: title(of: source.substring(with: range)), range: range)
  }

  /// Text of an ATX heading line without its opening and closing `#` runs.
  private static func title(of line: String) -> String {
    var text = Substring(line.trimmingCharacters(in: .whitespaces))
    text = text.drop { $0 == "#" }
    var content = text.trimmingCharacters(in: .whitespaces)
    // A closing `#` run counts only if a space separates it from the text.
    if let hashes = content.lastIndex(where: { $0 != "#" }) {
      let tail = content[content.index(after: hashes)...]
      if !tail.isEmpty, content[hashes] == " " || content[hashes] == "\t" {
        content = content[...hashes].trimmingCharacters(in: .whitespaces)
      }
    } else {
      content = ""
    }
    return content
  }
}
