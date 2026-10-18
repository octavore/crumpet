import Foundation
import SwiftTreeSitter

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Column content alignment, as declared by the `:--` / `:-:` / `--:` markers
/// in the delimiter row.
enum TableAlignment {
  case none
  case left
  case center
  case right

  /// Delimiter cell that declares this alignment.
  var delimiter: String {
    switch self {
    case .none: "---"
    case .left: ":---"
    case .center: ":---:"
    case .right: "---:"
    }
  }
}

/// Parsed pipe table, stamped on every character of the table as
/// ``NSAttributedString/Key/tableModel``.
///
/// The table source is concealed. Its first character lays out as a control
/// glyph the size of the table, and `TableWidgetView` is placed over that
/// space to display and edit the cells. A cell edit replaces the cell source
/// range, so the ranges are only valid for the text the model was parsed
/// from. Edits inside a table run the whole-document parse immediately, so
/// every edit leaves a fresh model behind.
final class TableModel: NSObject {
  struct Cell {
    /// Source range of the cell content, without surrounding spaces. Zero
    /// length for an empty cell.
    let range: NSRange
    /// Cell source text, escapes included.
    let text: String
  }

  struct Row {
    /// Row line, without its line break.
    let line: NSRange
    /// Cells in source order. A short row has fewer cells than the table has
    /// columns.
    let cells: [Cell]
  }

  /// Whole table source, from the start of the header line to the end of the
  /// last row, without the final line break.
  let range: NSRange
  /// Header row first, then body rows. The delimiter row is not included.
  let rows: [Row]
  let alignments: [TableAlignment]

  private var cachedGeometry: (width: CGFloat, geometry: TableGeometry)?

  init(range: NSRange, rows: [Row], alignments: [TableAlignment]) {
    self.range = range
    self.rows = rows
    self.alignments = alignments
  }

  var columnCount: Int { alignments.count }

  /// Cell text at `row`, `column`. Empty for a cell a short row lacks.
  func text(row: Int, column: Int) -> String {
    guard row < rows.count, column < rows[row].cells.count else { return "" }
    return rows[row].cells[column].text
  }

  /// Every cell text, padded so each row has `columnCount` cells.
  var grid: [[String]] {
    rows.indices.map { row in (0..<columnCount).map { text(row: row, column: $0) } }
  }

  /// Column widths and row heights for a table laid out in `maxWidth`.
  @MainActor
  func geometry(maxWidth: CGFloat) -> TableGeometry {
    if let cachedGeometry, abs(cachedGeometry.width - maxWidth) < 0.5 {
      return cachedGeometry.geometry
    }
    let geometry = TableGeometry.measure(self, maxWidth: maxWidth)
    cachedGeometry = (maxWidth, geometry)
    return geometry
  }

  // MARK: Markdown generation

  /// Pipe table Markdown for `cells`, header row first. Each row is padded
  /// or cut to `alignments.count` cells.
  static func markdown(cells: [[String]], alignments: [TableAlignment]) -> String {
    let count = alignments.count
    func line(_ texts: [String]) -> String {
      "| " + texts.joined(separator: " | ") + " |"
    }
    var lines: [String] = []
    for (index, row) in cells.enumerated() {
      let padded = (0..<count).map { $0 < row.count ? escaped(row[$0]) : "" }
      lines.append(line(padded))
      if index == 0 {
        lines.append(line(alignments.map(\.delimiter)))
      }
    }
    return lines.joined(separator: "\n")
  }

  /// Cell text made safe to place between pipes. Line breaks become spaces,
  /// and a pipe not already escaped gets a backslash.
  static func escaped(_ text: String) -> String {
    var result = ""
    var previous: Character?
    for character in text {
      switch character {
      case "\n", "\r", "\u{2028}", "\u{2029}":
        result.append(" ")
      case "|" where previous != "\\":
        result.append("\\|")
      default:
        result.append(character)
      }
      previous = character
    }
    return result
  }
}

extension NSAttributedString.Key {
  /// Table this character belongs to. The value is a ``TableModel``. Read by
  /// the layout manager delegate to conceal the source and reserve the table
  /// space, and by the coordinator to place each `TableWidgetView`.
  static let tableModel = NSAttributedString.Key("CrumpetTableModel")
}

extension NSAttributedString {
  /// Table whose source contains `location`, or ends immediately before it.
  func tableModel(around location: Int) -> TableModel? {
    for index in [location, location - 1] where index >= 0 && index < length {
      if let model = attribute(.tableModel, at: index, effectiveRange: nil) as? TableModel,
        NSMaxRange(model.range) <= length,
        location >= model.range.location, location <= NSMaxRange(model.range)
      {
        return model
      }
    }
    return nil
  }
}

extension MarkdownHighlighter {
  // MARK: Table parsing (block phase)

  /// Parses a table into a ``TableModel`` and stamps it over the table
  /// source.
  ///
  /// Runs in the `.block` phase so `stampBlockBase` records the model in each
  /// row's block base. The keystroke path then restores it on the edited row.
  func stampTable(_ node: Node, in storage: NSTextStorage, source: NSString, base: Int) {
    var rows: [TableModel.Row] = []
    var alignments: [TableAlignment] = []
    var lines: [NSRange] = []

    for index in 0..<node.childCount {
      guard let child = node.child(at: index) else { continue }
      let kind = child.nodeType ?? ""
      let range = nsRange(child.byteRange, base: base)
      guard range.length > 0 else { continue }
      switch kind {
      case "pipe_table_header", "pipe_table_row":
        let line = contentRange(of: range, in: source)
        lines.append(line)
        let spans = Self.columnSpans(in: line, source: source).spans
        let cells = spans.map { span in
          let content = Self.trimmed(span, in: source)
          return TableModel.Cell(range: content, text: source.substring(with: content))
        }
        rows.append(TableModel.Row(line: line, cells: cells))
      case "pipe_table_delimiter_row":
        lines.append(contentRange(of: range, in: source))
        alignments = Self.alignments(of: child)
      default:
        continue
      }
    }
    guard let first = lines.first, let last = lines.last, !rows.isEmpty else { return }

    let columnCount = max(alignments.count, rows.map(\.cells.count).max() ?? 0)
    if alignments.count < columnCount {
      alignments += Array(repeating: .none, count: columnCount - alignments.count)
    }
    let start = source.paragraphRange(for: NSRange(location: first.location, length: 0)).location
    let range = NSRange(location: start, length: NSMaxRange(last) - start)
    guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
    storage.addAttribute(
      .tableModel, value: TableModel(range: range, rows: rows, alignments: alignments),
      range: range)
  }

  // MARK: Row splitting

  /// Character ranges between the `|` separators of a row, plus the
  /// separator locations.
  ///
  /// Derived from the text rather than from `pipe_table_cell` nodes. A cell
  /// node covers its content and trailing space but not the leading space
  /// after the pipe.
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

    // A leading or trailing `|` is the table border, not a separator around
    // an empty cell.
    if let first = spans.first, isBlank(first, source), !pipes.isEmpty {
      spans.removeFirst()
    }
    if let last = spans.last, isBlank(last, source), !pipes.isEmpty, !spans.isEmpty {
      spans.removeLast()
    }
    return (spans, pipes)
  }

  /// `span` without its leading and trailing spaces. An all-space span
  /// becomes a zero-length range after its first space, so text inserted
  /// there keeps one space on each side.
  static func trimmed(_ span: NSRange, in source: NSString) -> NSRange {
    var start = span.location
    var end = NSMaxRange(span)
    while start < end, isSpace(source.character(at: start)) { start += 1 }
    while end > start, isSpace(source.character(at: end - 1)) { end -= 1 }
    if start == end {
      return NSRange(location: min(span.location + 1, NSMaxRange(span)), length: 0)
    }
    return NSRange(location: start, length: end - start)
  }

  /// Alignment each delimiter cell declares. `:--` is left, `--:` is right,
  /// `:-:` is center, and plain dashes are none.
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

  /// Line a row node names, without its terminator.
  ///
  /// tree-sitter reports a row range past its own newline and into the next
  /// row, so the line is resolved from where the range starts.
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
