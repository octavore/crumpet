import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Places a ``TableWidgetView`` over each concealed table and writes cell
/// edits back to the Markdown source.
///
/// The widgets are subviews of the editor text view. They are matched to
/// tables by document order and reused across reparses, so a focused cell
/// keeps focus while the table source under it changes.
extension TextViewEditor.Coordinator: TableWidgetHost {
  // MARK: Placement

  /// Places the widgets on the next main loop pass. Called after every
  /// layout pass.
  func scheduleTableSync() {
    guard !tableSyncScheduled, Typography.tablesEnabled || !tableWidgets.isEmpty else { return }
    tableSyncScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated { self?.syncTables() }
    }
  }

  /// Creates, updates, places, and removes widgets to match the tables in
  /// the text.
  func syncTables() {
    tableSyncScheduled = false
    guard let tv = textView, let storage = tv.optionalTextStorage,
      let layoutManager = tv.editorLayoutManager,
      let container = layoutManager.textContainers.first
    else { return }

    var models: [TableModel] = []
    if storage.length > 0 {
      storage.enumerateAttribute(
        .tableModel, in: NSRange(location: 0, length: storage.length),
        options: .longestEffectiveRangeNotRequired
      ) { value, _, _ in
        guard let model = value as? TableModel, model !== models.last,
          NSMaxRange(model.range) <= storage.length,
          storage.attribute(.tableModel, at: model.range.location, effectiveRange: nil)
            as? TableModel === model,
          !isTableRaw(model)
        else { return }
        models.append(model)
      }
    }

    while tableWidgets.count > models.count {
      tableWidgets.removeLast().removeFromSuperview()
    }
    let padding = container.lineFragmentPadding
    let available = container.size.width - 2 * padding
    let origin = tv.editorTextContainerOrigin
    for (index, model) in models.enumerated() {
      let geometry = model.geometry(maxWidth: available)
      let widget: TableWidgetView
      if index < tableWidgets.count {
        widget = tableWidgets[index]
        widget.update(model: model, geometry: geometry)
      } else {
        widget = TableWidgetView(model: model, geometry: geometry, host: self)
        tv.addSubview(widget)
        tableWidgets.append(widget)
      }
      let glyph = layoutManager.glyphIndexForCharacter(at: model.range.location)
      let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let frame = CGRect(
        origin: CGPoint(
          x: origin.x + fragment.minX + padding,
          y: origin.y + fragment.minY + TableGeometry.margin),
        size: geometry.frameSize(maxWidth: available))
      if widget.frame != frame { widget.frame = frame }
    }
  }

  /// Frame of the focused table cell in the editor text view, or nil if no
  /// cell has focus.
  var focusedTableCellFrame: CGRect? {
    for widget in tableWidgets {
      if let cell = widget.focusedCell {
        return widget.convert(widget.frame(of: cell), to: widget.superview)
      }
    }
    return nil
  }

  // MARK: Caret

  /// Moves focus into a table if a caret move lands in its concealed source.
  /// A caret arriving from above enters the first cell. Any other caret
  /// enters the first cell of the last row. Returns true if focus moves, in
  /// which case the editor caret should stay where it was. Only a caret the
  /// user moves in the focused editor is redirected.
  func redirectCaretIntoTable(from old: NSRange, to new: NSRange) -> Bool {
    guard !isApplyingTableEdit, new.length == 0, let tv = textView,
      let storage = tv.optionalTextStorage
    else { return false }
    #if canImport(UIKit)
      guard tv.isFirstResponder else { return false }
    #elseif canImport(AppKit)
      guard tv.window?.firstResponder === tv else { return false }
    #endif
    if let undo = tv.undoManager, undo.isUndoing || undo.isRedoing { return false }
    guard let model = storage.tableModel(around: new.location), !isTableRaw(model),
      let widget = tableWidgets.first(where: { $0.model === model })
    else { return false }
    let fromAbove = old.location < model.range.location
    let target = TableCellPosition(row: fromAbove ? 0 : model.rows.count - 1, column: 0)
    DispatchQueue.main.async { [weak widget] in
      MainActor.assumeIsolated { widget?.focus(target, atEnd: false) }
    }
    return true
  }

  // MARK: Markdown source

  /// Whether `table` shows as Markdown source instead of a widget. Every
  /// table does in `MarkerRevealMode.always`. In other modes only the table
  /// chosen with "Edit as Markdown" does.
  func isTableRaw(_ table: TableModel) -> Bool {
    Typography.revealMode == .always || table.range.location == rawTableStart
  }

  /// Shows `model` as Markdown source with the editor caret at the end of the
  /// cell at `position`.
  private func showTableSource(_ model: TableModel, at position: TableCellPosition) {
    rawTableStart = model.range.location
    invalidateTableLayout(model.range)
    syncTables()
    var caret = NSMaxRange(model.range)
    if position.row < model.rows.count {
      let row = model.rows[position.row]
      caret =
        position.column < row.cells.count
        ? NSMaxRange(row.cells[position.column].range) : NSMaxRange(row.line)
    }
    focusEditor(at: caret)
  }

  /// Returns the table shown as source to a widget if `selection` has left
  /// it, or if it is no longer a table. Called on every selection change.
  func updateRawTable(for selection: NSRange) {
    guard let start = rawTableStart, let storage = textView?.optionalTextStorage else { return }
    let model =
      start < storage.length
      ? storage.attribute(.tableModel, at: start, effectiveRange: nil) as? TableModel : nil
    if let model, model.range.location == start, selection.location >= start,
      NSMaxRange(selection) <= NSMaxRange(model.range)
    {
      return
    }
    rawTableStart = nil
    if let model { invalidateTableLayout(model.range) }
    scheduleTableSync()
  }

  /// Regenerates glyphs and layout for the lines of `range`, after a table
  /// switches between source and widget.
  private func invalidateTableLayout(_ range: NSRange) {
    guard let tv = textView, let storage = tv.optionalTextStorage,
      NSMaxRange(range) <= storage.length
    else { return }
    let lines = storage.mutableString.paragraphRange(for: range)
    storage.beginEditing()
    storage.edited(.editedAttributes, range: lines, changeInLength: 0)
    storage.endEditing()
    tv.refreshEditorDisplay()
  }

  // MARK: TableWidgetHost

  func tableWidget(
    _ widget: TableWidgetView, didEditCellAt position: TableCellPosition, text: String
  ) {
    let model = widget.model
    guard position.row < model.rows.count else { return }
    let row = model.rows[position.row]
    if position.column < row.cells.count {
      replaceTableSource(row.cells[position.column].range, with: TableModel.escaped(text))
    } else {
      // A short row gets its missing cells written out.
      var texts = (0..<model.columnCount).map { model.text(row: position.row, column: $0) }
      texts[position.column] = text
      let line = "| " + texts.map(TableModel.escaped).joined(separator: " | ") + " |"
      replaceTableSource(row.line, with: line)
    }
    syncTables()
  }

  func tableWidget(
    _ widget: TableWidgetView, navigate navigation: TableNavigation,
    from position: TableCellPosition
  ) {
    let model = widget.model
    let lastRow = model.rows.count - 1
    let lastColumn = model.columnCount - 1
    let row = position.row
    let column = position.column
    switch navigation {
    case .nextCell:
      if column < lastColumn {
        widget.focus(TableCellPosition(row: row, column: column + 1), atEnd: true)
      } else if row < lastRow {
        widget.focus(TableCellPosition(row: row + 1, column: 0), atEnd: true)
      } else {
        tableWidget(widget, perform: .insertRowBelow, at: TableCellPosition(row: row, column: 0))
      }
    case .previousCell:
      if column > 0 {
        widget.focus(TableCellPosition(row: row, column: column - 1), atEnd: true)
      } else if row > 0 {
        widget.focus(TableCellPosition(row: row - 1, column: lastColumn), atEnd: true)
      }
    case .nextRow:
      if row < lastRow {
        widget.focus(TableCellPosition(row: row + 1, column: column), atEnd: true)
      } else {
        tableWidget(widget, perform: .insertRowBelow, at: position)
      }
    case .up:
      if row > 0 {
        widget.focus(TableCellPosition(row: row - 1, column: column), atEnd: true)
      } else {
        exitTable(model, before: true)
      }
    case .down:
      if row < lastRow {
        widget.focus(TableCellPosition(row: row + 1, column: column), atEnd: false)
      } else {
        exitTable(model, before: false)
      }
    case .left:
      if column > 0 {
        widget.focus(TableCellPosition(row: row, column: column - 1), atEnd: true)
      } else if row > 0 {
        widget.focus(TableCellPosition(row: row - 1, column: lastColumn), atEnd: true)
      } else {
        exitTable(model, before: true)
      }
    case .right:
      if column < lastColumn {
        widget.focus(TableCellPosition(row: row, column: column + 1), atEnd: false)
      } else if row < lastRow {
        widget.focus(TableCellPosition(row: row + 1, column: 0), atEnd: false)
      } else {
        exitTable(model, before: false)
      }
    }
  }

  func tableWidget(
    _ widget: TableWidgetView, perform operation: TableOperation, at position: TableCellPosition
  ) {
    let model = widget.model
    var grid = model.grid
    var alignments = model.alignments
    let row = min(position.row, grid.count - 1)
    let column = min(position.column, alignments.count - 1)
    let blank = Array(repeating: "", count: alignments.count)
    var focus = TableCellPosition(row: row, column: column)

    switch operation {
    case .editMarkdown:
      showTableSource(model, at: position)
      return
    case .insertRowAbove:
      guard row > 0 else { return }
      grid.insert(blank, at: row)
    case .insertRowBelow:
      grid.insert(blank, at: row + 1)
      focus.row = row + 1
    case .insertColumnLeft:
      for index in grid.indices { grid[index].insert("", at: column) }
      alignments.insert(.none, at: column)
    case .insertColumnRight:
      for index in grid.indices { grid[index].insert("", at: column + 1) }
      alignments.insert(.none, at: column + 1)
      focus.column = column + 1
    case .deleteRow:
      guard row > 0 else { return }
      grid.remove(at: row)
      focus.row = min(row, grid.count - 1)
    case .deleteColumn:
      guard alignments.count > 1 else {
        deleteTable(model)
        return
      }
      for index in grid.indices { grid[index].remove(at: column) }
      alignments.remove(at: column)
      focus.column = min(column, alignments.count - 1)
    case .alignLeft:
      alignments[column] = .left
    case .alignCenter:
      alignments[column] = .center
    case .alignRight:
      alignments[column] = .right
    case .deleteTable:
      deleteTable(model)
      return
    }

    let start = model.range.location
    replaceTableSource(
      model.range, with: TableModel.markdown(cells: grid, alignments: alignments))
    syncTables()
    tableWidgets.first { $0.model.range.location == start }?.focus(focus, atEnd: true)
  }

  // MARK: Editing

  /// Removes a table and its line break, and puts the editor caret where it
  /// was.
  private func deleteTable(_ model: TableModel) {
    guard let storage = textView?.optionalTextStorage else { return }
    var range = model.range
    if NSMaxRange(range) < storage.length,
      storage.mutableString.character(at: NSMaxRange(range)) == 0x0A
    {
      range.length += 1
    }
    replaceTableSource(range, with: "")
    syncTables()
    focusEditor(at: model.range.location)
  }

  /// Moves focus from a table to the editor line above or below it. A table
  /// at the start or end of the document gets an empty line to move to.
  private func exitTable(_ model: TableModel, before: Bool) {
    guard let storage = textView?.optionalTextStorage else { return }
    if before {
      if model.range.location > 0 {
        focusEditor(at: model.range.location - 1)
      } else {
        replaceTableSource(NSRange(location: 0, length: 0), with: "\n")
        syncTables()
        focusEditor(at: 0)
      }
    } else {
      let end = NSMaxRange(model.range)
      if end >= storage.length {
        replaceTableSource(NSRange(location: end, length: 0), with: "\n")
        syncTables()
      }
      focusEditor(at: end + 1)
    }
  }

  /// Gives the editor text view focus with the caret at `location`.
  private func focusEditor(at location: Int) {
    guard let tv = textView, let storage = tv.optionalTextStorage else { return }
    let caret = NSRange(location: min(max(0, location), storage.length), length: 0)
    #if canImport(UIKit)
      tv.becomeFirstResponder()
    #elseif canImport(AppKit)
      tv.window?.makeFirstResponder(tv)
    #endif
    tv.setEditorSelectedRange(caret)
  }

  /// Replaces table source in the editor storage with undo support and
  /// binding sync. The editor selection is kept, shifted past the edit.
  private func replaceTableSource(_ range: NSRange, with string: String) {
    guard let tv = textView, let storage = tv.optionalTextStorage,
      NSMaxRange(range) <= storage.length
    else { return }
    isApplyingTableEdit = true
    defer { isApplyingTableEdit = false }
    let selection = tv.editorSelectedRange
    #if canImport(AppKit)
      guard tv.shouldChangeText(in: range, replacementString: string) else { return }
    #endif
    storage.beginEditing()
    storage.replaceCharacters(in: range, with: string)
    storage.endEditing()

    let delta = (string as NSString).length - range.length
    var kept = selection
    if selection.location >= NSMaxRange(range) {
      kept.location += delta
    } else if NSMaxRange(selection) > range.location {
      kept = NSRange(location: min(selection.location, range.location), length: 0)
    }
    kept.location = min(kept.location, storage.length)
    kept.length = min(kept.length, storage.length - kept.location)
    tv.setEditorSelectedRange(kept)
    #if canImport(AppKit)
      tv.didChangeText()
    #else
      scheduleBindingSync()
    #endif
  }
}

extension TextViewEditor.Coordinator {
  /// Places the table widgets after the layout changes.
  func layoutManager(
    _ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?,
    atEnd layoutFinishedFlag: Bool
  ) {
    scheduleTableSync()
  }
}

extension PlatformTextView {
  // NSTextView.layoutManager is optional; UITextView.layoutManager is not.
  var editorLayoutManager: NSLayoutManager? { layoutManager }

  /// Text container origin in the text view.
  var editorTextContainerOrigin: CGPoint {
    #if canImport(UIKit)
      CGPoint(x: textContainerInset.left, y: textContainerInset.top)
    #elseif canImport(AppKit)
      textContainerOrigin
    #endif
  }
}
