import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Draws the grid behind a Markdown table.
///
/// The table's borders are not text and are not in the document: the source
/// keeps its `|` separators and its `|---|` row, the layout hides both, and the
/// lines you actually see are stroked here, behind the glyphs. That split is
/// what lets a table look rendered while every keystroke still edits plain
/// Markdown.
///
/// Column boundaries need no glyph probing. `MarkdownHighlighter` pads each cell
/// with `.kern` until it occupies exactly its column's measured width, so the
/// running total of ``TableColumns/widths`` from the row's left edge *is* where
/// the text lands. The arithmetic and the layout agree by construction.
final class EditorLayoutManager: NSLayoutManager {
  /// The pictures block images display.
  let images = ImageStore()

  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    guard let storage = textStorage, storage.length > 0,
      let context = currentGraphicsContext
    else { return }

    let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    for table in tables(intersecting: visible, in: storage) {
      draw(table, in: storage, at: origin, into: context)
    }
    drawImageChips(in: visible, storage: storage, at: origin, into: context)
  }

  // MARK: Image chips

  /// Draws each image whose syntax is concealed. A block image whose picture
  /// has loaded draws the picture. Any other image fills a rounded chip and
  /// draws the chip's icon in the space its `!` reserves. An image is concealed
  /// when its `!` glyph is a control glyph, which keeps this in agreement with
  /// the reveal mode and the caret without recomputing either.
  private func drawImageChips(
    in visible: NSRange, storage: NSTextStorage, at origin: CGPoint, into context: CGContext
  ) {
    guard let container = textContainers.first else { return }
    let color = PlatformColor(Typography.colorScheme.link)
    storage.enumerateAttribute(.imageChip, in: visible) { value, run, _ in
      guard value != nil else { return }
      // The run is clipped to `visible`, so an image that starts above the
      // screen needs its full range to find its `!`.
      var image = run
      _ = storage.attribute(
        .imageChip, at: run.location, longestEffectiveRange: &image,
        in: storage.mutableString.paragraphRange(for: run))
      let icon = glyphIndexForCharacter(at: image.location)
      guard propertyForGlyph(at: icon).contains(.controlCharacter) else { return }

      context.saveGState()
      defer { context.restoreGState() }
      let line = lineFragmentRect(forGlyphAt: icon, effectiveRange: nil)
      let position = location(forGlyphAt: icon)
      let baseline = CGPoint(
        x: origin.x + line.minX + position.x, y: origin.y + line.minY + position.y)

      if let source = storage.attribute(.imageBlock, at: image.location, effectiveRange: nil)
        as? String, let picture = images.image(for: source)
      {
        let size = ImageStore.displaySize(
          of: picture, maxWidth: container.size.width - 2 * container.lineFragmentPadding)
        let rect = CGRect(origin: CGPoint(x: baseline.x, y: baseline.y - size.height), size: size)
        context.addPath(
          CGPath(
            roundedRect: rect, cornerWidth: ImageStore.cornerRadius,
            cornerHeight: ImageStore.cornerRadius, transform: nil))
        context.clip()
        #if canImport(UIKit)
          picture.draw(in: rect)
        #elseif canImport(AppKit)
          picture.draw(
            in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
            hints: nil)
        #endif
        return
      }

      context.setFillColor(color.withAlphaComponent(0.15).cgColor)
      let glyphs = glyphRange(forCharacterRange: image, actualCharacterRange: nil)
      enumerateEnclosingRects(
        forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
        in: container
      ) { rect, _ in
        let chip = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: 1)
        let path = CGPath(
          roundedRect: chip, cornerWidth: chip.height / 2, cornerHeight: chip.height / 2,
          transform: nil)
        context.addPath(path)
        context.fillPath()
      }

      let font =
        storage.attribute(.font, at: image.location, effectiveRange: nil) as? PlatformFont
        ?? TextStyle.body.font
      ImageChip.drawIcon(at: baseline, font: font, color: color)
    }
  }

  // MARK: Finding tables

  /// The character range of every table any part of which is on screen.
  ///
  /// Each table is grown past the visible range before it's drawn: a table
  /// taller than the viewport would otherwise be clipped to what's visible and
  /// get a border stroked across the middle of it at the edge of the screen.
  /// Growing is bounded by the table, not the document.
  private func tables(intersecting visible: NSRange, in storage: NSTextStorage) -> [NSRange] {
    var found: [NSRange] = []
    var last: TableColumns?
    storage.enumerateAttribute(.tableRow, in: visible) { value, range, _ in
      guard let row = value as? TableRowStyle else {
        last = nil
        return
      }
      // Adjacent rows of one table share a `TableColumns` by reference, which
      // is what separates two tables written back to back from one table.
      if let previous = last, previous === row.columns, var current = found.last {
        current.length = range.location + range.length - current.location
        found[found.count - 1] = current
      } else {
        found.append(range)
      }
      last = row.columns
    }
    return found.map { grown($0, in: storage) }
  }

  /// `range` extended over every neighbouring row belonging to the same table.
  private func grown(_ range: NSRange, in storage: NSTextStorage) -> NSRange {
    guard
      let columns =
        (storage.attribute(.tableRow, at: range.location, effectiveRange: nil)
        as? TableRowStyle)?.columns
    else { return range }

    var start = range.location
    while start > 0 {
      var run = NSRange(location: NSNotFound, length: 0)
      guard
        let row = storage.attribute(.tableRow, at: start - 1, effectiveRange: &run)
          as? TableRowStyle, row.columns === columns
      else { break }
      start = run.location
    }
    var end = range.location + range.length
    while end < storage.length {
      var run = NSRange(location: NSNotFound, length: 0)
      guard
        let row = storage.attribute(.tableRow, at: end, effectiveRange: &run) as? TableRowStyle,
        row.columns === columns
      else { break }
      end = run.location + run.length
    }
    return NSRange(location: start, length: end - start)
  }

  // MARK: Drawing

  private func draw(
    _ table: NSRange, in storage: NSTextStorage, at origin: CGPoint, into context: CGContext
  ) {
    var columns: TableColumns?
    var rows: [(rect: CGRect, isHeader: Bool)] = []
    let source = storage.mutableString
    var location = table.location
    let end = min(table.location + table.length, storage.length)
    while location < end {
      let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
      location = paragraph.location + paragraph.length
      guard
        let row = storage.attribute(.tableRow, at: paragraph.location, effectiveRange: nil)
          as? TableRowStyle
      else { continue }
      columns = row.columns
      // The delimiter row is laid out as a hairline and drawn as nothing; it
      // isn't a row of the rendered table.
      guard !row.isDelimiter else { continue }
      // Anchored on the row's last character, not its first. A row opens with a
      // `|`, whose glyph is null, and a null glyph at the start of a line takes
      // no space and so gets laid out as trailing content of the line *above*:
      // asking where that glyph sits answers for the previous row and draws the
      // whole grid one row too high.
      guard let anchor = lastContentCharacter(of: paragraph, in: source) else { continue }
      // One fragment per row, guaranteed: table paragraphs clip rather than
      // wrap, so a row is never split across visual lines.
      var rect = lineFragmentRect(
        forGlyphAt: glyphIndexForCharacter(at: anchor), effectiveRange: nil)
      rect.origin.x += origin.x
      rect.origin.y += origin.y
      rows.append((rect, row.isHeader))
    }
    guard let columns, !rows.isEmpty, !columns.widths.isEmpty else { return }

    // Text starts one `lineFragmentPadding` inside the fragment, and the column
    // widths are measured from the text, not from the fragment.
    let left = rows[0].rect.minX + (textContainers.first?.lineFragmentPadding ?? 0)
    let top = rows[0].rect.minY
    let bottom = rows[rows.count - 1].rect.maxY
    let total = columns.widths.reduce(0, +)
    let frame = CGRect(x: left, y: top, width: total, height: bottom - top)

    context.saveGState()
    defer { context.restoreGState() }

    for row in rows where row.isHeader {
      context.setFillColor(PlatformColor.tableHeaderFill.cgColor)
      context.fill(CGRect(x: left, y: row.rect.minY, width: total, height: row.rect.height))
    }

    // A hairline lands on a pixel boundary only if it's centred on a half
    // point, and a blurred grid is the one thing that gives a drawn table away.
    let width: CGFloat = 1
    context.setStrokeColor(PlatformColor.tableGrid.cgColor)
    context.setLineWidth(width)
    context.stroke(frame.insetBy(dx: width / 2, dy: width / 2))

    context.beginPath()
    for row in rows.dropLast() {
      let y = aligned(row.rect.maxY)
      context.move(to: CGPoint(x: left, y: y))
      context.addLine(to: CGPoint(x: left + total, y: y))
    }
    var x = left
    for column in columns.widths.dropLast() {
      x += column
      let position = aligned(x)
      context.move(to: CGPoint(x: position, y: top))
      context.addLine(to: CGPoint(x: position, y: bottom))
    }
    context.strokePath()
  }

  private func aligned(_ value: CGFloat) -> CGFloat { value.rounded() + 0.5 }

  /// The last character of a paragraph that isn't its line terminator: a
  /// position certain to be laid out in the paragraph's own line fragment.
  private func lastContentCharacter(of paragraph: NSRange, in source: NSString) -> Int? {
    var index = paragraph.location + paragraph.length
    while index > paragraph.location {
      let character = source.character(at: index - 1)
      if character != 0x0A, character != 0x0D { return index - 1 }
      index -= 1
    }
    return nil
  }
}

/// The icon at the front of a concealed image's chip. Layout reserves
/// ``iconAdvance(for:)`` for it and `EditorLayoutManager` draws it there.
enum ImageChip {
  static let symbolName = "photo"

  /// The width a concealed `!` takes in `font`: the icon plus a gap before the
  /// alt text.
  static func iconAdvance(for font: PlatformFont) -> CGFloat {
    (font.pointSize * 1.3).rounded()
  }

  /// Draws the icon in the space starting at `baseline`, centered on the cap
  /// height of `font`.
  static func drawIcon(at baseline: CGPoint, font: PlatformFont, color: PlatformColor) {
    let height = (font.capHeight * 1.2).rounded()
    #if canImport(UIKit)
      let config = UIImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
      guard
        let image = UIImage(systemName: symbolName, withConfiguration: config)?
          .withTintColor(color, renderingMode: .alwaysOriginal)
      else { return }
    #elseif canImport(AppKit)
      let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
      guard
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
          .withSymbolConfiguration(config)
      else { return }
    #endif
    guard image.size.height > 0 else { return }
    let width = height * image.size.width / image.size.height
    let rect = CGRect(
      x: baseline.x + (iconAdvance(for: font) - width) / 2 - 1,
      y: baseline.y - font.capHeight / 2 - height / 2,
      width: width, height: height)
    #if canImport(UIKit)
      image.draw(in: rect)
    #elseif canImport(AppKit)
      image.draw(
        in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
        hints: nil)
    #endif
  }
}
