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
  var length = 0

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
  /// edit inside a code fence) is corrected once typing pauses. A single span
  /// is enough: edits in one idle window cluster around the cursor, and
  /// over-covering only restyles a few extra paragraphs identically.
  private var dirtySpan: NSRange?

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
    let inCode = enclosedByCodeBlock(old, at: start)

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

  // MARK: Local parse (per keystroke)

  /// Restyles the edited paragraph's inline markup and nothing else, returning
  /// the paragraph's range. Bounded by the paragraph's length, so it stays
  /// instant however long the document is.
  ///
  /// The paragraph's block-level attributes (heading size, code font, list
  /// indent) are not re-derived here. Deciding a block's kind takes context
  /// this parse doesn't have (a `# foo` line is a heading unless a fence three
  /// paragraphs up made it code; a setext underline is invisible from the
  /// line it underlines), so guessing from a lone paragraph is exactly what
  /// used to flash text into the wrong style mid-keystroke. Instead the
  /// paragraph is reset to the block style the last whole-document parse gave
  /// it, stamped on the text as ``NSAttributedString/Key/blockBase``, and only
  /// a whole-document parse, which does have the context, ever changes it.
  /// When the keystroke looks like it reshaped a block, `applyEdit` runs that
  /// parse immediately rather than waiting out the debounce, so a marker still
  /// takes effect as you type it.
  @discardableResult
  private func styleEditedParagraph(
    around editedRange: NSRange, inCode: Bool, in storage: NSTextStorage
  ) -> NSRange {
    let source = storage.mutableString
    guard let para = paragraphs(covering: [editedRange], in: source).first, para.length > 0
    else { return editedRange }

    // Read before the reset below wipes it: the row's measured geometry, which
    // is re-applied afterwards rather than re-derived. See `restoreTableRow`.
    let row =
      storage.attribute(.tableRow, at: para.location, effectiveRange: nil) as? TableRowStyle

    // Resetting to the block base does double duty: it clears inline
    // decorations that the edit invalidated (the `*` you just deleted), and it
    // gives the characters just typed, which arrive carrying the text view's
    // typing attributes, the block's look rather than a stray body font.
    let base = blockBase(of: para, in: storage)
    storage.setAttributes(base, range: para)
    storage.addAttribute(.blockBase, value: base, range: para)

    // Code is verbatim: no inline markup to find, and no parse worth doing. The
    // explicit restyle covers a line typed *into* an existing block, which is new
    // text the last full parse never stamped.
    if inCode {
      applyCode(to: para, in: storage)
      return para
    }

    // The block parse is still what locates inline content (it knows `# ` is a
    // marker, not text), but only its `inline` nodes are acted on.
    guard let localTree = block.parse(source.substring(with: para)),
      let root = localTree.rootNode
    else { return para }
    // The local tree's byte offsets start at zero, so shift every styled range by
    // the paragraph's document location.
    styleBlock(
      root, in: storage, source: source, targets: [para], base: para.location, phase: .inline)
    if let row { restoreTableRow(para, style: row, in: storage, source: source) }
    return para
  }

  /// Re-pads a table row the reset above just flattened.
  ///
  /// A row's cell padding and hidden pipes are per-character work, so they are
  /// not part of the block base and don't come back with it. Left at that, every
  /// keystroke in a table would collapse the row's columns and pop its pipes
  /// back into view until the debounced parse landed, which is the whole of
  /// typing.
  ///
  /// The column widths don't need re-measuring for that, only re-applying: they
  /// belong to the table, not the keystroke, and only a full parse is allowed
  /// to change them. They ride on the text as the ``TableRowStyle`` read off the
  /// row just before the reset, so they follow the document without a cache
  /// anyone has to keep in step with it. The row's own cell widths *are*
  /// re-measured, since its contents are what just changed.
  ///
  /// A keystroke that adds a column leaves the new cell unpadded (there's no
  /// width for it yet) until the deferred parse measures the table again.
  private func restoreTableRow(
    _ para: NSRange, style: TableRowStyle, in storage: NSTextStorage, source: NSString
  ) {
    guard para.length > 0 else { return }
    let content = source.paragraphRange(for: para)
    let contentEnd = min(content.location + content.length, source.length)
    var end = contentEnd
    while end > content.location, isNewline(source.character(at: end - 1)) { end -= 1 }
    let line = NSRange(location: content.location, length: end - content.location)
    guard line.length > 0 else { return }

    if style.isDelimiter {
      applyDelimiterRow(line, columns: style.columns, in: storage)
      return
    }
    let split = Self.columnSpans(in: line, source: source)
    applyRowLayout(
      paragraph: line, spans: split.spans, pipes: split.pipes, widths: nil,
      columns: style.columns, isHeader: style.isHeader, in: storage)
  }

  private func isNewline(_ character: unichar) -> Bool {
    character == 0x0A || character == 0x0D
  }

  /// The block attributes the last whole-document parse stamped on this paragraph.
  /// Falls back to the body style for a paragraph that parse never saw (a
  /// line typed since), which is also what a brand-new line should look like
  /// until the deferred parse classifies it.
  private func blockBase(of para: NSRange, in storage: NSTextStorage)
    -> [NSAttributedString.Key: Any]
  {
    var found: [NSAttributedString.Key: Any]?
    storage.enumerateAttribute(.blockBase, in: para) { value, _, stop in
      if let base = value as? [NSAttributedString.Key: Any] {
        found = base
        stop.pointee = true
      }
    }
    return found ?? TextStyle.body.attributes
  }

  /// Whether `offset` sits inside a code block according to `tree`, which must
  /// not have been `edit`ed for the current keystroke yet: its byte space has
  /// to still describe the text `offset` was measured in. Cheap: one
  /// descendant lookup and a walk up the parent chain, no parsing.
  private func enclosedByCodeBlock(_ tree: MutableTree, at offset: Int) -> Bool {
    guard let root = tree.rootNode else { return false }
    let byte = UInt32(max(0, min(offset, length)) * 2)
    var node = root.descendant(in: byte..<byte)
    while let current = node {
      switch current.nodeType ?? "" {
      case "fenced_code_block", "indented_code_block": return true
      default: node = current.parent
      }
    }
    return false
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

  /// Performs the incremental reparse: reparses the whole document (reusing
  /// untouched subtrees), then restyles the paragraphs whose syntax changed unioned
  /// with whatever the keystroke path touched. Normally deferred to an idle moment,
  /// but also run straight from a keystroke that reshaped a block.
  ///
  /// `bracketing` is false when the caller is already inside the storage's
  /// edit processing, where `beginEditing` is not allowed and attributes are
  /// mutated directly, the same rule `applyEdit` follows.
  private func runFullParse(_ storage: NSTextStorage, bracketing: Bool = true) {
    pendingParse?.cancel()
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
    if root.childCount == 0, storage.length > 0 {
      if bracketing { storage.beginEditing() }
      fullRestyle(storage)
      if bracketing { storage.endEditing() }
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
    let expanded = paragraphs(covering: blocks(covering: targets, root: root), in: source)
    if bracketing { storage.beginEditing() }
    restyle(ranges: expanded, root: root, source: source, in: storage)
    if bracketing { storage.endEditing() }

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
  /// slides it; an edit overlapping it grows it; an edit after leaves it.
  /// Over-covering is safe, so the overlap case just extends the span to
  /// cover the edit.
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

  /// Which layer of styling a tree walk applies. The two are separate passes
  /// so a paragraph's block style can be recorded (`stampBlockBase`) after the
  /// blocks land but before inline markup is layered on top, and so the
  /// keystroke path can run the inline pass alone, leaving block styling to
  /// the authoritative parse that has the context to decide it.
  private enum Phase {
    case block
    case inline
  }

  /// Resets the given ranges to the body style, re-applies the block styling the
  /// parse tree implies, records it as each paragraph's block base, then layers the
  /// inline markup over it. The tree walk prunes subtrees that fall entirely outside
  /// `ranges`, so an incremental edit only touches the paragraphs that changed.
  private func restyle(
    ranges: [NSRange], root: Node, source: NSString, in storage: NSTextStorage
  ) {
    for range in ranges where range.length > 0 {
      storage.setAttributes(TextStyle.body.attributes, range: range)
    }
    styleBlock(root, in: storage, source: source, targets: ranges, phase: .block)
    stampBlockBase(ranges: ranges, source: source, in: storage)
    styleBlock(root, in: storage, source: source, targets: ranges, phase: .inline)
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
    for range in ranges where range.length > 0 {
      var location = range.location
      let end = min(range.location + range.length, source.length)
      while location < end {
        let para = source.paragraphRange(for: NSRange(location: location, length: 0))
        guard para.length > 0 else { break }
        // Drop any base already stamped there, so a paragraph reached twice records
        // its attributes rather than a base nested inside a base.
        let base = storage.attributes(at: para.location, effectiveRange: nil)
          .filter { !Self.perCharacterKeys.contains($0.key) }
        storage.addAttribute(.blockBase, value: base, range: para)
        location = para.location + para.length
      }
    }
  }

  /// Attributes a paragraph's block base must never carry: the base itself
  /// (which would nest), and everything that describes one character rather
  /// than the block around it.
  private static let perCharacterKeys: Set<NSAttributedString.Key> = [
    .blockBase, .markdownMarker, .tableHidden, .kern, .listBulletMarker, .baselineOffset,
  ]

  // MARK: Block level

  /// `base` is the document offset (UTF-16 code units) of the parsed text's
  /// start: zero for the whole-document tree, the paragraph's location for a
  /// local parse whose byte offsets restart at zero. It is folded into every
  /// range conversion so styled ranges and `targets` are both in document
  /// coordinates.
  private func styleBlock(
    _ node: Node, in storage: NSTextStorage, source: NSString, targets: [NSRange], base: Int = 0,
    phase: Phase
  ) {
    let range = nsRange(node.byteRange, base: base)
    guard intersects(range, targets) else { return }

    switch node.nodeType ?? "" {
    case "atx_heading", "setext_heading":
      if phase == .block { apply(headingStyle(for: node), to: range, in: storage) }
      // The marker tag is per-character work, so it runs in the inline pass:
      // the block base excludes it, and the keystroke path re-applies only the
      // inline pass. See `stampBlockBase`.
      if phase == .inline, node.nodeType == "atx_heading" {
        tagHeadingMarker(node, range: range, in: storage, source: source, base: base)
      }
    case "fenced_code_block", "indented_code_block":
      if phase == .block { applyCode(to: range, in: storage) }
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
    storage.addAttribute(.markdownMarker, value: NSValue(range: span), range: markerRange)
  }

  // MARK: List level

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
  private func applyListIndent(
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
  private func tagUnorderedBullet(
    _ node: Node, in storage: NSTextStorage, source: NSString, base: Int
  ) {
    if let bulletRange = unorderedBulletMarker(node, in: source, base: base) {
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
        let offset = TextStyle.body.font.xHeight / 2 - glyphMid
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
      let range = nsRange(absolute, base: docBase)
      addTrait(.boldTrait, to: range, in: storage)
      addColor(Typography.colorScheme.bold, to: range, in: storage)
    case "emphasis":
      let range = nsRange(absolute, base: docBase)
      addTrait(.italicTrait, to: range, in: storage)
      addColor(Typography.colorScheme.italic, to: range, in: storage)
    case "code_span":
      applyCode(to: nsRange(absolute, base: docBase), in: storage)
    case "strikethrough":
      storage.addAttribute(
        .strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
        range: nsRange(absolute, base: docBase))
    case "emphasis_delimiter", "code_span_delimiter":
      // The `**`/`*`/`` ` `` characters themselves: a rendering hint for the
      // layout manager to conceal, not a style. See ``MarkerConcealment``.
      // The value carries the whole span (its parent node: the emphasis or code
      // span, opening delimiter through closing) so `.span` reveal mode can
      // uncover both delimiters together when the caret touches either — a lone
      // delimiter's own range would reveal just that one end.
      let span =
        node.parent.map { parent in
          let lower = parent.byteRange.lowerBound + inlineByteBase
          let upper = parent.byteRange.upperBound + inlineByteBase
          return nsRange(lower..<upper, base: docBase)
        } ?? nsRange(absolute, base: docBase)
      storage.addAttribute(
        .markdownMarker, value: NSValue(range: span), range: nsRange(absolute, base: docBase))
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

  private func applyCode(to range: NSRange, in storage: NSTextStorage) {
    // Code always renders at `Typography.codeRatio` × the base size, not
    // whatever size the surrounding construct (a heading, a title) happens
    // to be — that's what makes the ratio a real "code font size" knob
    // rather than just a monospacing of the context it's found in.
    let size = (Typography.baseSize * Typography.codeRatio).rounded()
    storage.addAttribute(
      .font, value: PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular),
      range: range)
    addColor(Typography.colorScheme.code, to: range, in: storage)
  }

  /// Sets a construct's foreground color without disturbing its font, so
  /// layering (e.g. a bold word inside a heading) only overrides color.
  private func addColor(_ color: Color, to range: NSRange, in storage: NSTextStorage) {
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
  private func blocks(covering ranges: [NSRange], root: Node) -> [NSRange] {
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
    let byte = UInt32(max(0, min(offset, length)) * 2)
    var node = root.descendant(in: byte..<byte)
    while let current = node {
      if Self.styledBlocks.contains(current.nodeType ?? "") { return nsRange(current.byteRange) }
      node = current.parent
    }
    return nil
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

extension NSAttributedString.Key {
  /// The block-level attributes (font, paragraph style, color) the last
  /// whole-document parse gave the paragraph this character belongs to,
  /// stamped on the text alongside them. It lets the per-keystroke path strip
  /// and re-derive a paragraph's inline markup without having to re-decide
  /// what kind of block the paragraph is, the one judgement a
  /// single-paragraph parse cannot make correctly, because the answer can
  /// live several paragraphs away.
  ///
  /// Internal to the editor: it travels with the text in the storage, but nothing
  /// outside the highlighter reads it, and pasted text is normalized by
  /// `TextStyle.sanitize` before it ever arrives.
  static let blockBase = NSAttributedString.Key("CharmingEditorBlockBase")

  /// Marks a markdown delimiter character (the `**`, `*`, or `` ` `` around
  /// bold, italic, and inline code) so the layout manager can conceal it when
  /// the caret isn't nearby. The value is an `NSValue`-wrapped `NSRange` of the
  /// whole span the delimiter belongs to (opening delimiter through closing),
  /// so `.span` reveal mode can uncover both delimiters together. Purely a
  /// rendering hint: the character stays in the text storage, so the Markdown
  /// source and the `String` binding built from it are untouched. See
  /// ``MarkerConcealment``.
  static let markdownMarker = NSAttributedString.Key("CharmingEditorMarkdownMarker")

  /// Marks the bullet character (`-`, `*`, `+`) of an unordered list item so the
  /// layout manager can substitute the glyph ``ListBulletStyle`` selects. The
  /// value is an ignored `true`. Purely a rendering hint: the source character
  /// is untouched, like ``markdownMarker``. See ``MarkerConcealment``.
  static let listBulletMarker = NSAttributedString.Key("CharmingEditorListBulletMarker")
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
