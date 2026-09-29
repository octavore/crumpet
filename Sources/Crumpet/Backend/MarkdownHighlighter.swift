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

/// Derives the editor's formatting from the text as Markdown, rather than from
/// stored rich-text attributes. The block grammar finds headings and code
/// blocks; the inline grammar finds emphasis and code spans within each
/// paragraph. The Markdown source stays the single source of truth for how
/// the document looks.
///
/// tree-sitter-markdown is a "split" grammar: the block parser leaves inline
/// content unparsed in `inline` nodes, which we re-parse with the inline parser.
///
/// The highlighter is the text storage's `NSTextStorageDelegate`. On each user
/// edit, `didProcessEditing` hands us the exact edited range and length delta,
/// so we don't have to reconstruct the edit by diffing.
///
/// To keep typing instant on long documents, work is split by layer instead of
/// done all at once:
///
///  - Per keystroke, we restyle only the cursor's paragraph, and only its
///    inline markup (emphasis, code spans), by parsing that paragraph's text
///    in isolation. This is bounded by the paragraph's length, not the
///    document's, so it stays fast regardless of file size.
///  - Block styling (heading size, code font, list indent) is never decided
///    from a lone paragraph, because a paragraph alone doesn't carry the
///    evidence for what block it is: `# foo` is a heading unless a fence three
///    paragraphs up made it code, and a setext heading is announced by the
///    line below it. Guessing would flash text into the wrong style
///    mid-keystroke, so we don't. A paragraph keeps the block style the last
///    whole-document parse gave it (recorded on the text as `.blockBase`)
///    until the next parse changes it.
///  - That whole-document reparse is debounced: it runs once typing pauses,
///    reusing untouched subtrees and restyling the paragraphs the parse says
///    changed, plus whatever the keystroke path touched. We still feed
///    tree-sitter a precise `InputEdit` on every keystroke so the tree stays
///    editable.
///  - Exception: a keystroke that reshapes a block (typing or deleting the `#`
///    of a heading, a bullet, a fence) skips the debounce and reparses
///    immediately. That's cheap to detect (the edit lands in the run of
///    marker characters at the start of its line), and it's the case the user
///    is waiting to see settle. It doesn't decide anything itself, though: a
///    `#` typed inside a code fence trips the same detector, and the parse
///    then correctly leaves the line as code.
///
/// The debounce is now a safety net rather than the main path: a block change
/// it catches (one the marker heuristic couldn't see) settles a moment later
/// instead of never.
///
/// Everything on the per-keystroke path is kept off the document's length:
///  - We read characters through `storage.mutableString`, a live non-copying
///    proxy, instead of `storage.string`, which snapshots the whole document.
///  - tree-sitter is fed a few-KB chunk at a time from that proxy, so an
///    incremental reparse only reads the regions near the edit.
///  - The row/column `Point`s an `InputEdit` needs come from a line-start
///    index maintained incrementally, so we never rescan the document
///    counting newlines, which would otherwise cost three passes per
///    keystroke on a large document.
///
/// Incremental tree reuse can collapse to an empty `(document)` node under
/// release optimization. As a safety net, if a reparse degenerates that way
/// over non-empty text, we discard the tree and parse from scratch, so
/// styling stays correct even if we occasionally pay for a full parse.
///
/// SwiftTreeSitter parses in UTF-16LE, so every byte offset tree-sitter
/// reports is a UTF-16 byte offset, exactly two per `NSString`/`NSRange`
/// UTF-16 code unit. That's why the range conversions here halve byte offsets.
@MainActor
final class MarkdownHighlighter: NSObject {
  let block = Parser()
  let inline = Parser()
  private let codeSyntax = CodeSyntaxHighlighter()

  /// The parse tree for the text currently in the storage, reused across edits
  /// for incremental parsing. Nil until the first parse, and reset whenever a
  /// reparse degenerates and we fall back to a fresh parse.
  var tree: MutableTree?

  /// UTF-16 offsets at which each line starts (`[0]` for an empty document), so
  /// `point(at:)` can find a row by binary search instead of scanning the whole
  /// document. Maintained incrementally across edits and rebuilt on a full parse.
  var lineStarts: [Int] = [0]

  /// UTF-16 length of the text the index and styling currently describe, so
  /// `nsRange` can clamp node ranges that reach past the document (tree-sitter
  /// sometimes reports a block's range out to a trailing position).
  var length = 0

  /// A full incremental reparse scheduled to run once typing pauses. Reset on
  /// every keystroke so it only fires when the user stops; cancelled whenever a
  /// whole-document parse supersedes it.
  var pendingParse: Task<Void, Never>?

  /// How long the document must stay idle before the deferred full reparse runs.
  /// Long enough that a normal typing burst never triggers it, short enough that
  /// any paragraph the local parse mis-styled is corrected almost immediately.
  let fullParseDelay: Duration = .milliseconds(600)

  /// The document range styled optimistically by a local paragraph parse since
  /// the last full parse. The deferred reparse re-styles it against the
  /// authoritative tree, so a paragraph the local parse couldn't classify (an
  /// edit inside a code fence) is corrected once typing pauses. A single span
  /// is enough: edits in one idle window cluster around the cursor, and
  /// over-covering only restyles a few extra paragraphs identically.
  var dirtySpan: NSRange?

  /// The characters the current edit actually replaced, recorded in
  /// `willProcessEditing`, the last moment it's knowable: the range handed to
  /// `didProcessEditing` has already been widened to whole paragraphs by
  /// attribute fixing. Nil when an edit reaches `applyEdit` without going
  /// through the delegate, in which case the widened range is used and simply
  /// over-triggers.
  private var touchedRange: NSRange?

  /// When true, `applyEdit` prints a per-phase timing breakdown. Diagnostic only.
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

  /// Full reparse and restyle of the entire document. Used for the initial
  /// render and any programmatic whole-document replacement. Safe to call from
  /// outside an edit transaction: it brackets its own begin/endEditing.
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

  /// Reacts to a single character edit: styles the edited paragraph immediately
  /// from a local parse, records the `InputEdit` for the deferred whole-document
  /// reparse, and (re)arms that reparse to run once typing pauses. `editedRange`
  /// is in the post-edit text; `delta` is the change in length (`changeInLength`).
  /// Must run inside the storage's edit processing: it mutates attributes
  /// directly, without begin/endEditing.
  func applyEdit(editedRange: NSRange, delta: Int, to storage: NSTextStorage) {
    let newLength = storage.length

    // No baseline tree, or a whole-document replacement (e.g. setAttributedString).
    // A fresh parse is both simpler and what incremental would reduce to anyway.
    let isWholeDoc = editedRange.location == 0 && editedRange.length == newLength
    guard let old = tree, !isWholeDoc else {
      fullRestyle(storage)
      return
    }

    let start = editedRange.location
    let newEnd = editedRange.location + editedRange.length
    let oldEnd = newEnd - delta

    // Whether the edit lands in a code block, whose contents are verbatim and
    // so have no inline markup to restyle. Asked of the previous tree before
    // `edit` shifts its offsets, since `start` is a valid offset in both texts.
    let inCode = old.rootNode.map { enclosedByCodeBlock($0, at: start) } ?? false

    // The start point is shared by both texts (the prefix is unchanged), but
    // the old end point must be read against the pre-edit line index, so
    // compute both before advancing the index. The byte offsets are
    // authoritative for tree-sitter; the points keep its column-sensitive
    // scanner honest.
    let t0 = debugTiming ? CFAbsoluteTimeGetCurrent() : 0
    let startPoint = point(at: start)
    let oldEndPoint = point(at: oldEnd)
    updateLineStarts(start: start, oldEnd: oldEnd, newEnd: newEnd, delta: delta, in: storage)
    length = newLength
    let newEndPoint = point(at: newEnd)
    let t1 = debugTiming ? CFAbsoluteTimeGetCurrent() : 0

    // Accumulate the edit on the tree so the deferred reparse is incremental,
    // but don't parse now: that whole-document cost is what we're deferring.
    old.edit(
      InputEdit(
        startByte: start * 2, oldEndByte: oldEnd * 2, newEndByte: newEnd * 2,
        startPoint: startPoint, oldEndPoint: oldEndPoint, newEndPoint: newEndPoint))

    // Immediate, length-independent restyling of the edited paragraph's inline
    // markup. Its block style is left alone; only a real parse changes that.
    let edited = styleEditedParagraph(around: editedRange, inCode: inCode, in: storage)
    let t2 = debugTiming ? CFAbsoluteTimeGetCurrent() : 0

    // Remember what we styled optimistically (shifting any earlier span for
    // this edit first) so the parse re-checks it against the real tree.
    dirtySpan = union(shift(dirtySpan, start: start, oldEnd: oldEnd, delta: delta), edited)

    // A keystroke that touches the line's block marker (typing or deleting the
    // `#` of a heading, a bullet, a fence) is the one that most needs an
    // answer now, and it's cheap to detect. It still doesn't get a guess: it
    // gets the real parse, early. Everything else rides the debounce. We're
    // inside edit processing, so the parse mutates attributes without its own
    // transaction.
    //
    // Skip the detector entirely inside a code block: its lines are verbatim,
    // so a `#` or `-` at the start of one is source text, not markup, and is a
    // shape real code repeats constantly (comments, YAML-ish lists). Without
    // this, every such keystroke would force an eager reparse instead of
    // riding the debounce like the rest of typing in code does. The one case
    // this defers, typing the marker that closes the fence, still settles,
    // just on the debounce rather than the keystroke.
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

  /// Whether the edit landed in the run of characters that decides what block
  /// its line is: the leading indentation and any block-marker characters
  /// after it (an ATX `#`, a bullet or number, a block quote `>`, a fence, a
  /// setext underline). Typing into the body of a line cannot change the
  /// line's block, so it doesn't qualify; typing at the very start of one
  /// always does.
  ///
  /// `touched` must be the range the edit actually replaced (see
  /// `touchedRange`), not the paragraph-widened range `didProcessEditing`
  /// reports: that one starts at the line's first character no matter where
  /// you typed, which would make every keystroke look like it touched the
  /// marker.
  ///
  /// A cheap over-approximation on purpose: a false positive costs one early
  /// parse (correct work, just sooner), while a false negative would leave a
  /// heading looking like body text until typing pauses. It's measured on the
  /// post-edit text, so deleting a marker is caught as surely as typing one:
  /// the line's marker run simply gets shorter, and the edit still sits
  /// inside it.
  private func reshapesBlocks(_ touched: NSRange, in storage: NSTextStorage) -> Bool {
    let source = storage.mutableString
    let location = min(touched.location, source.length)
    let line = source.paragraphRange(for: NSRange(location: location, length: 0))

    var index = line.location
    let limit = min(line.location + min(line.length, markerScanLimit), source.length)
    while index < limit, isMarkerCharacter(source.character(at: index)) { index += 1 }
    return location <= index
  }

  /// How far into a line to look for block markers. Well past any real marker (a
  /// deep list indent plus `10. `), and it keeps the scan constant-time.
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

  /// Whether `offset` sits inside a code block according to the current tree.
  /// False before the first parse.
  func isInCodeBlock(at offset: Int) -> Bool {
    guard let root = tree?.rootNode else { return false }
    return enclosedByCodeBlock(root, at: offset)
  }

  /// Whether `offset` sits inside a code block according to the tree `root`
  /// belongs to. That tree's byte space must describe the text `offset` was
  /// measured in. Cheap: one descendant lookup and a walk up the parent chain,
  /// no parsing.
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

  /// Which layer of styling a tree walk applies. The two are separate passes
  /// so a paragraph's block style can be recorded (`stampBlockBase`) after the
  /// blocks land but before inline markup is layered on top, and so the
  /// keystroke path can run the inline pass alone, leaving block styling to
  /// the authoritative parse that has the context to decide it.
  enum Phase {
    case block
    case inline
  }

  /// Resets the given ranges to the body style, re-applies the block styling the
  /// parse tree implies, records it as each paragraph's block base, then layers the
  /// inline markup over it. The tree walk prunes subtrees that fall entirely outside
  /// `ranges`, so an incremental edit only touches the paragraphs that changed.
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

  /// Records, on every paragraph in `ranges`, the block attributes it just
  /// received, so the keystroke path can restore them without re-deriving what
  /// kind of block the paragraph is, a judgement that needs the whole
  /// document. Runs between the two passes, when the text carries block
  /// styling and nothing else, which is exactly what the base has to be.
  ///
  /// Block attributes are uniform across a paragraph (a paragraph style must
  /// be, and nothing here varies font or color within a block), so the first
  /// character's attributes describe the whole of it.
  ///
  /// Attributes that vary *within* a paragraph are excluded, since the base is
  /// applied to the whole of it. Nothing here should be producing them: this
  /// runs between the block and inline passes, and per-character work belongs
  /// to the inline pass by that rule. The filter is what keeps that a rule
  /// rather than an accident — a table row's first character is a `|`, so
  /// tagging pipes in the block pass would smear "this character renders as
  /// nothing" across the entire row on the next keystroke.
  private func stampBlockBase(ranges: [NSRange], source: NSString, in storage: NSTextStorage) {
    forEachLine(covering: ranges.filter { $0.length > 0 }, in: source) { para in
      // Drop any base already stamped there, so a paragraph reached twice records
      // its attributes rather than a base nested inside a base.
      let base = storage.attributes(at: para.location, effectiveRange: nil)
        .filter { !Self.perCharacterKeys.contains($0.key) }
      storage.addAttribute(.blockBase, value: base, range: para)
    }
  }

  /// Attributes a paragraph's block base must never carry: the base itself
  /// (which would nest), and everything that describes one character rather
  /// than the block around it.
  private static let perCharacterKeys: Set<NSAttributedString.Key> = [
    .blockBase, .markdownMarker, .tableHidden, .kern, .listBulletMarker, .baselineOffset,
    .imageChip, .imageChipIcon, .imageBlock, .imageCaption, .linkChipIcon,
  ]

  // MARK: Block level

  /// `base` is the document offset (UTF-16 code units) of the parsed text's
  /// start: zero for the whole-document tree, the paragraph's location for a
  /// local parse whose byte offsets restart at zero. It is folded into every
  /// range conversion so styled ranges and `targets` are both in document
  /// coordinates.
  func styleBlock(
    _ node: Node, in storage: NSTextStorage, source: NSString, targets: [NSRange], base: Int = 0,
    phase: Phase
  ) {
    let range = nsRange(node.byteRange, base: base)
    guard intersects(range, targets) else { return }

    switch node.nodeType ?? "" {
    case "atx_heading", "setext_heading":
      // Only ATX headings (`#`, `##`) are styled. Setext headings (`===`, `---`)
      // are left as plain text, since a `-` line under a list item's text (an
      // empty nested bullet) would otherwise turn the item into a heading.
      if node.nodeType == "setext_heading" { break }
      if phase == .block { apply(headingStyle(for: node), to: range, in: storage) }
      // The marker tag is per-character work, so it runs in the inline pass:
      // the block base excludes it, and the keystroke path re-applies only the
      // inline pass. See `stampBlockBase`.
      if phase == .inline, node.nodeType == "atx_heading" {
        tagHeadingMarker(node, range: range, in: storage, source: source, base: base)
      }
    case "fenced_code_block", "indented_code_block":
      if phase == .block { applyCode(to: range, in: storage) }
      // Token colors are per-character work, so they run in the inline pass.
      if phase == .inline, node.nodeType == "fenced_code_block" {
        highlightFence(node, in: storage, source: source, base: base)
      }
      return  // code is verbatim; don't descend for inline emphasis
    case "pipe_table":
      // Experimental and off by default: leave the table as plain text, its
      // pipes and delimiter row visible. Break to the child descent so cell
      // contents still get inline emphasis and code spans.
      if !Typography.tablesEnabled { break }
      if phase == .block {
        // Monospace the whole table: a fixed advance width is what keeps the
        // source readable while it's being edited, and what makes the measured
        // column widths hold still as you type into a cell. Then fall through
        // to the descent, which bolds the header row.
        applyTableFont(to: range, in: storage)
        break
      }
      // The measured grid, in the inline phase and after the descent, so every
      // cell is already in the font it renders in. See `layoutTable`.
      for index in 0..<node.childCount {
        if let child = node.child(at: index) {
          styleBlock(child, in: storage, source: source, targets: targets, base: base, phase: phase)
        }
      }
      layoutTable(node, in: storage, source: source, base: base)
      return
    case "pipe_table_header":
      // The header row's cells, set bold over the monospaced base.
      if phase == .block, Typography.tablesEnabled {
        addTrait(.boldTrait, to: range, in: storage)
      }
    case "pipe_table_delimiter_row":
      // The `|---|:--:|` line is markup the rendered grid hides outright, so
      // there is nothing to style. With tables off it stays visible as text;
      // descend so a stray emphasis marker on it still parses.
      if !Typography.tablesEnabled { break }
      return
    case "pipe_table_cell":
      // Cells aren't `inline` nodes in the block grammar, so re-parse each one
      // for emphasis and code spans the way `styleInline` does for paragraphs.
      if phase == .inline {
        styleInline(node, range: range, in: storage, source: source, base: base)
      }
      return
    case "list_item":
      // Hang the item's wrapped and continuation lines under its text, then keep
      // descending so the marker's own paragraph and any nested list still get
      // styled (a nested item overrides this indent with its own, deeper one).
      if phase == .block {
        applyListIndent(node, range: range, in: storage, source: source, base: base)
      }
      // The marker tag and its font run in the inline pass, not the block one:
      // `stampBlockBase` samples the paragraph's first character (the marker)
      // between the passes, so an enlarged marker font applied in the block
      // pass would be recorded as the whole item's block base and then smeared
      // across every character the next keystroke restyles. Layering it in the
      // inline pass also means the keystroke path re-applies it, so the marker
      // keeps its glyph while typing instead of flashing back to `-`.
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

    // recurse into children to find nested blocks and inlines
    for index in 0..<node.childCount {
      if let child = node.child(at: index) {
        styleBlock(child, in: storage, source: source, targets: targets, base: base, phase: phase)
      }
    }
  }

  /// Whether `range` overlaps any range we are restyling. The document root
  /// spans everything and so always passes, letting the walk descend; blocks
  /// outside the changed paragraphs are pruned.
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

  /// Marks an ATX heading's `#` prefix (and the space after it) for concealment.
  /// When revealed, the prefix takes its normal width and pushes the heading
  /// text right. See ``NSAttributedString/Key/markdownMarker``.
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

    // The heading node includes its line terminator. Both the prefix and the
    // reveal span stop before it: `touches` treats the span's end as inclusive,
    // so a span ending at the next line's start would stay revealed with the
    // caret on that line.
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

    // The whole heading line is the reveal span: touching the text, not just
    // the `#`s, is enough to bring the prefix back, matching how emphasis and
    // code spans reveal from anywhere inside them.
    storage.addAttribute(
      .markdownMarker, value: MarkerSpan.value(span: span, marker: markerRange),
      range: markerRange)
  }

  // MARK: Attribute application

  /// Sets a block style's font, paragraph, and color across `range`.
  private func apply(_ style: TextStyle, to range: NSRange, in storage: NSTextStorage) {
    storage.addAttributes(style.attributes, range: range)
  }

  /// Unions a symbolic trait onto whatever font each run already carries, so a
  /// heading stays heading-sized when its words are also `**bold**`.
  func addTrait(_ trait: FontTraits, to range: NSRange, in storage: NSTextStorage) {
    storage.enumerateAttribute(.font, in: range) { value, runRange, _ in
      let current = value as? PlatformFont ?? TextStyle.body.font
      storage.addAttribute(
        .font, value: current.with(traits: current.traits.union(trait)), range: runRange)
    }
  }

  /// Sets a table's font to the monospaced system face at the body size,
  /// without code's size ratio or color: a table is content, not code, it just
  /// needs a fixed advance width so the source stays readable as it's edited.
  ///
  /// The paragraph style stops rows from soft-wrapping. A padded row is wider
  /// than its source text, so a table close to the column width would wrap
  /// mid-row, and the grid stroked around it would have no relation to where
  /// the cells ended up. Clipping keeps one line fragment per row: a table too
  /// wide for the column is cut off at the edge rather than scrambled.
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

  /// Code blocks render at `Typography.codeRatio` × the base size. An inline
  /// code span (`inline: true`) renders at that ratio of the size it sits in,
  /// so a span inside a heading scales with the heading. The inline pass only
  /// runs over text already reset to its block base, so the ratio is applied
  /// once.
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
  /// supported language. Blocks with no language or an unsupported one keep
  /// the plain code color.
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

  /// The first word of a fence's info string, which names the language.
  private func infoLanguage(_ info: Node, source: NSString, base: Int) -> String? {
    let range = nsRange(info.byteRange, base: base)
    guard range.length > 0 else { return nil }
    let text = source.substring(with: range)
    return text.split(whereSeparator: { $0.isWhitespace || $0 == "{" }).first.map(String.init)
  }

  /// Sets a construct's foreground color without disturbing its font, so
  /// layering (e.g. a bold word inside a heading) only overrides color.
  func addColor(_ color: Color, to range: NSRange, in storage: NSTextStorage) {
    storage.addAttribute(.foregroundColor, value: PlatformColor(color), range: range)
  }

  // MARK: Range conversion

  /// Converts a tree-sitter UTF-16 byte range into an `NSRange` (UTF-16 code
  /// units). Each code unit is two bytes, so the bounds halve cleanly; `base`
  /// (a code-unit document offset) shifts a local parse's zero-based ranges into
  /// document coordinates; both are clamped to the current length so a node
  /// reaching past the document yields a valid (possibly empty) range rather than
  /// throwing when it's applied.
  func nsRange(_ byteRange: Range<UInt32>, base: Int = 0) -> NSRange {
    let lower = min(Int(byteRange.lowerBound) / 2 + base, length)
    let upper = min(Int(byteRange.upperBound) / 2 + base, length)
    return NSRange(location: lower, length: upper - lower)
  }

  /// The blocks that carry their own styling: the ones a restyle both resets
  /// and re-derives. Containers (`list`, `block_quote`, `section`, `document`)
  /// are deliberately absent: expanding to those would restyle an entire list
  /// on every edit to one item, and their styling is applied through the
  /// items inside them.
  private static let styledBlocks: Set<String> = [
    "paragraph", "atx_heading", "setext_heading", "fenced_code_block",
    "indented_code_block", "html_block", "link_reference_definition", "thematic_break",
    "pipe_table",
  ]

  /// Grows each range to the whole block at either end of it.
  ///
  /// Restyling resets a range to the body style and then re-applies whatever
  /// the tree says, which is only sound if the reset covers everything the
  /// tree walk will style. It doesn't, by default: styling follows nodes, and
  /// a node can reach past the range that selected it (an `inline` node spans
  /// a whole markdown paragraph, which may be several lines). Reset one of
  /// those lines and delete the code span that used to run across them, and
  /// the walk re-derives the paragraph's now-empty inline styling while the
  /// other line keeps the monospace forever. So reset the block, not the
  /// line.
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

  /// The styled block containing `offset`, if any: the nearest ancestor of
  /// the node there whose kind owns styling of its whole extent.
  private func enclosingBlock(at offset: Int, root: Node) -> NSRange? {
    ancestor(at: offset, root: root, in: Self.styledBlocks).map { nsRange($0.byteRange) }
  }

  /// Expands each range to whole paragraphs, so block styling (headings, code
  /// fences, spacing) is recomputed against entire lines. Overlapping results
  /// are harmless: restyle just re-applies the same attributes.
  func paragraphs(covering ranges: [NSRange], in ns: NSString) -> [NSRange] {
    ranges.map { r in
      let location = min(r.location, ns.length)
      let clamped = NSRange(location: location, length: min(r.length, ns.length - location))
      return ns.paragraphRange(for: clamped)
    }
  }
}

extension MarkdownHighlighter: @preconcurrency NSTextStorageDelegate {
  /// The single place user edits trigger restyling. Fires after the storage
  /// applies an edit; `.editedCharacters` distinguishes a text change from the
  /// attribute changes we make here (which would otherwise recurse).
  /// Fires *before* the storage fixes attributes, which is the only place the
  /// edit's true extent is visible: by `didProcessEditing` the range has been
  /// widened to whole paragraphs (a one-character insert arrives as the entire
  /// line). `applyEdit` needs the real one to tell an edit that touched a line's
  /// block marker from one that didn't.
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
