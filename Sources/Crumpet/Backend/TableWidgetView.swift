import Foundation

#if canImport(UIKit)
  import UIKit
  typealias PlatformView = UIView
  typealias TableScrollView = UIScrollView
#elseif canImport(AppKit)
  import AppKit
  typealias PlatformView = NSView
#endif

/// Cell position in a table. The header is row 0.
struct TableCellPosition: Equatable {
  var row: Int
  var column: Int
}

/// Caret movement out of a table cell.
enum TableNavigation {
  /// Tab. Moves to the next cell, adding a row after the last cell.
  case nextCell
  /// Shift-Tab. Moves to the previous cell.
  case previousCell
  /// Return. Moves down one cell, adding a row in the last row.
  case nextRow
  /// Up arrow on the first line of a cell.
  case up
  /// Down arrow on the last line of a cell.
  case down
  /// Left arrow at the start of a cell.
  case left
  /// Right arrow at the end of a cell.
  case right
}

/// Structural table edit offered in a cell context menu.
enum TableOperation: Int, CaseIterable {
  /// Shows the table source as text until the editor caret leaves it.
  case editMarkdown
  case insertRowAbove
  case insertRowBelow
  case insertColumnLeft
  case insertColumnRight
  case deleteRow
  case deleteColumn
  case alignLeft
  case alignCenter
  case alignRight
  case deleteTable

  var title: String {
    switch self {
    case .editMarkdown: "Edit as Markdown"
    case .insertRowAbove: "Insert Row Above"
    case .insertRowBelow: "Insert Row Below"
    case .insertColumnLeft: "Insert Column Left"
    case .insertColumnRight: "Insert Column Right"
    case .deleteRow: "Delete Row"
    case .deleteColumn: "Delete Column"
    case .alignLeft: "Align Column Left"
    case .alignCenter: "Align Column Center"
    case .alignRight: "Align Column Right"
    case .deleteTable: "Delete Table"
    }
  }

  /// Operations offered for a cell in `row`. The header row cannot be
  /// deleted or have a row inserted above it.
  static func available(forRow row: Int) -> [TableOperation] {
    row == 0 ? allCases.filter { $0 != .insertRowAbove && $0 != .deleteRow } : allCases
  }

  /// Index of the menu group the operation belongs to.
  var group: Int {
    switch self {
    case .editMarkdown: 0
    case .insertRowAbove, .insertRowBelow, .insertColumnLeft, .insertColumnRight: 1
    case .deleteRow, .deleteColumn: 2
    case .alignLeft, .alignCenter, .alignRight: 3
    case .deleteTable: 4
    }
  }
}

/// Receiver of edits made in a ``TableWidgetView``.
@MainActor
protocol TableWidgetHost: AnyObject {
  func tableWidget(
    _ widget: TableWidgetView, didEditCellAt position: TableCellPosition, text: String)
  func tableWidget(
    _ widget: TableWidgetView, navigate navigation: TableNavigation,
    from position: TableCellPosition)
  func tableWidget(
    _ widget: TableWidgetView, perform operation: TableOperation, at position: TableCellPosition)
}

/// Editable view of one Markdown table, placed over the space the concealed
/// table source reserves in the editor.
///
/// Each cell is a wrapping text view. A table wider than the text column
/// scrolls horizontally. Edits are reported to ``host``, which writes them
/// to the Markdown source. The view only displays the model it is given.
final class TableWidgetView: PlatformView {
  weak var host: TableWidgetHost?
  private(set) var model: TableModel
  private(set) var geometry: TableGeometry
  private let scrollView = TableScrollView()
  private let gridView = TableGridView()
  private var cells: [[TableCellTextView]] = []
  #if canImport(AppKit)
    /// Cell the open context menu belongs to.
    private var menuPosition: TableCellPosition?
  #endif

  init(model: TableModel, geometry: TableGeometry, host: TableWidgetHost) {
    self.model = model
    self.geometry = geometry
    self.host = host
    super.init(frame: .zero)
    setUp()
    update(model: model, geometry: geometry, force: true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  private func setUp() {
    #if canImport(UIKit)
      backgroundColor = .clear
      clipsToBounds = true
      layer.cornerRadius = TableGeometry.cornerRadius
      layer.borderWidth = TableGeometry.border
      scrollView.backgroundColor = .clear
      scrollView.showsVerticalScrollIndicator = false
      scrollView.alwaysBounceVertical = false
      scrollView.alwaysBounceHorizontal = false
      scrollView.contentInsetAdjustmentBehavior = .never
      scrollView.addSubview(gridView)
      addSubview(scrollView)
      registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
        (view: TableWidgetView, _: UITraitCollection) in
        view.updateBorderColor()
      }
    #elseif canImport(AppKit)
      wantsLayer = true
      layer?.cornerRadius = TableGeometry.cornerRadius
      layer?.borderWidth = TableGeometry.border
      layer?.masksToBounds = true
      scrollView.drawsBackground = false
      scrollView.borderType = .noBorder
      scrollView.hasHorizontalScroller = true
      scrollView.hasVerticalScroller = false
      scrollView.autohidesScrollers = true
      scrollView.scrollerStyle = .overlay
      scrollView.verticalScrollElasticity = .none
      scrollView.documentView = gridView
      addSubview(scrollView)
    #endif
    updateBorderColor()
  }

  private func updateBorderColor() {
    #if canImport(UIKit)
      layer.borderColor = PlatformColor.tableGrid.resolvedColor(with: traitCollection).cgColor
    #elseif canImport(AppKit)
      effectiveAppearance.performAsCurrentDrawingAppearance {
        layer?.borderColor = PlatformColor.tableGrid.cgColor
      }
    #endif
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      layoutScrollView()
    }
  #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      layoutScrollView()
    }

    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      updateBorderColor()
    }
  #endif

  private func layoutScrollView() {
    let inset = TableGeometry.border
    scrollView.frame = bounds.insetBy(dx: inset, dy: inset)
    #if canImport(UIKit)
      scrollView.contentSize = gridView.frame.size
    #endif
  }

  // MARK: Model

  /// Shows `model`. Cell views are reused by position, so a focused cell
  /// keeps focus. A cell whose text already matches the model is left alone,
  /// which keeps its selection.
  func update(model: TableModel, geometry: TableGeometry, force: Bool = false) {
    let restyle = force || model !== self.model
    self.model = model
    self.geometry = geometry
    let rowCount = model.rows.count
    let columnCount = model.columnCount

    while cells.count > rowCount {
      cells.removeLast().forEach { $0.removeFromSuperview() }
    }
    for row in cells.indices {
      while cells[row].count > columnCount {
        cells[row].removeLast().removeFromSuperview()
      }
    }
    while cells.count < rowCount { cells.append([]) }
    for row in 0..<rowCount {
      while cells[row].count < columnCount {
        let cell = TableCellTextView()
        cell.delegate = self
        cell.widget = self
        gridView.addSubview(cell)
        cells[row].append(cell)
      }
    }

    let xs = geometry.columnOffsets
    let ys = geometry.rowOffsets
    let inset = CGSize(width: TableGeometry.horizontalInset, height: TableGeometry.verticalInset)
    for row in 0..<rowCount {
      for column in 0..<columnCount {
        let cell = cells[row][column]
        let position = TableCellPosition(row: row, column: column)
        let alignment = model.alignments[column]
        let roleChanged =
          cell.position != position || cell.isHeader != (row == 0)
          || cell.columnAlignment != alignment
        cell.position = position
        cell.isHeader = row == 0
        cell.columnAlignment = alignment
        let text = model.text(row: row, column: column)
        if cell.cellText != text {
          cell.setCellText(text)
        } else if restyle || roleChanged {
          cell.restyle()
        }
        cell.frame = CGRect(
          x: xs[column] + inset.width, y: ys[row] + inset.height,
          width: max(0, geometry.columnWidths[column] - 2 * inset.width),
          height: max(0, geometry.rowHeights[row] - 2 * inset.height))
      }
    }
    gridView.geometry = geometry
    gridView.frame = CGRect(
      x: 0, y: 0, width: geometry.contentWidth, height: geometry.contentHeight)
    layoutScrollView()
  }

  // MARK: Focus

  /// Cell that has keyboard focus.
  var focusedCell: TableCellTextView? {
    cells.joined().first { $0.isFocused }
  }

  /// Gives `position` keyboard focus with the caret at its start or end, and
  /// scrolls it into view.
  func focus(_ position: TableCellPosition, atEnd: Bool) {
    guard position.row >= 0, position.row < cells.count, position.column >= 0,
      position.column < cells[position.row].count
    else { return }
    let cell = cells[position.row][position.column]
    let caret = NSRange(location: atEnd ? (cell.cellText as NSString).length : 0, length: 0)
    #if canImport(UIKit)
      cell.becomeFirstResponder()
      cell.selectedRange = caret
    #elseif canImport(AppKit)
      window?.makeFirstResponder(cell)
      cell.setSelectedRange(caret)
    #endif
    reveal(cell)
  }

  /// Frame of the cell at `position`, including its insets, in this view.
  func frame(of cell: TableCellTextView) -> CGRect {
    let rect = cell.frame.insetBy(
      dx: -TableGeometry.horizontalInset, dy: -TableGeometry.verticalInset)
    return convert(rect, from: gridView)
  }

  /// Scrolls the table, then the editor, so `cell` is visible.
  private func reveal(_ cell: TableCellTextView) {
    let rect = cell.frame.insetBy(
      dx: -TableGeometry.horizontalInset, dy: -TableGeometry.verticalInset)
    #if canImport(UIKit)
      scrollView.scrollRectToVisible(rect, animated: false)
      if let editor = superview as? UIScrollView {
        editor.scrollRectToVisible(gridView.convert(rect, to: editor), animated: true)
      }
    #elseif canImport(AppKit)
      gridView.scrollToVisible(rect)
      if let editor = superview {
        editor.scrollToVisible(gridView.convert(rect, to: editor))
      }
    #endif
  }

  fileprivate func navigate(_ navigation: TableNavigation, from cell: TableCellTextView) {
    host?.tableWidget(self, navigate: navigation, from: cell.position)
  }

  fileprivate func cellDidChange(_ cell: TableCellTextView) {
    host?.tableWidget(self, didEditCellAt: cell.position, text: cell.cellText)
  }
}

// MARK: - Grid

/// Draws the header fill and the lines between cells. The outer border is
/// the widget layer border.
final class TableGridView: PlatformView {
  var geometry = TableGeometry(columnWidths: [], rowHeights: []) {
    didSet {
      guard geometry != oldValue else { return }
      #if canImport(UIKit)
        setNeedsDisplay()
      #elseif canImport(AppKit)
        needsDisplay = true
      #endif
    }
  }

  #if canImport(UIKit)
    override init(frame: CGRect) {
      super.init(frame: frame)
      isOpaque = false
      backgroundColor = .clear
      contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
      guard let context = UIGraphicsGetCurrentContext() else { return }
      drawGrid(in: context)
    }
  #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
      guard let context = NSGraphicsContext.current?.cgContext else { return }
      drawGrid(in: context)
    }
  #endif

  private func drawGrid(in context: CGContext) {
    let width = geometry.contentWidth
    let height = geometry.contentHeight
    if let header = geometry.rowHeights.first {
      context.setFillColor(PlatformColor.tableHeaderFill.cgColor)
      context.fill(CGRect(x: 0, y: 0, width: width, height: header))
    }
    context.setFillColor(PlatformColor.tableGrid.cgColor)
    for y in geometry.rowOffsets.dropFirst() {
      context.fill(CGRect(x: 0, y: y - 0.5, width: width, height: 1))
    }
    for x in geometry.columnOffsets.dropFirst() {
      context.fill(CGRect(x: x - 0.5, y: 0, width: 1, height: height))
    }
  }
}

// MARK: - Cell

/// Text view for one table cell. Built on a TextKit 1 stack with no insets
/// or line fragment padding, matching ``TableCellMeasurer``.
final class TableCellTextView: PlatformTextView {
  var position = TableCellPosition(row: -1, column: -1)
  var isHeader = false
  var columnAlignment = TableAlignment.none
  weak var widget: TableWidgetView?
  private let cellStorage: NSTextStorage

  init() {
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    storage.addLayoutManager(layoutManager)
    let container = NSTextContainer(size: CGSize(width: 0, height: 1e7))
    container.lineFragmentPadding = 0
    container.widthTracksTextView = true
    layoutManager.addTextContainer(container)
    cellStorage = storage
    super.init(frame: .zero, textContainer: container)
    storage.delegate = self
    #if canImport(UIKit)
      isScrollEnabled = false
      backgroundColor = .clear
      textContainerInset = .zero
      smartQuotesType = .no
      smartDashesType = .no
      allowsEditingTextAttributes = false
    #elseif canImport(AppKit)
      isRichText = false
      allowsUndo = false
      drawsBackground = false
      textContainerInset = .zero
      isVerticallyResizable = false
      isHorizontallyResizable = false
      isAutomaticQuoteSubstitutionEnabled = false
      isAutomaticDashSubstitutionEnabled = false
      usesFontPanel = false
    #endif
  }

  #if canImport(AppKit)
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
      cellStorage = container?.layoutManager?.textStorage ?? NSTextStorage()
      super.init(frame: frameRect, textContainer: container)
    }
  #endif

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  var cellText: String { cellStorage.string }

  var isFocused: Bool {
    #if canImport(UIKit)
      isFirstResponder
    #elseif canImport(AppKit)
      window?.firstResponder === self
    #endif
  }

  private var cellSelection: NSRange {
    #if canImport(UIKit)
      selectedRange
    #elseif canImport(AppKit)
      selectedRange()
    #endif
  }

  /// Replaces the text, keeping the selection where it fits.
  func setCellText(_ text: String) {
    let selection = cellSelection
    typingAttributes = TableCellStyle.attributes(isHeader: isHeader, alignment: columnAlignment)
    cellStorage.replaceCharacters(
      in: NSRange(location: 0, length: cellStorage.length), with: text)
    let length = cellStorage.length
    let location = min(selection.location, length)
    let clamped = NSRange(location: location, length: min(selection.length, length - location))
    #if canImport(UIKit)
      selectedRange = clamped
    #elseif canImport(AppKit)
      setSelectedRange(clamped)
    #endif
  }

  /// Re-applies the cell style, for a role or theme change.
  func restyle() {
    typingAttributes = TableCellStyle.attributes(isHeader: isHeader, alignment: columnAlignment)
    cellStorage.beginEditing()
    TableCellStyle.apply(to: cellStorage, isHeader: isHeader, alignment: columnAlignment)
    cellStorage.endEditing()
  }

  /// Whether the caret is on the first and on the last visual line.
  private var caretLines: (isFirst: Bool, isLast: Bool) {
    let length = cellStorage.length
    guard length > 0, let manager = cellStorage.layoutManagers.first else { return (true, true) }
    let glyphCount = manager.numberOfGlyphs
    guard glyphCount > 0 else { return (true, true) }
    let caret = min(cellSelection.location, length - 1)
    let line = manager.lineFragmentRect(
      forGlyphAt: manager.glyphIndexForCharacter(at: caret), effectiveRange: nil)
    let first = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
    let last = manager.lineFragmentRect(forGlyphAt: glyphCount - 1, effectiveRange: nil)
    return (line.minY <= first.minY, line.minY >= last.minY)
  }

  private var isCaretAtStart: Bool {
    let selection = cellSelection
    return selection.length == 0 && selection.location == 0
  }

  private var isCaretAtEnd: Bool {
    let selection = cellSelection
    return selection.length == 0 && selection.location == cellStorage.length
  }

  #if canImport(UIKit)
    override var keyCommands: [UIKeyCommand]? {
      let previous = UIKeyCommand(
        input: "\t", modifierFlags: .shift, action: #selector(moveToPreviousCell))
      previous.wantsPriorityOverSystemBehavior = true
      return (super.keyCommands ?? []) + [previous]
    }

    @objc private func moveToPreviousCell() {
      widget?.navigate(.previousCell, from: self)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      for press in presses {
        guard let key = press.key,
          key.modifierFlags.intersection([.shift, .control, .alternate, .command]).isEmpty
        else { continue }
        let navigation: TableNavigation? =
          switch key.keyCode {
          case .keyboardUpArrow: caretLines.isFirst ? .up : nil
          case .keyboardDownArrow: caretLines.isLast ? .down : nil
          case .keyboardLeftArrow: isCaretAtStart ? .left : nil
          case .keyboardRightArrow: isCaretAtEnd ? .right : nil
          default: nil
          }
        if let navigation {
          widget?.navigate(navigation, from: self)
          return
        }
      }
      super.pressesBegan(presses, with: event)
    }
  #elseif canImport(AppKit)
    /// Navigation a key command performs instead of editing the cell.
    fileprivate func navigation(for selector: Selector) -> TableNavigation? {
      switch selector {
      case #selector(NSResponder.insertTab(_:)): .nextCell
      case #selector(NSResponder.insertBacktab(_:)): .previousCell
      case #selector(NSResponder.insertNewline(_:)),
        #selector(NSResponder.insertLineBreak(_:)),
        #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
        .nextRow
      case #selector(NSResponder.moveUp(_:)): caretLines.isFirst ? .up : nil
      case #selector(NSResponder.moveDown(_:)): caretLines.isLast ? .down : nil
      case #selector(NSResponder.moveLeft(_:)): isCaretAtStart ? .left : nil
      case #selector(NSResponder.moveRight(_:)): isCaretAtEnd ? .right : nil
      default: nil
      }
    }

    /// Pasted text arrives as plain text. Line breaks become spaces when the
    /// cell is written back.
    override func paste(_ sender: Any?) {
      pasteAsPlainText(sender)
    }
  #endif
}

extension TableCellTextView: @preconcurrency NSTextStorageDelegate {
  func textStorage(
    _ textStorage: NSTextStorage, didProcessEditing editedMask: TextStorageEditActions,
    range editedRange: NSRange, changeInLength delta: Int
  ) {
    guard editedMask.contains(.editedCharacters) else { return }
    TableCellStyle.apply(to: textStorage, isHeader: isHeader, alignment: columnAlignment)
  }
}

// MARK: - Delegates

#if canImport(UIKit)
  extension TableWidgetView: UITextViewDelegate {
    func textView(
      _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
      guard let cell = textView as? TableCellTextView else { return true }
      switch text {
      case "\n":
        navigate(.nextRow, from: cell)
        return false
      case "\t":
        navigate(.nextCell, from: cell)
        return false
      default:
        return true
      }
    }

    func textViewDidChange(_ textView: UITextView) {
      guard let cell = textView as? TableCellTextView else { return }
      cellDidChange(cell)
    }

    func textView(
      _ textView: UITextView, editMenuForTextIn range: NSRange,
      suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
      guard let cell = textView as? TableCellTextView else { return nil }
      let position = cell.position
      let operations = TableOperation.available(forRow: position.row)
      let groups = Dictionary(grouping: operations, by: \.group).sorted { $0.key < $1.key }
      let menus = groups.map { _, operations in
        UIMenu(
          options: .displayInline,
          children: operations.map { operation in
            UIAction(
              title: operation.title,
              attributes: operation == .deleteTable ? .destructive : []
            ) { [weak self] _ in
              guard let self else { return }
              self.host?.tableWidget(self, perform: operation, at: position)
            }
          })
      }
      return UIMenu(children: suggestedActions + [UIMenu(title: "Table", children: menus)])
    }
  }
#elseif canImport(AppKit)
  extension TableWidgetView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
      guard let cell = notification.object as? TableCellTextView else { return }
      cellDidChange(cell)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      guard let cell = textView as? TableCellTextView,
        let navigation = cell.navigation(for: commandSelector)
      else { return false }
      navigate(navigation, from: cell)
      return true
    }

    func textView(
      _ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int
    ) -> NSMenu? {
      guard let cell = view as? TableCellTextView else { return menu }
      menuPosition = cell.position
      var index = 0
      var group: Int?
      for operation in TableOperation.available(forRow: cell.position.row) {
        if let group, group != operation.group {
          menu.insertItem(.separator(), at: index)
          index += 1
        }
        group = operation.group
        let item = NSMenuItem(
          title: operation.title, action: #selector(performTableOperation(_:)),
          keyEquivalent: "")
        item.target = self
        item.tag = operation.rawValue
        menu.insertItem(item, at: index)
        index += 1
      }
      menu.insertItem(.separator(), at: index)
      return menu
    }

    @objc private func performTableOperation(_ sender: NSMenuItem) {
      guard let operation = TableOperation(rawValue: sender.tag), let position = menuPosition
      else { return }
      host?.tableWidget(self, perform: operation, at: position)
    }
  }

  /// Horizontal scroll view that passes vertical scrolling to the editor.
  final class TableScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
      let fits = (documentView?.frame.width ?? 0) <= contentView.bounds.width
      if fits || abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
        nextResponder?.scrollWheel(with: event)
      } else {
        super.scrollWheel(with: event)
      }
    }
  }
#endif
