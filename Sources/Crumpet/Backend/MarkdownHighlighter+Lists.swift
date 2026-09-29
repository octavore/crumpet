import Foundation
import SwiftTreeSitter

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// List item styling: the hanging indent and the rendered bullet.
extension MarkdownHighlighter {
  /// Gives a list item a hanging indent so soft-wrapped lines and continuation
  /// text align under the item's content instead of under its marker, and so
  /// a nested list sits visually inside its parent. The indent is the
  /// rendered width of the item's prefix (the leading indentation, the
  /// ordered or unordered marker `1.`, `-`, `*`, `+`, and the space after it),
  /// measured in the body font. The prefix is real text that already
  /// positions the first line, so only continuation lines (`headIndent`)
  /// move; the first line stays.
  ///
  /// Applied to the whole item, including any nested list, before the walk
  /// descends: each nested item then overrides this with its own deeper indent.
  func applyListIndent(
    _ node: Node, range: NSRange, in storage: NSTextStorage, source: NSString, base: Int
  ) {
    guard range.length > 0 else { return }
    // The prefix runs to where the item's content begins: the first child
    // that isn't the marker (a task marker, paragraph, or the nested list
    // itself). It starts at the line's first character, not the item node's
    // start, so a nested item's leading indentation (which tree-sitter
    // attributes to the parent, not the item) is counted, letting nesting
    // deepen the indent.
    var contentStart = range.location
    for index in 0..<node.childCount {
      guard let child = node.child(at: index) else { continue }
      if (child.nodeType ?? "").hasPrefix("list_marker") { continue }
      contentStart = nsRange(child.byteRange, base: base).location
      break
    }
    let lineStart = source.lineRange(for: NSRange(location: range.location, length: 0)).location
    let prefixLength = max(0, contentStart - lineStart)
    guard prefixLength > 0 else { return }

    let prefix = source.substring(with: NSRange(location: lineStart, length: prefixLength))
    var indent = (prefix as NSString).size(withAttributes: [.font: TextStyle.body.font]).width

    // The prefix above measures every character, including the bullet, at
    // body size, but `tagUnorderedBullet` draws unordered bullets at their
    // own scale and trailing kern (see `ListBulletStyle`). Swap in that
    // glyph's actual width so wrapped and continuation lines still hang
    // under the item's text instead of under where a body-sized `-` would
    // have ended.
    if let bulletRange = unorderedBulletMarker(node, in: source, base: base) {
      let style = Typography.listBulletStyle
      if let scalar = style.markerScalar {
        let typed = source.substring(with: bulletRange) as NSString
        let typedWidth = typed.size(withAttributes: [.font: TextStyle.body.font]).width
        let markerFont = Typography.current.font(
          ofSize: Typography.baseSize * style.markerScale, weight: .regular)
        let glyphWidth = (String(scalar) as NSString)
          .size(withAttributes: [.font: markerFont]).width
        indent += glyphWidth - typedWidth + Typography.baseSize * style.markerTrailingKern
      }
    }

    let style = NSMutableParagraphStyle()
    style.setParagraphStyle(TextStyle.body.paragraphStyle)
    style.headIndent = indent
    // A paragraph style must span whole paragraphs: NSTextStorage's attribute
    // fixing collapses each paragraph to the style at its first character. A
    // nested item starts mid-line (after its parent's indentation), so apply
    // from the paragraph start, over that leading whitespace too, or the fix
    // would discard this indent in favor of the parent's.
    storage.addAttribute(.paragraphStyle, value: style, range: source.paragraphRange(for: range))
  }

  /// The single-character range of an unordered list item's bullet (`-`, `*`,
  /// `+`), or nil if `node` isn't an unordered item. The marker child is
  /// `- `, `* `, `+ ` (any leading indentation belongs to the parent), so the
  /// bullet is the first non-space character.
  private func unorderedBulletMarker(
    _ node: Node, in source: NSString, base: Int
  ) -> NSRange? {
    for index in 0..<node.childCount {
      guard let child = node.child(at: index) else { continue }
      guard (child.nodeType ?? "").hasPrefix("list_marker") else { continue }
      let markerRange = nsRange(child.byteRange, base: base)
      guard markerRange.length > 0,
        markerRange.location + markerRange.length <= source.length
      else { return nil }
      let text = source.substring(with: markerRange)
      let leading = text.prefix { $0 == " " || $0 == "\t" }.count
      guard let bullet = text.dropFirst(leading).first,
        bullet == "-" || bullet == "*" || bullet == "+"
      else { return nil }
      return NSRange(location: markerRange.location + leading, length: 1)
    }
    return nil
  }

  /// Marks the bullet character of an unordered list item (`-`, `*`, `+`) with
  /// ``NSAttributedString/Key/listBulletMarker`` so the layout manager can draw
  /// it as the glyph `Typography.listBulletStyle` selects. Ordered markers
  /// (`1.`, `2)`) are left alone. Purely a rendering hint: the character stays
  /// in the text, so the Markdown source is untouched. Which glyph it becomes
  /// is decided at glyph generation, not here, so the tag carries no value and
  /// changing the style needs no restyle.
  func tagUnorderedBullet(
    _ node: Node, in storage: NSTextStorage, source: NSString, base: Int
  ) {
    if let bulletRange = unorderedBulletMarker(node, in: source, base: base) {
      tagBullet(bulletRange, in: storage)
    }
  }

  /// Tags the bullet of every empty unordered item (`- ` with only whitespace
  /// after it) in `ranges` that the tree did not already. An empty item cannot
  /// interrupt a paragraph, so an empty nested item under an item's text parses
  /// as a continuation of that text rather than as a `list_item`. Lines inside
  /// a code block according to `root` are skipped. With no `root` every line is
  /// checked, for a caller that has already ruled out code.
  func tagEmptyBullets(
    in ranges: [NSRange], root: Node?, source: NSString, storage: NSTextStorage
  ) {
    forEachLine(covering: ranges, in: source) { line in
      if let bullet = emptyBullet(in: line, source: source),
        root.map({ !enclosedByCodeBlock($0, at: bullet) }) ?? true
      {
        tagBullet(NSRange(location: bullet, length: 1), in: storage)
      }
    }
  }

  /// The offset of the bullet if `line` is an empty unordered item: optional
  /// indentation, `-`, `*`, or `+`, then at least one space or tab and nothing
  /// else before the line break.
  private func emptyBullet(in line: NSRange, source: NSString) -> Int? {
    var index = line.location
    let end = line.location + line.length
    while index < end, isIndentation(source.character(at: index)) { index += 1 }
    guard index + 1 < end else { return nil }
    let bullet = source.character(at: index)
    guard bullet == 0x2D || bullet == 0x2A || bullet == 0x2B,  // - * +
      isIndentation(source.character(at: index + 1))
    else { return nil }
    var rest = index + 1
    while rest < end, isIndentation(source.character(at: rest)) { rest += 1 }
    guard rest == end || isNewline(source.character(at: rest)) else { return nil }
    return index
  }

  /// Applies the unordered bullet tag and its marker styling to `bulletRange`.
  private func tagBullet(_ bulletRange: NSRange, in storage: NSTextStorage) {
    storage.addAttribute(.listBulletMarker, value: true, range: bulletRange)
    addColor(Typography.colorScheme.listBullet, to: bulletRange, in: storage)
    let style = Typography.listBulletStyle
    if let scalar = style.markerScalar {
      let markerFont = Typography.current.font(
        ofSize: Typography.baseSize * style.markerScale, weight: .regular)
      if style.markerScale != 1 {
        // The enlarged marker font would stretch the line; `EditorLayoutManager`
        // pins a bullet item's fragment back to the body's metrics (see
        // `shouldSetLineFragmentRect`).
        storage.addAttribute(.font, value: markerFont, range: bulletRange)
      }
      // Center the marker glyph on the body text's x-height. `•` and the other
      // shapes sit well above the baseline, more so once scaled, so without
      // this the bigger the marker the higher it floats above the line.
      let glyphMid = markerFont.glyphBoundingRect(for: scalar).midY
      let offset = TextStyle.body.font.xHeight / 2 - glyphMid + style.markerRaise
      if abs(offset) > 0.01 {
        storage.addAttribute(.baselineOffset, value: offset, range: bulletRange)
      }
    }
    if style.markerTrailingKern != 0 {
      storage.addAttribute(
        .kern, value: Typography.baseSize * style.markerTrailingKern, range: bulletRange)
    }
  }
}
