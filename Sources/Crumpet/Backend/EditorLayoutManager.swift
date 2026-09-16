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
  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    guard let storage = textStorage, storage.length > 0,
      let context = currentGraphicsContext
    else { return }

    let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    for table in tables(intersecting: visible, in: storage) {
      draw(table, in: storage, at: origin, into: context)
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
