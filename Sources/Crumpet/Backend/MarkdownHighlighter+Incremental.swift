import Foundation
import SwiftTreeSitter

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// The per-keystroke local parse, the deferred whole-document reparse, and the
/// line index.
extension MarkdownHighlighter {
  // MARK: Local parse (per keystroke)

  /// Restyles the edited paragraph's inline markup and returns the
  /// paragraph's range. The paragraph is reset to its `.blockBase`, since a
  /// lone paragraph lacks the context to decide its block type.
  @discardableResult
  func styleEditedParagraph(
    around editedRange: NSRange, inCode: Bool, in storage: NSTextStorage
  ) -> NSRange {
    let source = storage.mutableString
    guard let para = paragraphs(covering: [editedRange], in: source).first, para.length > 0
    else { return editedRange }

    // Read before the reset below clears it.
    let row =
      storage.attribute(.tableRow, at: para.location, effectiveRange: nil) as? TableRowStyle

    // Clears stale inline styling and restyles newly typed characters, which
    // arrive with the text view's typing attributes.
    let base = blockBase(of: para, in: storage)
    storage.setAttributes(base, range: para)
    storage.addAttribute(.blockBase, value: base, range: para)

    // Covers a line typed into an existing code block, which has no base yet.
    if inCode {
      applyCode(to: para, in: storage)
      return para
    }

    // Leading indentation is left out of the parse. Parsed alone, a line
    // indented four or more spaces reads as an indented code block. `inCode`
    // already ruled that out from the whole-document tree.
    var contentStart = para.location
    let paraEnd = para.location + para.length
    while contentStart < paraEnd, isIndentation(source.character(at: contentStart)) {
      contentStart += 1
    }
    let content = NSRange(location: contentStart, length: paraEnd - contentStart)
    guard content.length > 0, let localTree = block.parse(source.substring(with: content)),
      let root = localTree.rootNode
    else { return para }
    styleBlock(
      root, in: storage, source: source, targets: [para], base: content.location, phase: .inline)
    // The local tree misses an empty item below another item's text, such as
    // the one Return opens under a nested item.
    tagEmptyBullets(in: [para], root: nil, source: source, storage: storage)
    if let row { restoreTableRow(para, style: row, in: storage, source: source) }
    return para
  }

  /// Re-applies a table row's padding and hidden pipes after the reset. The
  /// column widths come from the `TableRowStyle` read before the reset; only a
  /// full parse re-measures them. A new column stays unpadded until then.
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

  /// The paragraph's `.blockBase`, or the body style for a line the last full
  /// parse never saw.
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

  /// Restarts the debounce timer for the whole-document reparse.
  func scheduleFullParse(for storage: NSTextStorage) {
    pendingParse?.cancel()
    pendingParse = Task { [weak self] in
      try? await Task.sleep(for: self?.fullParseDelay ?? .milliseconds(600))
      guard !Task.isCancelled else { return }
      self?.runFullParse(storage)
    }
  }

  /// Reparses the whole document incrementally and restyles the changed
  /// ranges plus `dirtySpan`. `bracketing` is false when called inside the
  /// storage's edit processing, where `beginEditing` is not allowed.
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
    // An incremental reparse can collapse to an empty document under release
    // optimization. Parse from scratch when that happens.
    if root.childCount == 0, storage.length > 0 {
      if bracketing { storage.beginEditing() }
      fullRestyle(storage)
      if bracketing { storage.endEditing() }
      return
    }

    // `old` has been edited, so it is the receiver and `newTree` the argument.
    var targets = old.changedRanges(from: newTree).map { nsRange($0.bytes) }
    tree = newTree
    if let dirty = dirtySpan { targets.append(dirty) }
    dirtySpan = nil

    // Expanding against the old tree too resets styling from a block that
    // has since split.
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

  /// Runs a scheduled reparse now. Used by tests.
  func flushPendingParse(_ storage: NSTextStorage) {
    guard pendingParse != nil else { return }
    pendingParse?.cancel()
    runFullParse(storage)
  }

  /// Moves or grows a dirty span for an edit that replaced `start..<oldEnd`
  /// with `delta` more characters.
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

  func union(_ a: NSRange?, _ b: NSRange) -> NSRange {
    guard let a = a else { return b }
    return NSUnionRange(a, b)
  }

  /// Parses from scratch and restyles the whole document. Runs inside edit
  /// processing.
  func fullRestyle(_ storage: NSTextStorage) {
    pendingParse?.cancel()
    pendingParse = nil
    dirtySpan = nil
    guard let root = freshParse(storage) else { return }
    restyle(
      ranges: [NSRange(location: 0, length: storage.length)], root: root,
      source: storage.mutableString, in: storage)
  }

  /// Parses with no tree reuse and rebuilds the line index.
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

  /// Feeds tree-sitter the document in chunks of up to 2048 UTF-16 code
  /// units, read from `storage.mutableString` without copying the whole text.
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

  /// Updates the line index for an edit that replaced `start..<oldEnd` with
  /// the text now at `start..<newEnd`.
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

  /// The tree-sitter row and byte column of a UTF-16 offset.
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
