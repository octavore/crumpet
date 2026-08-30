import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Conceals markdown delimiters (`**`, `*`, `` ` ``) so the editor reads like
/// rendered text while the source keeps every character. Implemented as
/// `NSLayoutManagerDelegate` glyph substitution rather than by editing the
/// text storage: `MarkdownHighlighter` marks each delimiter character with
/// `.markdownMarker`, and `shouldGenerateGlyphs` below turns the marked ones
/// into `.null` glyphs — zero width, undrawn — unless the caret is near them.
/// The characters themselves never leave the text storage, so the Markdown
/// source and the `String` binding built from it are untouched; only what
/// gets drawn changes.
///
/// "Near" is recomputed from the live selection on every call rather than
/// cached, so a caret move needs only a glyph invalidation (no restyle) to
/// take effect, and switching `Typography.revealMode` at runtime needs only
/// the same.
extension TextViewEditor.Coordinator: @preconcurrency NSLayoutManagerDelegate {
  func layoutManager(
    _ layoutManager: NSLayoutManager,
    shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
    properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
    characterIndexes: UnsafePointer<Int>,
    font aFont: PlatformFont,
    forGlyphRange glyphRange: NSRange
  ) -> Int {
    guard let storage = layoutManager.textStorage, glyphRange.length > 0 else { return 0 }
    // The live proxy, not `storage.string`: this runs on every layout pass,
    // so snapshotting the whole document here would cost on a large file.
    let source = storage.mutableString
    let selection = textView?.editorSelectedRange ?? NSRange(location: NSNotFound, length: 0)
    let mode = Typography.revealMode
    // `.always` never conceals a marker, so there's nothing to decide per
    // glyph; bail before even looking for one.
    guard mode != .always else { return 0 }

    // Only allocated once a marker actually needs concealing, so the common
    // case (a glyph range with no markers in it) costs one attribute check
    // per character and nothing else.
    var newProps: [NSLayoutManager.GlyphProperty]?
    // The attribute run the last lookup landed in, so a run of characters
    // sharing one run (the overwhelmingly common case) costs a range check
    // rather than a lookup. Runs this delegate sees are walked in order.
    var cachedRun = NSRange(location: NSNotFound, length: 0)
    var cachedMarker: Any?
    for index in 0..<glyphRange.length {
      let charIndex = characterIndexes[index]
      if !NSLocationInRange(charIndex, cachedRun) {
        // `effectiveRange`, not `longestEffectiveRange` over the document:
        // the latter extends the nil run across every adjacent unmarked run,
        // so each unmarked character walks the whole file's attribute list and
        // laying out one screen costs what the document is worth. The shortest
        // run is a lookup, and it's all this needs: the span comes from the
        // value, and `lineRegion` resolves any subrange of a marker to the
        // same paragraph.
        cachedMarker = storage.attribute(
          .markdownMarker, at: charIndex, effectiveRange: &cachedRun)
      }
      guard let marker = cachedMarker else { continue }
      let markerRange = cachedRun

      // `.span` reveals when the caret touches the whole emphasis/code span
      // (stored on the marker), so touching either delimiter uncovers both;
      // `.line` reveals for the caret anywhere on the delimiter's own line.
      let span = (marker as? NSValue)?.rangeValue ?? markerRange
      let region = mode == .line ? lineRegion(for: markerRange, in: source) : span
      guard !touches(selection, region) else { continue }

      if newProps == nil {
        newProps = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
      }
      newProps?[index] = .null
    }

    guard let properties = newProps else { return 0 }
    layoutManager.setGlyphs(
      glyphs, properties: properties, characterIndexes: characterIndexes, font: aFont,
      forGlyphRange: glyphRange)
    return glyphRange.length
  }

  /// The marker's line in `.line` mode: the paragraph it sits in, but only its
  /// content, excluding the trailing newline. `NSString.paragraphRange` folds
  /// that terminator into the range, which would push the line's end to the
  /// exact start of the next line — and since `touches` treats both ends as
  /// closed, a caret resting at the start of the following line (e.g. after
  /// pressing Down onto an empty line, where the column clamps to zero) would
  /// read as touching this line and keep its markers revealed. Trimming the
  /// terminator keeps the closed-interval reveal at the line's real edges (a
  /// caret at column zero or at the last character) without leaking across the
  /// paragraph boundary.
  private func lineRegion(for range: NSRange, in source: NSString) -> NSRange {
    var start = 0
    var end = 0
    var contentsEnd = 0
    source.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: range)
    return NSRange(location: start, length: contentsEnd - start)
  }

  /// Whether `selection` overlaps or sits at the edge of `region`, treating
  /// both as closed intervals so a bare caret immediately before or after a
  /// marker still counts as touching it — the point at which you'd expect to
  /// be able to start typing `*` yourself and land inside the markup.
  private func touches(_ selection: NSRange, _ region: NSRange) -> Bool {
    guard selection.location != NSNotFound else { return false }
    let selectionEnd = selection.location + selection.length
    let regionEnd = region.location + region.length
    return selection.location <= regionEnd && selectionEnd >= region.location
  }

  /// Re-draws whatever concealment the caret moving from `oldSelection` to
  /// `newSelection` may have flipped. Scoped to the paragraph(s) spanning
  /// both positions: a marker only ever reveals within its own line (even in
  /// `.line` mode), so that's all that can have changed — keeping this off
  /// the document's length, like the rest of the highlighter's incremental
  /// work.
  ///
  /// Only needed for a selection change with no text edit (arrow keys, a
  /// click): an edit already goes through this same path via
  /// `NSTextStorage`'s normal edit-processing.
  ///
  /// Routed through `NSTextStorage.edited(_:range:changeInLength:)` rather
  /// than calling the layout manager's `invalidateGlyphs`/`invalidateLayout`
  /// directly: those looked right but left glyphs that had already been
  /// revealed on screen instead of re-concealing them, some invalidation
  /// timing this reverse-engineering didn't nail. `edited(_:range:...)` is
  /// the one path `NSTextStorage` itself uses to notify every attached
  /// layout manager of a change, and it's already proven correct here — it's
  /// exactly how a bold/italic/color edit invalidates today. Passing
  /// `.editedAttributes` alone (no `.editedCharacters`) reaches the layout
  /// manager without re-triggering `MarkdownHighlighter`, whose delegate
  /// methods bail out unless characters changed.
  func invalidateConcealment(from oldSelection: NSRange, to newSelection: NSRange) {
    guard let tv = textView, let storage = tv.optionalTextStorage, storage.length > 0 else {
      return
    }
    let source = storage.mutableString
    let combined = NSUnionRange(oldSelection, newSelection)
    let start = min(combined.location, source.length)
    let end = min(combined.location + combined.length, source.length)
    let startPara = source.paragraphRange(for: NSRange(location: start, length: 0))
    let endPara = source.paragraphRange(for: NSRange(location: end, length: 0))
    let range = NSUnionRange(startPara, endPara)
    guard range.length > 0 else { return }
    storage.beginEditing()
    storage.edited(.editedAttributes, range: range, changeInLength: 0)
    storage.endEditing()
    // The reflow above can move visual lines the layout manager didn't mark for
    // redraw; repaint the visible text so none are left drawn at their old spot.
    tv.refreshEditorDisplay()
  }
}
