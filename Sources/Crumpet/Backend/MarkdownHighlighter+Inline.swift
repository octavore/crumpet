import Foundation
import SwiftTreeSitter

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Inline styling: emphasis, code spans, links, and images, found by
/// re-parsing each `inline` node with the inline grammar.
extension MarkdownHighlighter {
  func styleInline(
    _ inlineNode: Node, range: NSRange, in storage: NSTextStorage, source: NSString, base: Int
  ) {
    let substring = source.substring(with: range)
    guard !substring.isEmpty else { return }
    guard let tree = inline.parse(substring), let root = tree.rootNode
    else { return }
    walkInline(root, inlineByteBase: inlineNode.byteRange.lowerBound, docBase: base, in: storage)
  }

  private func walkInline(
    _ node: Node, inlineByteBase: UInt32, docBase: Int, in storage: NSTextStorage
  ) {
    let range = docRange(node, inlineByteBase: inlineByteBase, docBase: docBase)
    switch node.nodeType ?? "" {
    case "strong_emphasis":
      addTrait(.boldTrait, to: range, in: storage)
      addColor(Typography.colorScheme.bold, to: range, in: storage)
    case "emphasis":
      addTrait(.italicTrait, to: range, in: storage)
      addColor(Typography.colorScheme.italic, to: range, in: storage)
    case "code_span":
      applyCode(to: range, in: storage, inline: true)
    case "strikethrough":
      storage.addAttribute(
        .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
    case "inline_link", "shortcut_link", "full_reference_link", "collapsed_reference_link",
      "image", "uri_autolink", "email_autolink":
      addColor(Typography.colorScheme.link, to: range, in: storage)
      if node.nodeType == "image" {
        // A fresh token per image keeps back to back images in separate runs.
        storage.addAttribute(.imageChip, value: NSObject(), range: range)
        markBlockImage(
          node, range: range, inlineByteBase: inlineByteBase, docBase: docBase, in: storage)
      }
    case "emphasis_delimiter", "code_span_delimiter":
      // The `**`/`*`/`` ` `` characters themselves, concealed until the caret
      // touches the emphasis or code span they delimit.
      concealMarker(node, inlineByteBase: inlineByteBase, docBase: docBase, in: storage)
    case "link_destination", "link_title", "link_label":
      // A link's `(url "title")` or `[label]` part. Concealed until the caret
      // enters the enclosing link.
      concealMarker(node, inlineByteBase: inlineByteBase, docBase: docBase, in: storage)
    case "[", "]", "(", ")", "!":
      if let parent = node.parent, Self.linkContainerTypes.contains(parent.nodeType ?? "") {
        concealMarker(node, inlineByteBase: inlineByteBase, docBase: docBase, in: storage)
        if node.nodeType == "!", parent.nodeType == "image" {
          storage.addAttribute(.imageChipIcon, value: true, range: range)
        }
        if node.nodeType == "]", parent.nodeType != "image", Self.isFirstClosingBracket(node) {
          storage.addAttribute(.linkChipIcon, value: true, range: range)
        }
      }
    default:
      break
    }
    for index in 0..<node.childCount {
      if let child = node.child(at: index) {
        walkInline(child, inlineByteBase: inlineByteBase, docBase: docBase, in: storage)
      }
    }
  }

  /// Inline node types for links and images.
  private static let linkContainerTypes: Set<String> = [
    "inline_link", "shortcut_link", "full_reference_link", "collapsed_reference_link", "image",
  ]

  /// Whether `node` is the first `]` child of its parent, the one that ends
  /// the link text. A reference link's `[label]` brackets come after it.
  private static func isFirstClosingBracket(_ node: Node) -> Bool {
    guard let parent = node.parent else { return false }
    for index in 0..<parent.childCount {
      if let child = parent.child(at: index), child.nodeType == "]" {
        return child.byteRange == node.byteRange
      }
    }
    return false
  }

  /// Marks the `!` of an image that is alone on its line with `.imageBlock`, so
  /// the concealed image displays its picture. An image mixed into other text
  /// keeps the chip. Only inline destinations (`![alt](url)`) are handled.
  private func markBlockImage(
    _ node: Node, range: NSRange, inlineByteBase: UInt32, docBase: Int, in storage: NSTextStorage
  ) {
    let source = storage.mutableString
    var start = 0
    var end = 0
    var contentsEnd = 0
    source.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: range)
    let line = source.substring(with: NSRange(location: start, length: contentsEnd - start))
    guard line.trimmingCharacters(in: .whitespaces) == source.substring(with: range) else { return }

    var destination: Node?
    var description: Node?
    for index in 0..<node.childCount {
      guard let child = node.child(at: index) else { continue }
      if child.nodeType == "link_destination" { destination = child }
      if child.nodeType == "image_description" { description = child }
    }
    guard let destination else { return }
    var url = source.substring(
      with: docRange(destination, inlineByteBase: inlineByteBase, docBase: docBase))
    if url.hasPrefix("<"), url.hasSuffix(">"), url.count >= 2 {
      url = String(url.dropFirst().dropLast())
    }
    guard !url.isEmpty else { return }
    storage.addAttribute(
      .imageBlock, value: url, range: NSRange(location: range.location, length: 1))

    // The alt text conceals with the rest of the syntax once the picture
    // displays. Until then it is the chip's label.
    if let description {
      concealMarker(description, inlineByteBase: inlineByteBase, docBase: docBase, in: storage)
      storage.addAttribute(
        .imageCaption, value: url,
        range: docRange(description, inlineByteBase: inlineByteBase, docBase: docBase))
    }
  }

  /// Marks a syntax node for concealment. It reveals when the caret touches
  /// the node's parent: the emphasis or code span a delimiter belongs to, or
  /// the link a link part belongs to. See ``MarkerConcealment``.
  private func concealMarker(
    _ node: Node, inlineByteBase: UInt32, docBase: Int, in storage: NSTextStorage
  ) {
    let marker = docRange(node, inlineByteBase: inlineByteBase, docBase: docBase)
    let span =
      node.parent.map { docRange($0, inlineByteBase: inlineByteBase, docBase: docBase) } ?? marker
    storage.addAttribute(
      .markdownMarker, value: MarkerSpan.value(span: span, marker: marker), range: marker)
  }

  /// The document range of a node from an inline parse. `inlineByteBase`
  /// places the node in the block tree's byte space, and `docBase` shifts that
  /// to document coordinates.
  private func docRange(_ node: Node, inlineByteBase: UInt32, docBase: Int) -> NSRange {
    let bytes = node.byteRange
    return nsRange(
      (bytes.lowerBound + inlineByteBase)..<(bytes.upperBound + inlineByteBase), base: docBase)
  }
}
