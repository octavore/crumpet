import Foundation
import SwiftTreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Derives the editor's formatting from the text *as Markdown* rather than
/// from stored rich-text attributes. The block grammar finds headings and code
/// blocks; the inline grammar finds emphasis and code spans within each
/// paragraph's content. The Markdown source stays the single source of truth
/// for how the document looks.
///
/// tree-sitter-markdown is a "split" grammar: the block parser leaves inline
/// content unparsed in `inline` nodes, which we re-parse with the inline parser.
///
/// The highlighter is the text storage's `NSTextStorageDelegate`. On each user
/// edit `didProcessEditing` hands us the exact edited range and length delta,
/// far better than reconstructing the edit by diffing.
///
/// To keep typing instant on long documents, the per-keystroke path does the
/// least work that styles the cursor's paragraph correctly: it parses *only
/// that one paragraph's text* in isolation and restyles it. This is bounded by
/// the paragraph's length, not the document's, so it stays fast regardless of
/// file size. We still feed tree-sitter a precise `InputEdit` so the full tree
/// stays editable, but the expensive whole-document reparse is *debounced*: it
/// runs once typing pauses, reusing untouched subtrees and restyling the
/// paragraphs the parse says changed, plus any paragraph the local parse styled
/// optimistically. The only visible cost is a brief hitch on a huge document
/// when you stop, and a rare transient mis-style of multi-paragraph constructs
/// (an open code fence) until that deferred parse catches up.
///
/// Everything on the per-keystroke path is kept off the document's length:
///  - We read characters through `storage.mutableString`, a live non-copying
///    proxy, instead of `storage.string`, which snapshots the whole document.
///  - tree-sitter is fed a few-KB chunk at a time from that proxy, so an
///    incremental reparse only reads the regions near the edit.
///  - The row/column `Point`s an `InputEdit` needs come from a line-start index
///    maintained incrementally, so we never rescan the document counting
///    newlines, which would otherwise cost three passes per keystroke on a
///    large document.
///
/// Incremental tree reuse can collapse to an empty `(document)` node under
/// release optimization. As a safety net, if a reparse degenerates that way
/// over non-empty text, we throw the tree away and parse from scratch, so
/// styling stays correct even if we occasionally pay for a full parse.
///
/// SwiftTreeSitter parses in UTF-16LE, so every byte offset tree-sitter reports
/// is a UTF-16 *byte* offset, exactly two per `NSString`/`NSRange` UTF-16 code
/// unit, which is why the range conversions here halve byte offsets.
@MainActor
final class MarkdownHighlighter: NSObject {
  private let block = Parser()
  private let inline = Parser()

  /// The parse tree for the text currently in the storage, reused across edits
  /// for incremental parsing. Nil until the first parse, and reset whenever a
  /// reparse degenerates and we fall back to a fresh parse.
  private var tree: MutableTree?

  /// UTF-16 offsets at which each line starts (`[0]` for an empty document), so
  /// `point(at:)` can find a row by binary search instead of scanning the whole
  /// document. Maintained incrementally across edits and rebuilt on a full parse.
  private var lineStarts: [Int] = [0]

  /// UTF-16 length of the text the index and styling currently describe, so
  /// `nsRange` can clamp node ranges that reach past the document (tree-sitter
  /// sometimes reports a block's range out to a trailing position).
  private var length = 0

  /// A full incremental reparse scheduled to run once typing pauses. Reset on
  /// every keystroke so it only fires when the user stops; cancelled whenever a
  /// whole-document parse supersedes it.
  private var pendingParse: Task<Void, Never>?

  /// How long the document must stay idle before the deferred full reparse runs.
  /// Long enough that a normal typing burst never triggers it, short enough that
  /// any paragraph the local parse mis-styled is corrected almost immediately.
  private let fullParseDelay: Duration = .milliseconds(600)

  /// The document range styled optimistically by a local paragraph parse since
  /// the last full parse. The deferred reparse re-styles it against the
  /// authoritative tree, so a paragraph the local parse couldn't classify (an
  /// edit inside a code fence) is corrected once typing pauses. A single span is
  /// enough: edits in one idle window cluster around the cursor, and over-
  /// covering only restyles a few extra paragraphs identically.
  private var dirtySpan: NSRange?

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

    // No baseline tree, or a whole-document replacement (e.g. setAttributedString):
    // a fresh parse is both simpler and what incremental would reduce to.
    let isWholeDoc = editedRange.location == 0 && editedRange.length == newLength
    guard let old = tree, !isWholeDoc else {
      fullRestyle(storage)
      return
    }

    let start = editedRange.location
    let newEnd = editedRange.location + editedRange.length
    let oldEnd = newEnd - delta

    // The start point is shared by both texts (the prefix is unchanged); the old
    // end point must be read against the pre-edit line index, so compute both
    // before advancing the index. The byte offsets are authoritative for
    // tree-sitter; the points keep its column-sensitive scanner honest.
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

    // Immediate, length-independent styling of just the edited paragraph.
    let edited = styleLocalParagraph(around: editedRange, in: storage)
    let t2 = debugTiming ? CFAbsoluteTimeGetCurrent() : 0

    // Remember what we styled optimistically (shifting any earlier span for this
    // edit first) so the deferred parse re-checks it against the real tree.
    dirtySpan = union(shift(dirtySpan, start: start, oldEnd: oldEnd, delta: delta), edited)
    scheduleFullParse(for: storage)

    if debugTiming {
      let ms = { (a: CFAbsoluteTime, b: CFAbsoluteTime) in String(format: "%.2f", (b - a) * 1000) }
      print(
        "applyEdit: lineIndex+points=\(ms(t0, t1))ms localParse+restyle=\(ms(t1, t2))ms "
          + "(paragraph \(edited.length) chars)")
    }
  }

  // MARK: Local parse (per keystroke)

  /// Parses the single paragraph containing `editedRange` in isolation and
  /// restyles it, returning the paragraph's range. Bounded by the paragraph's
  /// length, so it stays instant however long the document is. A standalone
  /// paragraph parses to its own block (paragraph, heading, …) with inline
  /// content, which is everything we need for the common edit. It cannot see a
  /// code fence opened in a *different* paragraph; that's what the deferred
  /// whole-document parse corrects.
  @discardableResult
  private func styleLocalParagraph(around editedRange: NSRange, in storage: NSTextStorage)
    -> NSRange
  {
    let source = storage.mutableString
    guard let para = paragraphs(covering: [editedRange], in: source).first, para.length > 0
    else { return editedRange }
    let substring = source.substring(with: para)
    guard let localTree = block.parse(substring), let root = localTree.rootNode
    else { return para }
    storage.setAttributes(TextStyle.body.attributes, range: para)
    // The local tree's byte offsets start at zero, so shift every styled range by
    // the paragraph's document location.
    styleBlock(root, in: storage, source: source, targets: [para], base: para.location)
    return para
  }

  // MARK: Deferred full parse (on idle)

  /// (Re)arms the debounced whole-document reparse. Each keystroke cancels the
  /// previous timer, so the costly parse only runs after the user pauses.
  private func scheduleFullParse(for storage: NSTextStorage) {
    pendingParse?.cancel()
    pendingParse = Task { [weak self] in
      try? await Task.sleep(for: self?.fullParseDelay ?? .milliseconds(600))
      guard !Task.isCancelled else { return }
      self?.runFullParse(storage)
    }
  }

  /// Performs the deferred incremental reparse: reparses the whole document
  /// (reusing untouched subtrees), then restyles the paragraphs whose syntax
  /// changed unioned with whatever the local parses styled optimistically. Runs
  /// outside an edit transaction, so it brackets its own begin/endEditing.
  private func runFullParse(_ storage: NSTextStorage) {
    pendingParse = nil
    guard let old = tree else { return }

    let t0 = debugTiming ? CFAbsoluteTimeGetCurrent() : 0
    guard let newTree = block.parse(tree: old, readBlock: readBlock(for: storage)),
      let root = newTree.rootNode
    else {
      tree = nil  // force a clean full parse next time
      return
    }
    // Safety net: an incremental reparse can collapse to an empty document over
    // non-empty text under release optimization, so detect that and parse afresh.
    // We're outside an edit transaction here, so bracket the fallback.
    if root.childCount == 0, storage.length > 0 {
      storage.beginEditing()
      fullRestyle(storage)
      storage.endEditing()
      return
    }

    // Ranges whose syntax changed. tree-sitter's contract is
    // changed(old_tree: edited, new_tree: reparsed); `old` is the edited tree, so
    // it is the receiver and `newTree` the argument.
    var targets = old.changedRanges(from: newTree).map { nsRange($0.bytes) }
    tree = newTree
    if let dirty = dirtySpan { targets.append(dirty) }
    dirtySpan = nil

    let source = storage.mutableString
    let expanded = paragraphs(covering: targets, in: source)
    storage.beginEditing()
    restyle(ranges: expanded, root: root, source: source, in: storage)
    storage.endEditing()

    if debugTiming {
      let t1 = CFAbsoluteTimeGetCurrent()
      let ms = { (a: CFAbsoluteTime, b: CFAbsoluteTime) in String(format: "%.2f", (b - a) * 1000) }
      print(
        "runFullParse: parse+changedRanges+restyle=\(ms(t0, t1))ms "
          + "(restyleRanges=\(expanded.count) "
          + "spanning \(expanded.reduce(0) { $0 + $1.length }) chars)")
    }
  }

  /// Runs the debounced reparse synchronously instead of waiting out the timer.
  /// The live editor relies on the debounce; tests use this to observe the
  /// settled styling deterministically. A no-op when nothing is scheduled.
  func flushPendingParse(_ storage: NSTextStorage) {
    guard pendingParse != nil else { return }
    pendingParse?.cancel()
    runFullParse(storage)
  }

  /// Shifts a recorded dirty span to account for an edit that replaced
  /// `start..<oldEnd` with `start..<(oldEnd + delta)`. An edit before the span
  /// slides it; an edit overlapping it grows it; an edit after leaves it. Over-
  /// covering is safe, so the overlap case just extends the span to span the edit.
  private func shift(_ range: NSRange?, start: Int, oldEnd: Int, delta: Int) -> NSRange? {
    guard let r = range else { return nil }
    let end = r.location + r.length
    if oldEnd <= r.location {
      return NSRange(location: r.location + delta, length: r.length)
    }
    if start >= end {
      return r
    }
    let lower = min(r.location, start)
    let upper = max(end + delta, oldEnd + delta)
    return NSRange(location: lower, length: max(0, upper - lower))
  }

  /// Smallest range covering both, or the non-nil one. Used to fold each edited
  /// paragraph into the running dirty span.
  private func union(_ a: NSRange?, _ b: NSRange) -> NSRange {
    guard let a = a else { return b }
    return NSUnionRange(a, b)
  }

  /// Parses `storage` from scratch and restyles the whole document. The shared
  /// fallback for the initial render, whole-document replacement, and a
  /// degenerate incremental parse.
  private func fullRestyle(_ storage: NSTextStorage) {
    pendingParse?.cancel()
    pendingParse = nil
    dirtySpan = nil
    guard let root = freshParse(storage) else { return }
    restyle(
      ranges: [NSRange(location: 0, length: storage.length)], root: root,
      source: storage.mutableString, in: storage)
  }

  /// Parses `storage` with no tree reuse, rebuilds the line index as the new
  /// baseline, and returns the root node. Returns nil only if the parser yields
  /// nothing.
  private func freshParse(_ storage: NSTextStorage) -> Node? {
    rebuildLineStarts(storage)
    guard let newTree = block.parse(tree: nil as Tree?, readBlock: readBlock(for: storage)),
      let root = newTree.rootNode
    else {
      tree = nil
      return nil
    }
    tree = newTree
    return root
  }

  /// Feeds tree-sitter the requested slice of the document as UTF-16LE bytes
  /// pulled straight from `storage.mutableString`, a live proxy, so we copy
  /// only the few-KB chunk tree-sitter asks for rather than snapshotting the
  /// whole document on every parse. `byteOffset` is a UTF-16 byte offset (two
  /// per code unit). SwiftTreeSitter copies each returned chunk into its own
  /// buffer, so the `Data` we hand back only needs to outlive the call.
  private func readBlock(for storage: NSTextStorage) -> Parser.ReadBlock {
    let string = storage.mutableString
    let unitCount = string.length
    let chunkUnits = 2048
    return { byteOffset, _ in
      let start = byteOffset / 2
      guard start >= 0, start < unitCount else { return nil }
      let count = min(chunkUnits, unitCount - start)
      var buffer = [unichar](repeating: 0, count: count)
      string.getCharacters(&buffer, range: NSRange(location: start, length: count))
      return buffer.withUnsafeBytes { Data($0) }
    }
  }

  // MARK: Line index

  /// Recomputes every line start by scanning the document once. Used only on a
  /// full parse, never per keystroke.
  private func rebuildLineStarts(_ storage: NSTextStorage) {
    let string = storage.mutableString
    let n = string.length
    var starts: [Int] = [0]
    if n > 0 {
      var buffer = [unichar](repeating: 0, count: n)
      string.getCharacters(&buffer, range: NSRange(location: 0, length: n))
      for i in 0..<n where buffer[i] == 0x0A { starts.append(i + 1) }
    }
    lineStarts = starts
    length = n
  }

  /// Splices the line index for an edit that replaced `start..<oldEnd` with the
  /// text now occupying `start..<newEnd`: keep the starts up to `start`, add one
  /// per newline in the inserted run, then shift the starts past the edit by
  /// `delta`. O(line count), versus rescanning the whole document.
  private func updateLineStarts(
    start: Int, oldEnd: Int, newEnd: Int, delta: Int, in storage: NSTextStorage
  ) {
    var result: [Int] = []
    result.reserveCapacity(lineStarts.count + 2)
    for line in lineStarts where line <= start { result.append(line) }
    if newEnd > start {
      let count = newEnd - start
      var buffer = [unichar](repeating: 0, count: count)
      storage.mutableString.getCharacters(&buffer, range: NSRange(location: start, length: count))
      for i in 0..<count where buffer[i] == 0x0A { result.append(start + i + 1) }
    }
    for line in lineStarts where line > oldEnd { result.append(line + delta) }
    lineStarts = result
  }

  /// Row and column, measured in UTF-16 bytes, of a UTF-16 offset. Found by
  /// binary search over the line index: the line-relative position tree-sitter
  /// wants alongside the byte offsets.
  private func point(at offset: Int) -> Point {
    let bounded = max(0, min(offset, length))
    var low = 0
    var high = lineStarts.count - 1
    var row = 0
    while low <= high {
      let mid = (low + high) / 2
      if lineStarts[mid] <= bounded {
        row = mid
        low = mid + 1
      } else {
        high = mid - 1
      }
    }
    return Point(row: row, column: (bounded - lineStarts[row]) * 2)
  }

  // MARK: Restyling

  /// Resets the given ranges to the body style, then re-applies the styling the
  /// parse tree implies for any block that intersects them. The tree walk prunes
  /// subtrees that fall entirely outside `ranges`, so an incremental edit only
  /// touches the paragraphs that changed.
  private func restyle(
    ranges: [NSRange], root: Node, source: NSString, in storage: NSTextStorage
  ) {
    for range in ranges where range.length > 0 {
      storage.setAttributes(TextStyle.body.attributes, range: range)
    }
    styleBlock(root, in: storage, source: source, targets: ranges)
  }

  // MARK: Block level

  /// `base` is the document offset (UTF-16 code units) of the parsed text's
  /// start: zero for the whole-document tree, the paragraph's location for a
  /// local parse whose byte offsets restart at zero. It is folded into every
  /// range conversion so styled ranges and `targets` are both in document
  /// coordinates.
  private func styleBlock(
    _ node: Node, in storage: NSTextStorage, source: NSString, targets: [NSRange], base: Int = 0
  ) {
    let range = nsRange(node.byteRange, base: base)
    guard intersects(range, targets) else { return }

    switch node.nodeType ?? "" {
    case "atx_heading", "setext_heading":
      apply(headingStyle(for: node), to: range, in: storage)
    case "fenced_code_block", "indented_code_block":
      applyCode(to: range, in: storage)
      return  // code is verbatim; don't descend for inline emphasis
    case "inline":
      styleInline(node, range: range, in: storage, source: source, base: base)
      return
    default:
      break
    }

    // recurse into children to find nested blocks and inlines
    for index in 0..<node.childCount {
      if let child = node.child(at: index) {
        styleBlock(child, in: storage, source: source, targets: targets, base: base)
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

  // MARK: Inline level

  private func styleInline(
    _ inlineNode: Node, range: NSRange, in storage: NSTextStorage, source: NSString, base: Int
  ) {
    let substring = source.substring(with: range)
    guard !substring.isEmpty else { return }
    guard let tree = inline.parse(substring), let root = tree.rootNode
    else { return }
    // `inlineByteBase` places the re-parsed inline content within the block
    // tree's byte space; `docBase` then shifts that to document coordinates.
    walkInline(root, inlineByteBase: inlineNode.byteRange.lowerBound, docBase: base, in: storage)
  }

  private func walkInline(
    _ node: Node, inlineByteBase: UInt32, docBase: Int, in storage: NSTextStorage
  ) {
    let absolute =
      (node.byteRange.lowerBound + inlineByteBase)..<(node.byteRange.upperBound + inlineByteBase)
    switch node.nodeType ?? "" {
    case "strong_emphasis":
      addTrait(.boldTrait, to: nsRange(absolute, base: docBase), in: storage)
    case "emphasis":
      addTrait(.italicTrait, to: nsRange(absolute, base: docBase), in: storage)
    case "code_span":
      applyCode(to: nsRange(absolute, base: docBase), in: storage)
    case "strikethrough":
      storage.addAttribute(
        .strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
        range: nsRange(absolute, base: docBase))
    default:
      break
    }
    for index in 0..<node.childCount {
      if let child = node.child(at: index) {
        walkInline(child, inlineByteBase: inlineByteBase, docBase: docBase, in: storage)
      }
    }
  }

  // MARK: Attribute application

  /// Sets a block style's font, paragraph, and color across `range`.
  private func apply(_ style: TextStyle, to range: NSRange, in storage: NSTextStorage) {
    storage.addAttributes(style.attributes, range: range)
  }

  /// Unions a symbolic trait onto whatever font each run already carries, so a
  /// heading stays heading-sized when its words are also `**bold**`.
  private func addTrait(_ trait: FontTraits, to range: NSRange, in storage: NSTextStorage) {
    storage.enumerateAttribute(.font, in: range) { value, runRange, _ in
      let current = value as? PlatformFont ?? TextStyle.body.font
      storage.addAttribute(
        .font, value: current.with(traits: current.traits.union(trait)), range: runRange)
    }
  }

  private func applyCode(to range: NSRange, in storage: NSTextStorage) {
    storage.enumerateAttribute(.font, in: range) { value, runRange, _ in
      let size = (value as? PlatformFont ?? TextStyle.body.font).pointSize
      storage.addAttribute(
        .font, value: PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular),
        range: runRange)
    }
  }

  // MARK: Range conversion

  /// Converts a tree-sitter UTF-16 byte range into an `NSRange` (UTF-16 code
  /// units). Each code unit is two bytes, so the bounds halve cleanly; `base`
  /// (a code-unit document offset) shifts a local parse's zero-based ranges into
  /// document coordinates; both are clamped to the current length so a node
  /// reaching past the document yields a valid (possibly empty) range rather than
  /// throwing when it's applied.
  private func nsRange(_ byteRange: Range<UInt32>, base: Int = 0) -> NSRange {
    let lower = min(Int(byteRange.lowerBound) / 2 + base, length)
    let upper = min(Int(byteRange.upperBound) / 2 + base, length)
    return NSRange(location: lower, length: upper - lower)
  }

  /// Expands each range to whole paragraphs, so block styling (headings, code
  /// fences, spacing) is recomputed against entire lines. Overlapping results
  /// are harmless: restyle just re-applies the same attributes.
  private func paragraphs(covering ranges: [NSRange], in ns: NSString) -> [NSRange] {
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
  func textStorage(
    _ textStorage: NSTextStorage,
    didProcessEditing editedMask: NSTextStorageEditActions,
    range editedRange: NSRange,
    changeInLength delta: Int
  ) {
    guard editedMask.contains(.editedCharacters) else { return }
    applyEdit(editedRange: editedRange, delta: delta, to: textStorage)
  }
}
