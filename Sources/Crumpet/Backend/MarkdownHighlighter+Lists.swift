import Foundation
import SwiftTreeSitter

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// List item styling: the hanging indent and the rendered bullet.
extension MarkdownHighlighter {
  /// Sets a hanging indent so wrapped and continuation lines align under the
  /// item's text. The indent is the rendered width of the prefix: leading
  /// indentation, marker, and the space after it. A nested item overrides it
  /// with its own deeper indent.
  func applyListIndent(
    _ node: Node, range: NSRange, in storage: NSTextStorage, source: NSString, base: Int
  ) {
    guard range.length > 0 else { return }
    // The prefix runs from the line start to the first child that is not the
    // marker. Measuring from the line start counts a nested item's leading
    // indentation, which tree-sitter assigns to the parent.
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

    // Replace the typed bullet's width with the width of the glyph it renders
    // as, including that glyph's scale and trailing kern.
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
    // Attribute fixing applies each paragraph's first-character style to the
    // whole paragraph, so the style must start at the paragraph start, not at
    // a nested item's marker.
    storage.addAttribute(.paragraphStyle, value: style, range: source.paragraphRange(for: range))
  }

  /// The range of an unordered item's bullet character, or nil for an
  /// ordered item.
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

  /// Tags an unordered item's bullet so the layout manager draws it as the
  /// glyph `Typography.listBulletStyle` selects. Ordered markers are left alone.
  func tagUnorderedBullet(
    _ node: Node, in storage: NSTextStorage, source: NSString, base: Int
  ) {
    if let bulletRange = unorderedBulletMarker(node, in: source, base: base) {
      tagBullet(bulletRange, in: storage)
    }
  }

  /// Tags the bullet of every empty unordered item (`- ` with only whitespace
  /// after it) in `ranges`. An empty item cannot interrupt a paragraph, so an
  /// empty nested item under an item's text is not parsed as a `list_item`.
  /// Lines in a code block according to `root` are skipped. With no `root`,
  /// every line is checked.
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

  /// The bullet's offset if `line` is optional indentation, `-`, `*`, or `+`,
  /// then only spaces or tabs.
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

  /// Applies the bullet tag, color, font, baseline offset, and kern.
  private func tagBullet(_ bulletRange: NSRange, in storage: NSTextStorage) {
    storage.addAttribute(.listBulletMarker, value: true, range: bulletRange)
    addColor(Typography.colorScheme.listBullet, to: bulletRange, in: storage)
    let style = Typography.listBulletStyle
    if let scalar = style.markerScalar {
      let markerFont = Typography.current.font(
        ofSize: Typography.baseSize * style.markerScale, weight: .regular)
      if style.markerScale != 1 {
        // `shouldSetLineFragmentRect` keeps the larger font from growing the line.
        storage.addAttribute(.font, value: markerFont, range: bulletRange)
      }
      // Centers the glyph on the body font's x-height.
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
