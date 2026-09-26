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
    var cachedMarkerRun = NSRange(location: NSNotFound, length: 0)
    let images = (layoutManager as? EditorLayoutManager)?.images
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

      // A block image's alt text stays visible as the chip's label until its
      // picture loads.
      if let source = cachedAttributes[.imageCaption] as? String,
        images?.image(for: source) == nil
      {
        continue
      }

      // A table's `|` separators and its `|---|` delimiter row render as
      // nothing at all, in every reveal mode. The grid `EditorLayoutManager`
      // strokes is their rendering, and giving a pipe its advance back would
      // pull the padded columns off the lines drawn around them.
      if cachedAttributes[.tableHidden] == nil {
        guard mode != .always, let marker = cachedAttributes[.markdownMarker] else { continue }
        // `.span` reveals when the caret touches the whole emphasis/code span
        // (stored on the marker, relative to it), so touching either delimiter
        // uncovers both;
        // `.line` reveals for the caret anywhere on the delimiter's own line.
        let region: NSRange
        if mode == .line {
          region = lineRegion(for: cachedRun, in: source)
        } else if let value = marker as? NSValue {
          if !NSLocationInRange(charIndex, cachedMarkerRun) {
            // The whole marker run, which the stored span is relative to. The
            // attribute run above can be a fragment of it when other attributes
            // change partway through the marker. Bounded to the marker's line.
            storage.attribute(
              .markdownMarker, at: charIndex, longestEffectiveRange: &cachedMarkerRun,
              in: lineRegion(for: cachedRun, in: source))
          }
          region = MarkerSpan.span(from: value, markerStart: cachedMarkerRun.location)
        } else {
          region = cachedRun
        }
        guard !touches(selection, region) else { continue }
      }

      if newProps == nil {
        newProps = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
      }
      // A concealed image's `!` becomes a control glyph. The two delegate
      // methods below give it the width of the chip's icon, and
      // `EditorLayoutManager` draws the icon into that space.
      let isChipIcon =
        cachedAttributes[.imageChipIcon] != nil || cachedAttributes[.linkChipIcon] != nil
      newProps?[index] = isChipIcon ? .controlCharacter : .null
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

  /// Lays out a concealed image's `!` as whitespace, so it takes the width
  /// `boundingBoxForControlGlyphAt` gives it without drawing a glyph. Every
  /// other control character keeps its default action.
  func layoutManager(
    _ layoutManager: NSLayoutManager,
    shouldUse action: NSLayoutManager.ControlCharacterAction,
    forControlCharacterAt charIndex: Int
  ) -> NSLayoutManager.ControlCharacterAction {
    guard let storage = layoutManager.textStorage, charIndex < storage.length,
      storage.attribute(.imageChipIcon, at: charIndex, effectiveRange: nil) != nil
        || storage.attribute(.linkChipIcon, at: charIndex, effectiveRange: nil) != nil
    else { return action }
    return .whitespace
  }

  /// The space a concealed image's `!` reserves: the picture for a block image
  /// whose picture has loaded, otherwise the chip's icon.
  func layoutManager(
    _ layoutManager: NSLayoutManager,
    boundingBoxForControlGlyphAt glyphIndex: Int,
    for textContainer: NSTextContainer,
    proposedLineFragment proposedRect: CGRect,
    glyphPosition: CGPoint,
    characterIndex charIndex: Int
  ) -> CGRect {
    if let size = blockImageSize(at: charIndex, in: layoutManager, container: textContainer) {
      return CGRect(
        x: glyphPosition.x, y: glyphPosition.y - size.height, width: size.width,
        height: size.height)
    }
    let font =
      layoutManager.textStorage?.attribute(.font, at: charIndex, effectiveRange: nil)
      as? PlatformFont ?? TextStyle.body.font
    return CGRect(
      x: glyphPosition.x, y: glyphPosition.y - font.capHeight,
      width: ImageChip.iconAdvance(for: font), height: font.capHeight)
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

    // A block image displaying its picture: the line is the picture's height
    // plus padding, with the baseline at the picture's bottom edge. The `!`
    // is the line's first glyph, since the image is alone on its line.
    if layoutManager.propertyForGlyph(at: glyphRange.location).contains(.controlCharacter),
      let size = blockImageSize(at: charIndex, in: layoutManager, container: textContainer)
    {
      let height = size.height + 2 * ImageStore.verticalPadding
      rect.pointee.size.height = height
      usedRect.pointee.size.height = height
      baselineOffset.pointee = height - ImageStore.verticalPadding
      return true
    }

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
        baselineOffset.pointee = (bodyFont.ascender + (height - natural) / 2).rounded()
        return true
      }
    }

    guard
      let row = storage.attribute(.tableRow, at: charIndex, effectiveRange: nil) as? TableRowStyle,
      row.isDelimiter
    else {
      return centerTextInLine(
        rect: rect.pointee, baselineOffset: baselineOffset, in: storage, at: charIndex)
    }

    // Not zero: a zero-height fragment gives the layout manager nothing to
    // position the row's (invisible) caret against.
    let height: CGFloat = 1
    rect.pointee.size.height = height
    usedRect.pointee.size.height = height
    baselineOffset.pointee = height
    return true
  }

  /// The size the block image whose `!` is at `charIndex` lays out at. Nil
  /// when the character is not a block image's `!` or its picture has not
  /// loaded, in which case the image lays out as a chip.
  private func blockImageSize(
    at charIndex: Int, in layoutManager: NSLayoutManager, container: NSTextContainer
  ) -> CGSize? {
    guard let layoutManager = layoutManager as? EditorLayoutManager,
      let storage = layoutManager.textStorage, charIndex < storage.length,
      let source = storage.attribute(.imageBlock, at: charIndex, effectiveRange: nil) as? String,
      let image = layoutManager.images.image(for: source)
    else { return nil }
    let size = ImageStore.displaySize(
      of: image, maxWidth: container.size.width - 2 * container.lineFragmentPadding)
    return size.height > 0 ? size : nil
  }

  /// Called when a block image's picture finishes loading. Invalidates the
  /// line of every image with that source, so the line grows to fit and the
  /// alt text conceals.
  func imageDidLoad(_ source: String) {
    guard let tv = textView, let storage = tv.optionalTextStorage, storage.length > 0 else {
      return
    }
    var ranges: [NSRange] = []
    storage.enumerateAttribute(.imageBlock, in: NSRange(location: 0, length: storage.length)) {
      value, range, _ in
      if value as? String == source {
        ranges.append(storage.mutableString.paragraphRange(for: range))
      }
    }
    guard !ranges.isEmpty else { return }
    storage.beginEditing()
    for range in ranges {
      storage.edited(.editedAttributes, range: range, changeInLength: 0)
    }
    storage.endEditing()
    tv.refreshEditorDisplay()
  }

  /// Moves the text down to the middle of its line. `lineHeightMultiple`
  /// makes the line taller by adding all the extra height above the text. The
  /// caret spans the whole line, so it reached well above the text. With the
  /// extra height split above and below the text, the caret extends evenly
  /// past both.
  private func centerTextInLine(
    rect: CGRect, baselineOffset: UnsafeMutablePointer<CGFloat>,
    in storage: NSTextStorage, at charIndex: Int
  ) -> Bool {
    guard
      let style = storage.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil)
        as? NSParagraphStyle,
      style.lineHeightMultiple > 1
    else { return false }
    let extra = rect.height - rect.height / style.lineHeightMultiple
    baselineOffset.pointee = (baselineOffset.pointee - extra / 2).rounded()
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
