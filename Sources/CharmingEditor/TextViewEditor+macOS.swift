#if canImport(AppKit)
  import SwiftUI
  import AppKit

  extension TextViewEditor {
    func makeNSView(context: Context) -> NSScrollView {
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true
      scroll.drawsBackground = false
      scroll.borderType = .noBorder

      let tv = EditorTextView(frame: .zero)
      tv.delegate = context.coordinator
      tv.isRichText = true
      tv.allowsUndo = true
      tv.drawsBackground = false
      tv.textContainerInset = NSSize(
        width: EditorLayout.minInset, height: EditorLayout.verticalInset)
      tv.typingAttributes = TextStyle.body.attributes
      tv.isVerticallyResizable = true
      tv.isHorizontallyResizable = false
      tv.autoresizingMask = [.width]
      tv.minSize = NSSize(width: 0, height: 0)
      tv.maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      tv.textContainer?.widthTracksTextView = true

      // The highlighter is the storage's delegate: every character edit (typing,
      // paste, programmatic replacement) routes through its didProcessEditing,
      // which is the single trigger for incremental restyling.
      tv.textStorage?.delegate = context.coordinator.highlighter

      scroll.documentView = tv
      context.coordinator.textView = tv
      // Seed the applied face and size so the first updateNSView only restyles
      // if the saved typography differs from the typing attributes set above.
      Typography.current = fontFamily
      Typography.baseSize = fontSize
      context.coordinator.appliedFont = fontFamily
      context.coordinator.appliedSize = fontSize
      return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
      // Switch typeface first; if it changed, the document was just restyled and
      // the binding resynced, so skip the storage rebuild below.
      if context.coordinator.applyFont(fontFamily, size: fontSize) { return }
      // While the text view is the live source of truth (typing in flight, its
      // binding sync still pending), don't rebuild the storage from the binding.
      if context.coordinator.isSyncingFromTextView { return }
      guard let tv = scroll.documentView as? NSTextView,
        let storage = tv.textStorage
      else { return }
      let desired = NSAttributedString(text)
      guard storage != desired else { return }
      let selected = tv.selectedRanges
      // Replacing the storage fires the highlighter's didProcessEditing, which
      // restyles the whole document; no explicit highlight call needed.
      storage.setAttributedString(desired)
      tv.selectedRanges = selected
    }
  }

  extension TextViewEditor.Coordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
      // The storage delegate has already restyled the text; coalesce the costly
      // binding conversion so it runs once typing settles, not per keystroke.
      scheduleBindingSync()
    }

    /// Intercept Return to continue a list. `insertNewline:` is plain Return only;
    /// Shift-Return maps to `insertLineBreak:`, so a soft break still falls through
    /// to the default and doesn't spawn a marker.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        return handleListNewline()
      }
      return false
    }
  }

  /// An `NSTextView` that normalizes pasted rich text into the editor's type
  /// system instead of dumping in foreign fonts and attachments, and keeps the
  /// text in a centered, readable column while filling the scroll view.
  final class EditorTextView: NSTextView {
    // Above the column width only the centering inset changes, not the text
    // layout. Without this, the view blits its cached bitmap during a live
    // resize and only re-centers once resizing stops; opting out forces a
    // continuous redraw so the column tracks the window smoothly.
    override var preservesContentDuringLiveResize: Bool { false }

    // The superview drives this on every live-resize step, unlike
    // `setFrameSize`, which coalesces and only lands once resizing stops.
    // Overriding here keeps the centered column tracking the window edge.
    override func resize(withOldSuperviewSize oldSize: NSSize) {
      super.resize(withOldSuperviewSize: oldSize)
      let inset = max(EditorLayout.minInset, (bounds.width - EditorLayout.maxTextWidth) / 2)
      if abs(textContainerInset.width - inset) > 0.5 {
        textContainerInset = NSSize(width: inset, height: EditorLayout.verticalInset)
      }
    }

    override func paste(_ sender: Any?) {
      guard
        let pasted = NSPasteboard.general.readObjects(
          forClasses: [NSAttributedString.self], options: nil)?.first
          as? NSAttributedString
      else {
        super.paste(sender)
        return
      }
      let clean = TextStyle.sanitize(pasted: pasted)
      // insertText routes through undo and fires textDidChange, syncing
      // the binding, just like the user typing the text.
      insertText(clean, replacementRange: selectedRange())
    }
  }
#endif
