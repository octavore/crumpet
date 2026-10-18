import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Measured layout of one table: column widths and row heights, in points,
/// excluding the border.
///
/// Measured with the same TextKit 1 setup the cell text views use, so a cell
/// wraps in the view exactly where it wrapped here.
struct TableGeometry: Equatable {
  var columnWidths: [CGFloat]
  var rowHeights: [CGFloat]

  /// Space between a cell edge and its text, left and right.
  static let horizontalInset: CGFloat = 10
  /// Space between a cell edge and its text, top and bottom.
  static let verticalInset: CGFloat = 7
  /// Widest a column grows before its text wraps.
  static let maxColumnWidth: CGFloat = 320
  static let minColumnWidth: CGFloat = 56
  static let border: CGFloat = 1
  static let cornerRadius: CGFloat = 8
  /// Space above and below the table inside its line fragment.
  static let margin: CGFloat = 6

  var contentWidth: CGFloat { columnWidths.reduce(0, +) }
  var contentHeight: CGFloat { rowHeights.reduce(0, +) }

  /// Widget size in a text column `maxWidth` wide. A table wider than the
  /// column scrolls horizontally inside it.
  func frameSize(maxWidth: CGFloat) -> CGSize {
    CGSize(
      width: min(contentWidth + 2 * Self.border, max(0, maxWidth)),
      height: contentHeight + 2 * Self.border)
  }

  /// Height of the line fragment the table lays out in.
  var lineHeight: CGFloat { contentHeight + 2 * Self.border + 2 * Self.margin }

  /// Left edge of each column, from the content origin.
  var columnOffsets: [CGFloat] {
    var offsets: [CGFloat] = []
    var x: CGFloat = 0
    for width in columnWidths {
      offsets.append(x)
      x += width
    }
    return offsets
  }

  /// Top edge of each row, from the content origin.
  var rowOffsets: [CGFloat] {
    var offsets: [CGFloat] = []
    var y: CGFloat = 0
    for height in rowHeights {
      offsets.append(y)
      y += height
    }
    return offsets
  }

  @MainActor
  static func measure(_ model: TableModel, maxWidth: CGFloat) -> TableGeometry {
    let limit = max(minColumnWidth, min(maxColumnWidth, maxWidth - 2 * border))
    let grid = model.grid
    var widths: [CGFloat] = []
    for column in 0..<model.columnCount {
      var natural: CGFloat = 0
      for (row, cells) in grid.enumerated() {
        let size = TableCellMeasurer.size(
          of: cells[column], isHeader: row == 0, alignment: .none, width: nil)
        natural = max(natural, size.width)
      }
      widths.append(min(limit, max(minColumnWidth, (natural + 2 * horizontalInset).rounded(.up))))
    }
    var heights: [CGFloat] = []
    for (row, cells) in grid.enumerated() {
      var height: CGFloat = 0
      for column in 0..<model.columnCount {
        let size = TableCellMeasurer.size(
          of: cells[column], isHeader: row == 0, alignment: model.alignments[column],
          width: widths[column] - 2 * horizontalInset)
        height = max(height, size.height)
      }
      heights.append((height + 2 * verticalInset).rounded(.up))
    }
    return TableGeometry(columnWidths: widths, rowHeights: heights)
  }
}

/// Text attributes of a table cell.
@MainActor
enum TableCellStyle {
  /// Inline styler for cell text, separate from any document highlighter.
  private static let styler = MarkdownHighlighter()

  static func font(isHeader: Bool) -> PlatformFont {
    let body = TextStyle.body.font
    return isHeader ? body.with(traits: body.traits.union(.boldTrait)) : body
  }

  static func attributes(isHeader: Bool, alignment: TableAlignment)
    -> [NSAttributedString.Key: Any]
  {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 2
    switch alignment {
    case .none, .left: style.alignment = .natural
    case .center: style.alignment = .center
    case .right: style.alignment = .right
    }
    return [
      .font: font(isHeader: isHeader),
      .paragraphStyle: style,
      .foregroundColor: PlatformColor(Typography.colorScheme.text),
    ]
  }

  /// Restyles all of `storage` as a cell. Inline Markdown is styled and its
  /// markers are dimmed. Only attributes change, so this is safe to call from
  /// text storage edit processing.
  static func apply(to storage: NSTextStorage, isHeader: Bool, alignment: TableAlignment) {
    let full = NSRange(location: 0, length: storage.length)
    guard full.length > 0 else { return }
    storage.setAttributes(attributes(isHeader: isHeader, alignment: alignment), range: full)
    styler.styleInlineText(in: storage)
    let dimmed = PlatformColor(Typography.colorScheme.text).withAlphaComponent(0.4)
    storage.enumerateAttribute(.markdownMarker, in: full) { value, range, _ in
      if value != nil { storage.addAttribute(.foregroundColor, value: dimmed, range: range) }
    }
  }
}

/// Measures cell text with a scratch TextKit 1 stack.
@MainActor
enum TableCellMeasurer {
  private static let storage = NSTextStorage()
  private static let container: NSTextContainer = {
    let container = NSTextContainer(size: CGSize(width: 1e7, height: 1e7))
    container.lineFragmentPadding = 0
    return container
  }()
  private static let layoutManager: NSLayoutManager = {
    let manager = NSLayoutManager()
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    return manager
  }()

  /// Size of `text` laid out `width` wide, or on one line if `width` is nil.
  /// Empty text measures as one line with no width.
  static func size(of text: String, isHeader: Bool, alignment: TableAlignment, width: CGFloat?)
    -> CGSize
  {
    let manager = layoutManager
    let sample = text.isEmpty ? "X" : text
    storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: sample)
    TableCellStyle.apply(to: storage, isHeader: isHeader, alignment: alignment)
    container.size = CGSize(width: max(1, width ?? 1e7), height: 1e7)
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container).size
    return CGSize(
      width: text.isEmpty ? 0 : used.width.rounded(.up), height: used.height.rounded(.up))
  }
}
