import Foundation
import SwiftTreeSitter
import SwiftUI
import TreeSitterMarkdown
import TreeSitterMarkdownInline

#if canImport(UIKit)
  import UIKit
  typealias TextStorageEditActions = NSTextStorage.EditActions
#elseif canImport(AppKit)
  import AppKit
  typealias TextStorageEditActions = NSTextStorageEditActions
#endif

/// Derives the editor's formatting from the Markdown source. The block grammar
/// finds block structure and leaves inline content in `inline` nodes, which
/// are re-parsed with the inline grammar.
///
/// The highlighter is the text storage's delegate. Work is split so typing
/// stays fast on long documents:
///
///  - Per keystroke, only the edited paragraph's inline markup is restyled,
///    from a parse of that paragraph alone. Its block style is restored from
///    `.blockBase`, the style the last whole-document parse gave it.
///  - The whole-document reparse is incremental and debounced. A keystroke
///    that touches a line's block marker runs it immediately instead.
///  - Characters are read through `storage.mutableString` and tree-sitter is
///    fed small chunks, so no per-keystroke work scales with document length.
///
/// SwiftTreeSitter parses UTF-16LE, so every tree-sitter byte offset is two
/// per `NSString` code unit.
@MainActor
final class MarkdownHighlighter: NSObject {
  let block = Parser()
  let inline = Parser()
  private let codeSyntax = CodeSyntaxHighlighter()

  /// The parse tree for the current text, reused for incremental parsing. Nil
  /// until the first parse.
  var tree: MutableTree?

  /// UTF-16 offset of each line start, for `point(at:)`.
  var lineStarts: [Int] = [0]

  /// UTF-16 length of the text the tree describes. `nsRange` clamps to it.
  var length = 0

  /// The debounced whole-document reparse, if one is scheduled.
  var pendingParse: Task<Void, Never>?

  let fullParseDelay: Duration = .milliseconds(600)

  /// The range styled by local parses since the last full parse. The full
  /// parse restyles it against the whole-document tree.
  var dirtySpan: NSRange?

  /// The range the current edit replaced, recorded in `willProcessEditing`.
  /// By `didProcessEditing` the range has been widened to whole paragraphs.
  private var touchedRange: NSRange?

  /// When true, `applyEdit` and `runFullParse` print timings.
  var debugTiming = false

  override init() {
    super.init()
    do {
      try block.setLanguage(Language(tree_sitter_markdown()))
      try inline.setLanguage(Language(tree_sitter_markdown_inline()))
    } catch {
      print("MarkdownHighlighter: setLanguage failed: \(error)")
    }
  }

  // MARK: Entry points

  /// Parses and restyles the whole document. Brackets its own
  /// begin/endEditing.
  func highlight(_ storage: NSTextStorage) {
    pendingParse?.cancel()
    pendingParse = nil
    dirtySpan = nil
    guard let root = freshParse(storage) else { return }
    storage.beginEditing()
    restyle(
      ranges: [NSRange(location: 0, length: storage.length)], root: root,
      source: storage.mutableString, in: storage)
    storage.endEditing()
  }

  /// Handles one edit: restyles the edited paragraph from a local parse,
  /// records the edit on the tree, and runs or schedules the full reparse.
  /// `editedRange` is in the post-edit text. Runs inside the storage's edit
  /// processing, so it mutates attributes without begin/endEditing.
  func applyEdit(editedRange: NSRange, delta: Int, to storage: NSTextStorage) {
    let newLength = storage.length

    let isWholeDoc = editedRange.location == 0 && editedRange.length == newLength
    guard let old = tree, !isWholeDoc else {
      fullRestyle(storage)
      return
    }

    let start = editedRange.location
    let newEnd = editedRange.location + editedRange.length
    let oldEnd = newEnd - delta

    // Asked of the tree before `edit` shifts its offsets. `start` is valid in
    // both the old and new text.
    let inCode = old.rootNode.map { enclosedByCodeBlock($0, at: start) } ?? false

    // The old end point is read from the line index before it is updated.
    let t0 = debugTiming ? CFAbsoluteTimeGetCurrent() : 0
    let startPoint = point(at: start)
    let oldEndPoint = point(at: oldEnd)
    updateLineStarts(start: start, oldEnd: oldEnd, newEnd: newEnd, delta: delta, in: storage)
    length = newLength
    let newEndPoint = point(at: newEnd)
    let t1 = debugTiming ? CFAbsoluteTimeGetCurrent() : 0

    old.edit(
      InputEdit(
        startByte: start * 2, oldEndByte: oldEnd * 2, newEndByte: newEnd * 2,
        startPoint: startPoint, oldEndPoint: oldEndPoint, newEndPoint: newEndPoint))

    let edited = styleEditedParagraph(around: editedRange, inCode: inCode, in: storage)
    let t2 = debugTiming ? CFAbsoluteTimeGetCurrent() : 0

    dirtySpan = union(shift(dirtySpan, start: start, oldEnd: oldEnd, delta: delta), edited)

    // An edit to a line's block marker reparses now. Inside a code block a
    // leading `#` or `-` is source text, so the edit waits for the debounce.
    let touched = touchedRange ?? editedRange
    touchedRange = nil
    if !inCode, reshapesBlocks(touched, in: storage) {
      runFullParse(storage, bracketing: false)
    } else {
      scheduleFullParse(for: storage)
    }

    if debugTiming {
      let ms = { (a: CFAbsoluteTime, b: CFAbsoluteTime) in String(format: "%.2f", (b - a) * 1000) }
      print(
        "applyEdit: lineIndex+points=\(ms(t0, t1))ms localParse+restyle=\(ms(t1, t2))ms "
          + "(paragraph \(edited.length) chars)")
    }
  }

  /// Whether `touched` lies in its line's leading run of indentation and
  /// block-marker characters, so the edit may change the line's block type.
  /// Deliberately over-approximates: a false positive only costs an early
  /// parse. `touched` must be the replaced range, not the widened one.
  private func reshapesBlocks(_ touched: NSRange, in storage: NSTextStorage) -> Bool {
    let source = storage.mutableString
    let location = min(touched.location, source.length)
    let line = source.paragraphRange(for: NSRange(location: location, length: 0))

    var index = line.location
    let limit = min(line.location + min(line.length, markerScanLimit), source.length)
    while index < limit, isMarkerCharacter(source.character(at: index)) { index += 1 }
    return location <= index
  }

  /// How far into a line to look for block markers.
  private let markerScanLimit = 24

  private func isMarkerCharacter(_ character: unichar) -> Bool {
    switch character {
    case 0x20, 0x09: true  // space, tab: leading indentation
    case 0x23: true  // #  atx heading
    case 0x3E: true  // >  block quote
    case 0x2D, 0x2A, 0x2B: true  // - * +  bullets (and `-` setext underline)
    case 0x3D: true  // =  setext underline
    case 0x60, 0x7E: true  // ` ~  code fences
    case 0x30...0x39: true  // digits: ordered list
    case 0x2E, 0x29: true  // . )  ordered list delimiters
    default: false
    }
  }

  // MARK: Text and tree helpers

  func isIndentation(_ character: unichar) -> Bool {
    character == 0x20 || character == 0x09
  }

  func isNewline(_ character: unichar) -> Bool {
    character == 0x0A || character == 0x0D
  }

  /// Whether `offset` is inside a code block according to the current tree.
  /// False before the first parse.
  func isInCodeBlock(at offset: Int) -> Bool {
    guard let root = tree?.rootNode else { return false }
    return enclosedByCodeBlock(root, at: offset)
  }

  /// Whether `offset` is inside a code block in the tree `root` belongs to.
  /// That tree must describe the text `offset` was measured in.
  func enclosedByCodeBlock(_ root: Node, at offset: Int) -> Bool {
    ancestor(at: offset, root: root, in: Self.codeBlocks) != nil
  }

  private static let codeBlocks: Set<String> = ["fenced_code_block", "indented_code_block"]

  /// The node at `offset`, or its nearest ancestor, whose type is in `types`.
  private func ancestor(at offset: Int, root: Node, in types: Set<String>) -> Node? {
    let byte = UInt32(max(0, min(offset, length)) * 2)
    var node = root.descendant(in: byte..<byte)
    while let current = node {
      if types.contains(current.nodeType ?? "") { return current }
      node = current.parent
    }
    return nil
  }

  /// Calls `body` with each line, including its line break, of the paragraphs
  /// covering `ranges`.
  func forEachLine(
    covering ranges: [NSRange], in source: NSString, _ body: (NSRange) -> Void
  ) {
    for span in paragraphs(covering: ranges, in: source) {
      var location = span.location
      let end = span.location + span.length
      while location < end {
        let line = source.paragraphRange(for: NSRange(location: location, length: 0))
        guard line.length > 0 else { break }
        body(line)
        location = line.location + line.length
      }
    }
  }

  // MARK: Restyling

  /// The two passes of a tree walk. Block styling is recorded as the block
  /// base between them, and the keystroke path runs the inline pass alone.
  enum Phase {
    case block
    case inline
  }

  /// Resets `ranges` to the body style, applies block styling, records the
  /// block base, then applies inline styling.
  func restyle(
    ranges: [NSRange], root: Node, source: NSString, in storage: NSTextStorage
  ) {
    for range in ranges where range.length > 0 {
      storage.setAttributes(TextStyle.body.attributes, range: range)
    }
    styleBlock(root, in: storage, source: source, targets: ranges, phase: .block)
    stampBlockBase(ranges: ranges, source: source, in: storage)
    styleBlock(root, in: storage, source: source, targets: ranges, phase: .inline)
    tagEmptyBullets(in: ranges, root: root, source: source, storage: storage)
  }

  /// Records each paragraph's block attributes as `.blockBase`, so the
  /// keystroke path can restore them without a whole-document parse. Uses the
  /// first character's attributes, minus per-character keys. Per-character
  /// work must run in the inline pass, or it would be copied across the
  /// whole paragraph on the next keystroke.
  private func stampBlockBase(ranges: [NSRange], source: NSString, in storage: NSTextStorage) {
    forEachLine(covering: ranges.filter { $0.length > 0 }, in: source) { para in
      // Filtering out `.blockBase` keeps a base from nesting inside another.
      let base = storage.attributes(at: para.location, effectiveRange: nil)
        .filter { !Self.perCharacterKeys.contains($0.key) }
      storage.addAttribute(.blockBase, value: base, range: para)
    }
  }

  /// Attributes a block base never carries.
  private static let perCharacterKeys: Set<NSAttributedString.Key> = [
    .blockBase, .markdownMarker, .tableHidden, .kern, .listBulletMarker, .baselineOffset,
    .imageChip, .imageChipIcon, .imageBlock, .imageCaption, .linkChipIcon,
  ]

  // MARK: Block level

  /// Styles `node` and its descendants that intersect `targets`. `base` is
  /// the document offset of the parsed text: zero for the whole-document
  /// tree, the paragraph's location for a local parse.
  func styleBlock(
    _ node: Node, in storage: NSTextStorage, source: NSString, targets: [NSRange], base: Int = 0,
    phase: Phase
  ) {
    let range = nsRange(node.byteRange, base: base)
    guard intersects(range, targets) else { return }

    switch node.nodeType ?? "" {
    case "atx_heading", "setext_heading":
      // Setext headings are left as plain text, since a `-` line under a list
      // item's text (an empty nested bullet) would otherwise make a heading.
      if node.nodeType == "setext_heading" { break }
      if phase == .block { apply(headingStyle(for: node), to: range, in: storage) }
      if phase == .inline, node.nodeType == "atx_heading" {
        tagHeadingMarker(node, range: range, in: storage, source: source, base: base)
      }
    case "fenced_code_block", "indented_code_block":
      if phase == .block { applyCode(to: range, in: storage) }
      if phase == .inline, node.nodeType == "fenced_code_block" {
        highlightFence(node, in: storage, source: source, base: base)
      }
      return  // code is verbatim; don't descend for inline emphasis
    case "pipe_table":
      // With tables off, the table stays plain text and its cells still get
      // inline styling from the descent.
      if !Typography.tablesEnabled { break }
      if phase == .block {
        // Monospace keeps the measured column widths stable while typing.
        applyTableFont(to: range, in: storage)
        break
      }
      // The grid is laid out after the descent, once every cell has its font.
      for index in 0..<node.childCount {
        if let child = node.child(at: index) {
          styleBlock(child, in: storage, source: source, targets: targets, base: base, phase: phase)
        }
      }
      layoutTable(node, in: storage, source: source, base: base)
      return
    case "pipe_table_header":
      if phase == .block, Typography.tablesEnabled {
        addTrait(.boldTrait, to: range, in: storage)
      }
    case "pipe_table_delimiter_row":
      if !Typography.tablesEnabled { break }
      return
    case "pipe_table_cell":
      // Cells are not `inline` nodes, so each is re-parsed here.
      if phase == .inline {
        styleInline(node, range: range, in: storage, source: source, base: base)
      }
      return
    case "list_item":
      // A nested item overrides this indent with its own.
      if phase == .block {
        applyListIndent(node, range: range, in: storage, source: source, base: base)
      }
      // The bullet's font is per-character, so it is applied in the inline
      // pass. The keystroke path then re-applies it too.
      if phase == .inline {
        tagUnorderedBullet(node, in: storage, source: source, base: base)
      }
    case "inline":
      if phase == .inline {
        styleInline(node, range: range, in: storage, source: source, base: base)
      }
      return
    default:
      break
    }

    for index in 0..<node.childCount {
      if let child = node.child(at: index) {
        styleBlock(child, in: storage, source: source, targets: targets, base: base, phase: phase)
      }
    }
  }

  private func intersects(_ range: NSRange, _ targets: [NSRange]) -> Bool {
    targets.contains { NSIntersectionRange(range, $0).length > 0 }
  }

  /// Title for a level-1 heading, otherwise the heading style.
  private func headingStyle(for node: Node) -> TextStyle {
    for index in 0..<node.childCount {
      switch node.child(at: index)?.nodeType ?? "" {
      case "atx_h1_marker", "setext_h1_underline": return .title
      default: continue
      }
    }
    return .heading
  }

  /// Marks an ATX heading's `#` prefix and the space after it for
  /// concealment. The prefix reveals when the caret touches the heading line.
  private func tagHeadingMarker(
    _ node: Node, range: NSRange, in storage: NSTextStorage, source: NSString, base: Int
  ) {
    guard range.length > 0 else { return }
    var sawMarker = false
    var contentStart: Int?
    for index in 0..<node.childCount {
      guard let child = node.child(at: index) else { continue }
      let type = child.nodeType ?? ""
      if type.hasPrefix("atx_h"), type.hasSuffix("_marker") {
        sawMarker = true
        continue
      }
      if sawMarker {
        contentStart = nsRange(child.byteRange, base: base).location
        break
      }
    }
    guard sawMarker else { return }

    // The span stops before the line break. A span ending at the next line's
    // start would stay revealed with the caret on that line.
    var lineStart = 0
    var lineEnd = 0
    var contentsEnd = 0
    source.getLineStart(
      &lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
      for: NSRange(location: range.location, length: 0))
    let prefixEnd = min(contentStart ?? contentsEnd, contentsEnd)
    let prefixLength = max(0, prefixEnd - lineStart)
    guard prefixLength > 0 else { return }
    let markerRange = NSRange(location: lineStart, length: prefixLength)
    let span = NSRange(location: lineStart, length: contentsEnd - lineStart)

    storage.addAttribute(
      .markdownMarker, value: MarkerSpan.value(span: span, marker: markerRange),
      range: markerRange)
  }

  // MARK: Attribute application

  private func apply(_ style: TextStyle, to range: NSRange, in storage: NSTextStorage) {
    storage.addAttributes(style.attributes, range: range)
  }

  /// Adds a symbolic trait to each run's existing font, so bold text in a
  /// heading keeps the heading size.
  func addTrait(_ trait: FontTraits, to range: NSRange, in storage: NSTextStorage) {
    storage.enumerateAttribute(.font, in: range) { value, runRange, _ in
      let current = value as? PlatformFont ?? TextStyle.body.font
      storage.addAttribute(
        .font, value: current.with(traits: current.traits.union(trait)), range: runRange)
    }
  }

  /// Sets a table to the monospaced system font at body size. Rows clip
  /// instead of wrapping, so each row stays one line fragment and matches the
  /// stroked grid.
  private func applyTableFont(to range: NSRange, in storage: NSTextStorage) {
    let style = NSMutableParagraphStyle()
    style.setParagraphStyle(TextStyle.body.paragraphStyle)
    style.lineBreakMode = .byClipping
    storage.addAttributes(
      [
        .font: PlatformFont.monospacedSystemFont(
          ofSize: Typography.baseSize, weight: .regular),
        .paragraphStyle: style,
      ], range: range)
  }

  /// Code blocks render at `Typography.codeRatio` times the base size. An
  /// inline code span (`inline: true`) renders at that ratio of the font it
  /// sits in, so a span in a heading scales with the heading.
  func applyCode(to range: NSRange, in storage: NSTextStorage, inline: Bool = false) {
    if inline {
      storage.enumerateAttribute(.font, in: range) { value, runRange, _ in
        let context = (value as? PlatformFont)?.pointSize ?? Typography.baseSize
        let size = (context * Typography.codeRatio).rounded()
        storage.addAttribute(
          .font, value: PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular),
          range: runRange)
      }
    } else {
      let size = (Typography.baseSize * Typography.codeRatio).rounded()
      storage.addAttribute(
        .font, value: PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular),
        range: range)
    }
    addColor(Typography.colorScheme.code, to: range, in: storage)
  }

  /// Colors the tokens of a fenced code block whose info string names a
  /// supported language.
  private func highlightFence(
    _ node: Node, in storage: NSTextStorage, source: NSString, base: Int
  ) {
    var language: String?
    var content: Node?
    for index in 0..<node.childCount {
      guard let child = node.child(at: index) else { continue }
      switch child.nodeType ?? "" {
      case "info_string": language = infoLanguage(child, source: source, base: base)
      case "code_fence_content": content = child
      default: break
      }
    }
    guard let language, CodeSyntaxHighlighter.supports(language), let content else { return }
    let range = nsRange(content.byteRange, base: base)
    guard range.length > 0 else { return }
    let colors = Typography.colorScheme.syntax
    let tokens = codeSyntax.tokens(
      of: source.substring(with: range) as NSString, language: language)
    for token in tokens {
      let color: Color =
        switch token.kind {
        case .keyword: colors.keyword
        case .string: colors.string
        case .number: colors.number
        case .comment: colors.comment
        case .function: colors.function
        case .property: colors.property
        }
      let tokenRange = NSRange(
        location: range.location + token.range.location, length: token.range.length)
      guard NSMaxRange(tokenRange) <= NSMaxRange(range) else { continue }
      addColor(color, to: tokenRange, in: storage)
    }
  }

  /// The first word of a fence's info string.
  private func infoLanguage(_ info: Node, source: NSString, base: Int) -> String? {
    let range = nsRange(info.byteRange, base: base)
    guard range.length > 0 else { return nil }
    let text = source.substring(with: range)
    return text.split(whereSeparator: { $0.isWhitespace || $0 == "{" }).first.map(String.init)
  }

  func addColor(_ color: Color, to range: NSRange, in storage: NSTextStorage) {
    storage.addAttribute(.foregroundColor, value: PlatformColor(color), range: range)
  }

  // MARK: Range conversion

  /// Converts a tree-sitter byte range to an `NSRange`, shifted by `base` and
  /// clamped to `length`.
  func nsRange(_ byteRange: Range<UInt32>, base: Int = 0) -> NSRange {
    let lower = min(Int(byteRange.lowerBound) / 2 + base, length)
    let upper = min(Int(byteRange.upperBound) / 2 + base, length)
    return NSRange(location: lower, length: upper - lower)
  }

  /// Blocks a restyle resets and re-derives as a unit. Containers such as
  /// `list` are excluded, so editing one item does not restyle the whole list.
  private static let styledBlocks: Set<String> = [
    "paragraph", "atx_heading", "setext_heading", "fenced_code_block",
    "indented_code_block", "html_block", "link_reference_definition", "thematic_break",
    "pipe_table",
  ]

  /// Grows each range to the whole styled block at either end. A node's
  /// styling can extend past the range that selected it (an `inline` node
  /// spans a multi-line paragraph), so the reset has to cover the block.
  func blocks(covering ranges: [NSRange], root: Node) -> [NSRange] {
    ranges.map { range in
      let last = max(range.location, range.location + range.length - 1)
      var expanded = range
      if let start = enclosingBlock(at: range.location, root: root) {
        expanded = NSUnionRange(expanded, start)
      }
      if let end = enclosingBlock(at: last, root: root) {
        expanded = NSUnionRange(expanded, end)
      }
      return expanded
    }
  }

  private func enclosingBlock(at offset: Int, root: Node) -> NSRange? {
    ancestor(at: offset, root: root, in: Self.styledBlocks).map { nsRange($0.byteRange) }
  }

  /// Expands each range to whole paragraphs.
  func paragraphs(covering ranges: [NSRange], in ns: NSString) -> [NSRange] {
    ranges.map { r in
      let location = min(r.location, ns.length)
      let clamped = NSRange(location: location, length: min(r.length, ns.length - location))
      return ns.paragraphRange(for: clamped)
    }
  }
}

extension MarkdownHighlighter: @preconcurrency NSTextStorageDelegate {
  /// Records the replaced range before attribute fixing widens it to whole
  /// paragraphs. `.editedCharacters` separates text edits from the attribute
  /// changes the highlighter makes itself.
  func textStorage(
    _ textStorage: NSTextStorage,
    willProcessEditing editedMask: TextStorageEditActions,
    range editedRange: NSRange,
    changeInLength delta: Int
  ) {
    guard editedMask.contains(.editedCharacters) else { return }
    touchedRange = editedRange
  }

  func textStorage(
    _ textStorage: NSTextStorage,
    didProcessEditing editedMask: TextStorageEditActions,
    range editedRange: NSRange,
    changeInLength delta: Int
  ) {
    guard editedMask.contains(.editedCharacters) else { return }
    applyEdit(editedRange: editedRange, delta: delta, to: textStorage)
  }
}
