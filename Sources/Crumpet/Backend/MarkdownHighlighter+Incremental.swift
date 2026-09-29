import Foundation
import SwiftTreeSitter

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// The per-keystroke local parse, the deferred whole-document reparse, and the
/// line index that feeds tree-sitter its edit points.
extension MarkdownHighlighter {
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
  func styleEditedParagraph(
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
    //
    // The line's leading indentation is left out of the parse. Parsed alone,
    // a nested item indented four or more spaces (`    - item`) reads as an
    // indented code block, which would drop its bullet tag and inline styling.
    // Whether the line is code was already decided from the whole-document
    // tree (`inCode`), so the indentation carries no information here.
    var contentStart = para.location
    let paraEnd = para.location + para.length
    while contentStart < paraEnd, isIndentation(source.character(at: contentStart)) {
      contentStart += 1
    }
    let content = NSRange(location: contentStart, length: paraEnd - contentStart)
    guard content.length > 0, let localTree = block.parse(source.substring(with: content)),
      let root = localTree.rootNode
    else { return para }
    // The local tree's byte offsets start at zero, so shift every styled range by
    // the parsed text's document location.
    styleBlock(
      root, in: storage, source: source, targets: [para], base: content.location, phase: .inline)
    // The local tree also misses an empty item below another item's text, such
    // as the one Return opens under a nested item. Code was ruled out above.
    tagEmptyBullets(in: [para], root: nil, source: source, storage: storage)
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

  // MARK: Deferred full parse (on idle)

  /// (Re)arms the debounced whole-document reparse. Each keystroke cancels the
  /// previous timer, so the costly parse only runs after the user pauses.
  func scheduleFullParse(for storage: NSTextStorage) {
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
  func runFullParse(_ storage: NSTextStorage, bracketing: Bool = true) {
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

    // Expand against the old tree too, so styling from a block that has since
    // split is reset. `old` is edited, so its offsets match the current text.
    if let oldRoot = old.rootNode {
      targets = blocks(covering: targets, root: oldRoot)
    }
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
  func shift(_ range: NSRange?, start: Int, oldEnd: Int, delta: Int) -> NSRange? {
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
  func union(_ a: NSRange?, _ b: NSRange) -> NSRange {
    guard let a = a else { return b }
    return NSUnionRange(a, b)
  }

  /// Parses `storage` from scratch and restyles the whole document. The shared
  /// fallback for the initial render, whole-document replacement, and a
  /// degenerate incremental parse.
  func fullRestyle(_ storage: NSTextStorage) {
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
  func freshParse(_ storage: NSTextStorage) -> Node? {
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
  func updateLineStarts(
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
  func point(at offset: Int) -> Point {
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
}
