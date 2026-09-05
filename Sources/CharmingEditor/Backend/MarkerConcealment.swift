import CoreText
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

    // Only allocated once something actually needs concealing, so the common
    // case (a glyph range with no markers in it) costs one attribute check
    // per run and nothing else.
    var newProps: [NSLayoutManager.GlyphProperty]?
    // Allocated only if a list bullet actually needs its glyph swapped.
    var newGlyphs: [CGGlyph]?
    // The bullet replacement glyph in `aFont`, resolved once per call, nil when
    // the style picks no glyph or the face lacks it. Resolved eagerly in
    // straight-line code: a nested closure capturing `aFont` here is
    // main-actor-isolated (from `Coordinator`) while `aFont` arrives through a
    // `@preconcurrency` requirement as task-isolated, which the release build's
    // whole-module pass rejects as a data race. One `CTFontGetGlyphsForCharacters`
    // per layout pass is cheap enough to not be worth the laziness.
    var bulletGlyph: CGGlyph?
    if let bulletScalar = Typography.listBulletStyle.markerScalar {
      bulletGlyph = aFont.glyph(for: bulletScalar)
    }
    // The attribute run the last lookup landed in, so a run of characters
    // sharing one run (the overwhelmingly common case) costs a range check
    // rather than a lookup. Runs this delegate sees are walked in order.
    var cachedRun = NSRange(location: NSNotFound, length: 0)
    var cachedAttributes: [NSAttributedString.Key: Any] = [:]
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
        cachedAttributes = storage.attributes(at: charIndex, effectiveRange: &cachedRun)
      }

      // An unordered list's bullet character renders as the glyph the current
      // `ListBulletStyle` picks, when it picks one and the face has it. The
      // source `-`/`*`/`+` is untouched; only the drawn glyph changes.
      if cachedAttributes[.listBulletMarker] != nil, let replacement = bulletGlyph {
        if newGlyphs == nil {
          newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        }
        newGlyphs?[index] = replacement
        continue
      }

      // A table's `|` separators and its `|---|` delimiter row render as
      // nothing at all, in every reveal mode. The grid `EditorLayoutManager`
      // strokes is their rendering, and giving a pipe its advance back would
      // pull the padded columns off the lines drawn around them.
      if cachedAttributes[.tableHidden] == nil {
        guard mode != .always, let marker = cachedAttributes[.markdownMarker] else { continue }
        // `.span` reveals when the caret touches the whole emphasis/code span
        // (stored on the marker), so touching either delimiter uncovers both;
        // `.line` reveals for the caret anywhere on the delimiter's own line.
        let span = (marker as? NSValue)?.rangeValue ?? cachedRun
        let region = mode == .line ? lineRegion(for: cachedRun, in: source) : span
        guard !touches(selection, region) else { continue }
      }

      if newProps == nil {
        newProps = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
      }
      newProps?[index] = .null
    }

    guard newProps != nil || newGlyphs != nil else { return 0 }
    let properties =
      newProps ?? Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
    let finalGlyphs =
      newGlyphs ?? Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
    finalGlyphs.withUnsafeBufferPointer { glyphBuffer in
      layoutManager.setGlyphs(
        glyphBuffer.baseAddress!, properties: properties, characterIndexes: characterIndexes,
        font: aFont, forGlyphRange: glyphRange)
    }
    return glyphRange.length
  }

  /// Takes the `|---|:--:|` row out of the visible layout without taking it out
  /// of the text. Its characters are already nulled at glyph generation, which
  /// leaves an empty line the height of a row; collapsing the fragment to a
  /// hairline closes that gap, so the header sits directly on the first body
  /// row the way a rendered table reads.
  ///
  /// The row is still there to click into, which is what `caretSkippingHiddenRow`
  /// is for.
  func layoutManager(
    _ layoutManager: NSLayoutManager,
    shouldSetLineFragmentRect rect: UnsafeMutablePointer<CGRect>,
    lineFragmentUsedRect usedRect: UnsafeMutablePointer<CGRect>,
    baselineOffset: UnsafeMutablePointer<CGFloat>,
    in textContainer: NSTextContainer,
    forGlyphRange glyphRange: NSRange
  ) -> Bool {
    guard let storage = layoutManager.textStorage, storage.length > 0 else { return false }
    let charIndex = min(
      layoutManager.characterIndexForGlyph(at: glyphRange.location), storage.length - 1)

    // A list item whose marker renders as an enlarged glyph: the big font on
    // the marker character drives the line height up. Pin the fragment back to
    // the body's metrics so list items sit the same height as, and align with,
    // the paragraphs around them. The marker glyph is centered on the text's
    // x-height in `MarkdownHighlighter`, so it stays inside these bounds.
    if Typography.listBulletStyle.markerScale != 1 {
      let lineCharRange = layoutManager.characterRange(
        forGlyphRange: glyphRange, actualGlyphRange: nil)
      var isBulletLine = false
      storage.enumerateAttribute(.listBulletMarker, in: lineCharRange) { value, _, stop in
        if value != nil {
          isBulletLine = true
          stop.pointee = true
        }
      }
      if isBulletLine {
        let bodyFont = TextStyle.body.font
        let natural = bodyFont.naturalLineHeight
        let height = (natural * Typography.lineHeightMultiple).rounded()
        rect.pointee.size.height = height
        usedRect.pointee.size.height = height
        baselineOffset.pointee = (bodyFont.ascender + (height - natural)).rounded()
        return true
      }
    }

    guard
      let row = storage.attribute(.tableRow, at: charIndex, effectiveRange: nil) as? TableRowStyle,
      row.isDelimiter
    else { return false }

    // Not zero: a zero-height fragment gives the layout manager nothing to
    // position the row's (invisible) caret against.
    let height: CGFloat = 1
    rect.pointee.size.height = height
    usedRect.pointee.size.height = height
    baselineOffset.pointee = height
    return true
  }

  /// Where the caret should go when a move lands it on a table's hidden
  /// delimiter row: through it, in the direction it was already travelling.
  /// The row occupies a hairline on screen, so leaving the caret there would
  /// mean an arrow press that appears to do nothing and a row of text that
  /// can't be seen while it's being typed into.
  ///
  /// Returns nil when the caret isn't on such a row, or when the move is a
  /// selection rather than a caret (dragging across a table should select the
  /// delimiter row's characters like any others, since they're still text).
  func caretSkippingHiddenRow(from old: NSRange, to new: NSRange) -> NSRange? {
    guard new.length == 0, let storage = textView?.optionalTextStorage, storage.length > 0
    else { return nil }
    let index = min(new.location, storage.length - 1)
    guard
      let row = storage.attribute(.tableRow, at: index, effectiveRange: nil) as? TableRowStyle,
      row.isDelimiter
    else { return nil }

    let source = storage.mutableString
    let paragraph = source.paragraphRange(for: NSRange(location: index, length: 0))
    let forwards = old.location <= new.location
    let target = forwards ? paragraph.location + paragraph.length : paragraph.location - 1
    guard target >= 0, target <= storage.length else { return nil }
    return NSRange(location: target, length: 0)
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
