import Foundation
import SwiftTreeSitter

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// How a column's content sits within its measured width, as declared by the
/// `:--` / `:-:` / `--:` markers in the delimiter row.
enum TableAlignment {
  case none
  case left
  case center
  case right
}

/// One table's measured geometry, shared by reference across every row of that
/// table. Two things depend on the sharing: the drawing pass groups rows into
/// tables by this object's identity, and the per-keystroke path re-applies a
/// row's padding from the copy the last full parse left on the text, so the
/// widths survive an edit without any range bookkeeping.
final class TableColumns: NSObject {
  /// The rendered width of each column, pipes excluded: the widest cell in the
  /// column plus `MarkdownHighlighter.tableCellPadding`.
  let widths: [CGFloat]
  let alignments: [TableAlignment]

  init(widths: [CGFloat], alignments: [TableAlignment]) {
    self.widths = widths
    self.alignments = alignments
  }
}

/// What one row of a table is, stamped on the row's whole paragraph as
/// ``NSAttributedString/Key/tableRow``. Uniform across the paragraph on
/// purpose: that is what lets it survive the per-keystroke path, which resets a
/// paragraph to the block attributes of its first character.
final class TableRowStyle: NSObject {
  let columns: TableColumns
  let isHeader: Bool
  let isDelimiter: Bool

  init(columns: TableColumns, isHeader: Bool, isDelimiter: Bool) {
    self.columns = columns
    self.isHeader = isHeader
    self.isDelimiter = isDelimiter
  }
}

extension NSAttributedString.Key {
  /// The table row this character's paragraph is, and the measured geometry of
  /// the table it belongs to. Read by `EditorLayoutManager` to stroke the grid,
  /// by the line-fragment delegate to collapse the delimiter row, and by the
  /// per-keystroke path to re-apply the row's padding without re-measuring.
  static let tableRow = NSAttributedString.Key("CrumpetTableRow")

  /// Marks a character that renders as nothing at all: a table's `|`
  /// separators, whose job is done by the stroked grid, and the whole
  /// `|---|:--:|` delimiter row. Unlike ``markdownMarker`` this never reveals,
  /// whatever `Typography.revealMode` says — revealing a pipe would add its
  /// advance back and pull every column off the grid drawn around it. The
  /// characters stay in the text storage; only what is drawn changes.
  static let tableHidden = NSAttributedString.Key("CrumpetTableHidden")
}

extension MarkdownHighlighter {
  /// Breathing room added to the widest cell in a column, split evenly by the
  /// cell's own leading and trailing spaces where the author wrote them.
  static let tableCellPadding: CGFloat = 18

  // MARK: Whole-table layout (full parse)

  /// Measures a table's columns and pads every row to them.
  ///
  /// Runs in the `.inline` phase, after the walk has descended into the cells,
  /// for two reasons. Emphasis inside a cell changes the font it renders in, so
  /// measuring before the inline pass would measure the wrong thing. And
  /// `stampBlockBase` runs between the phases, recording a paragraph's first
  /// character's attributes as the base the keystroke path restores: a row's
  /// first character is a `|`, so anything per-cell applied in the block phase
  /// would be captured and then smeared across the whole row on the next
  /// keystroke.
  func layoutTable(_ node: Node, in storage: NSTextStorage, source: NSString, base: Int) {
    var rows: [(paragraph: NSRange, spans: [NSRange], pipes: [Int], isHeader: Bool)] = []
    var alignments: [TableAlignment] = []
    var delimiter: NSRange?

    for index in 0..<node.childCount {
      guard let child = node.child(at: index) else { continue }
      let kind = child.nodeType ?? ""
      let range = nsRange(child.byteRange, base: base)
      guard range.length > 0 else { continue }
      switch kind {
      case "pipe_table_header", "pipe_table_row":
        let paragraph = contentRange(of: range, in: source)
        let split = Self.columnSpans(in: paragraph, source: source)
        rows.append((paragraph, split.spans, split.pipes, kind == "pipe_table_header"))
      case "pipe_table_delimiter_row":
        delimiter = contentRange(of: range, in: source)
        alignments = Self.alignments(of: child)
      default:
        continue
      }
    }
    guard !rows.isEmpty else { return }

    // Widest rendered cell per column. A row with fewer cells than the widest
    // row simply contributes nothing to the columns it doesn't reach.
    let columnCount = rows.reduce(0) { max($0, $1.spans.count) }
    var widths = [CGFloat](repeating: 0, count: columnCount)
    var measured: [[CGFloat]] = []
    for row in rows {
      var rowWidths: [CGFloat] = []
      for (column, span) in row.spans.enumerated() {
        let width = Self.renderedWidth(of: span, in: storage)
        rowWidths.append(width)
        widths[column] = max(widths[column], width)
      }
      measured.append(rowWidths)
    }
    let columns = TableColumns(
      widths: widths.map { $0 + Self.tableCellPadding },
      alignments: Self.padded(alignments, to: columnCount))

    for (index, row) in rows.enumerated() {
      applyRowLayout(
        paragraph: row.paragraph, spans: row.spans, pipes: row.pipes, widths: measured[index],
        columns: columns, isHeader: row.isHeader, in: storage)
    }
    if let delimiter {
      applyDelimiterRow(delimiter, columns: columns, in: storage)
    }
  }

  // MARK: Row layout (full parse and keystroke path)

  /// Pads one row's cells out to the table's column widths and hides its pipes.
  ///
  /// `widths` is the row's own measured cell widths; pass nil to have them
  /// measured here, which is what the per-keystroke path does (it re-applies a
  /// row whose column widths are already known but whose cell contents just
  /// changed).
  func applyRowLayout(
    paragraph: NSRange, spans: [NSRange], pipes: [Int], widths: [CGFloat]?,
    columns: TableColumns, isHeader: Bool, in storage: NSTextStorage
  ) {
    for pipe in pipes where pipe < storage.length {
      storage.addAttribute(.tableHidden, value: true, range: NSRange(location: pipe, length: 1))
    }
    for (column, span) in spans.enumerated() where column < columns.widths.count {
      let natural = widths.map { $0[column] } ?? Self.renderedWidth(of: span, in: storage)
      let padding = max(0, columns.widths[column] - natural)
      guard padding > 0 else { continue }
      pad(span, by: padding, aligned: columns.alignments[column], in: storage)
    }
    storage.addAttribute(
      .tableRow,
      value: TableRowStyle(columns: columns, isHeader: isHeader, isDelimiter: false),
      range: paragraph)
  }

  /// Hides the `|---|:--:|` row: its glyphs are drawn in no colour at all, and
  /// ``MarkerConcealment`` collapses its line fragment to a hairline, so the row
  /// leaves the layout without leaving the text.
  ///
  /// Deliberately *not* the null glyphs that hide the pipes. A line whose every
  /// glyph is null has nothing left to break on, and TextKit folds it into the
  /// end of the line above: the two rows share one fragment, and a fragment
  /// shared by two rows can't be given one row's height. An invisible glyph
  /// still breaks its line, which is the property this row needs.
  func applyDelimiterRow(_ paragraph: NSRange, columns: TableColumns, in storage: NSTextStorage) {
    guard paragraph.length > 0 else { return }
    storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: paragraph)
    storage.addAttribute(
      .tableRow,
      value: TableRowStyle(columns: columns, isHeader: false, isDelimiter: true),
      range: paragraph)
  }

  /// Distributes `padding` across the cell as letter spacing, at the anchor its
  /// alignment calls for.
  ///
  /// `.kern` adds space *after* the character it sits on, so padding placed
  /// after the cell's last glyph pushes the following pipe (and with it the
  /// column boundary) rightwards, which is left alignment. Right and centre
  /// need space *before* the content, and the only glyph available for that is
  /// the cell's own leading space, since the character before that is the pipe
  /// and a null glyph carries no advance. A cell written `|a|`, with no leading
  /// space, therefore falls back to left alignment.
  private func pad(
    _ span: NSRange, by padding: CGFloat, aligned alignment: TableAlignment,
    in storage: NSTextStorage
  ) {
    guard span.length > 0 else { return }
    let trailing = span.location + span.length - 1
    let leading = Self.leadingAnchor(in: span, storage: storage)

    switch alignment {
    case .right where leading != nil:
      storage.addAttribute(.kern, value: padding, range: NSRange(location: leading!, length: 1))
    case .center where leading != nil:
      storage.addAttribute(
        .kern, value: padding / 2, range: NSRange(location: leading!, length: 1))
      storage.addAttribute(
        .kern, value: padding - padding / 2, range: NSRange(location: trailing, length: 1))
    default:
      storage.addAttribute(.kern, value: padding, range: NSRange(location: trailing, length: 1))
    }
  }

  /// The cell's leading whitespace run's last character, the only glyph that
  /// can carry padding placed *before* the content. Nil when the content starts
  /// at the cell's first character.
  private static func leadingAnchor(in span: NSRange, storage: NSTextStorage) -> Int? {
    let source = storage.mutableString
    var index = span.location
    let end = span.location + span.length
    while index < end, isSpace(source.character(at: index)) { index += 1 }
    guard index > span.location, index < end else { return nil }
    return index - 1
  }

  // MARK: Measurement

  /// The width the cell actually renders at: its attributed substring, with the
  /// characters that render as nothing removed and any padding from a previous
  /// pass stripped.
  ///
  /// Measuring the source text instead would be wrong twice over. The span
  /// keeps the author's own spaces, which stay visible and take width, so a
  /// trimmed measurement overshoots by exactly those spaces and `| a |` would
  /// not line up with `|a|`. And a cell containing `**x**` renders bold and
  /// two markers shorter than its source measures.
  static func renderedWidth(of span: NSRange, in storage: NSTextStorage) -> CGFloat {
    guard span.length > 0, span.location + span.length <= storage.length else { return 0 }
    let piece = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: span))
    let full = NSRange(location: 0, length: piece.length)
    var concealed: [NSRange] = []
    piece.enumerateAttribute(.markdownMarker, in: full) { value, range, _ in
      if value != nil { concealed.append(range) }
    }
    for range in concealed.reversed() { piece.deleteCharacters(in: range) }
    piece.removeAttribute(.kern, range: NSRange(location: 0, length: piece.length))
    return piece.size().width
  }

  // MARK: Row splitting

  /// The character ranges between a row's `|` separators, plus the separators'
  /// own locations.
  ///
  /// Derived from the text rather than from `pipe_table_cell` nodes because
  /// those are not a partition of the row: a cell node covers its content and
  /// its trailing space but not the leading space after the pipe, whereas what
  /// a column occupies on screen is exactly the gap between two pipes. Reading
  /// the text also gives the per-keystroke path a splitter that needs no parse
  /// tree.
  ///
  /// A `\|` is content, not a separator, matching how the parser reads it.
  static func columnSpans(in paragraph: NSRange, source: NSString)
    -> (spans: [NSRange], pipes: [Int])
  {
    var pipes: [Int] = []
    let end = paragraph.location + paragraph.length
    var index = paragraph.location
    while index < end {
      let character = source.character(at: index)
      if character == 0x5C {  // backslash: skip whatever it escapes
        index += 2
        continue
      }
      if character == 0x7C { pipes.append(index) }
      index += 1
    }

    var spans: [NSRange] = []
    var start = paragraph.location
    for pipe in pipes {
      spans.append(NSRange(location: start, length: pipe - start))
      start = pipe + 1
    }
    spans.append(NSRange(location: start, length: end - start))

    // A leading or trailing `|` is the table's own border, not a separator
    // around an empty cell, so the empty span it produces isn't a column.
    if let first = spans.first, isBlank(first, source), !pipes.isEmpty {
      spans.removeFirst()
    }
    if let last = spans.last, isBlank(last, source), !pipes.isEmpty, !spans.isEmpty {
      spans.removeLast()
    }
    return (spans, pipes)
  }

  /// The alignment each delimiter cell declares: `:--` left, `--:` right,
  /// `:-:` centre, plain dashes none.
  private static func alignments(of delimiterRow: Node) -> [TableAlignment] {
    var result: [TableAlignment] = []
    for index in 0..<delimiterRow.childCount {
      guard let cell = delimiterRow.child(at: index),
        cell.nodeType == "pipe_table_delimiter_cell"
      else { continue }
      var left = false
      var right = false
      for inner in 0..<cell.childCount {
        switch cell.child(at: inner)?.nodeType ?? "" {
        case "pipe_table_align_left": left = true
        case "pipe_table_align_right": right = true
        default: continue
        }
      }
      switch (left, right) {
      case (true, true): result.append(.center)
      case (true, false): result.append(.left)
      case (false, true): result.append(.right)
      case (false, false): result.append(.none)
      }
    }
    return result
  }

  private static func padded(_ alignments: [TableAlignment], to count: Int) -> [TableAlignment] {
    guard alignments.count < count else { return Array(alignments.prefix(count)) }
    return alignments + Array(repeating: .none, count: count - alignments.count)
  }

  private static func isBlank(_ range: NSRange, _ source: NSString) -> Bool {
    for index in range.location..<(range.location + range.length)
    where !isSpace(source.character(at: index)) {
      return false
    }
    return true
  }

  private static func isSpace(_ character: unichar) -> Bool {
    character == 0x20 || character == 0x09
  }

  /// The one line a row node names, without its terminator.
  ///
  /// Both halves matter. tree-sitter reports a row's range out past its own
  /// newline and into the row below, so the range is resolved from where it
  /// *starts* rather than over the whole of it, or a row would claim the next
  /// row's text as its own cells. And the terminator is dropped because hiding
  /// a newline is hiding a line break: a null glyph there merges the row into
  /// the one after it, which is exactly what a table wants least.
  private func contentRange(of range: NSRange, in source: NSString) -> NSRange {
    var start = 0
    var end = 0
    var contentsEnd = 0
    source.getParagraphStart(
      &start, end: &end, contentsEnd: &contentsEnd,
      for: NSRange(location: min(range.location, source.length), length: 0))
    let location = max(range.location, start)
    return NSRange(location: location, length: max(0, min(contentsEnd, source.length) - location))
  }
}
