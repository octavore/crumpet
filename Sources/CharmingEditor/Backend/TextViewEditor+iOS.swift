#if canImport(UIKit)
  import SwiftUI
  import UIKit
  import UniformTypeIdentifiers

  extension TextViewEditor {
    func makeUIView(context: Context) -> UITextView {
      // The TextKit 1 stack, assembled by hand so the layout manager is ours:
      // `EditorLayoutManager` strokes the grid behind Markdown tables. Left to
      // itself a `UITextView` builds a TextKit 2 stack and only falls back to
      // TextKit 1 when something asks it for a `layoutManager`, which the
      // editor does (marker concealment is an `NSLayoutManagerDelegate`); this
      // makes the choice deliberate rather than a side effect of that access.
      let storage = NSTextStorage()
      let layoutManager = EditorLayoutManager()
      storage.addLayoutManager(layoutManager)
      let container = NSTextContainer(size: .zero)
      container.widthTracksTextView = true
      layoutManager.addTextContainer(container)
      context.coordinator.storage = storage

      let tv = EditorTextView(frame: .zero, textContainer: container)
      tv.delegate = context.coordinator
      tv.setEditorBackground(UIColor(syntaxColors.background))
      tv.alwaysBounceVertical = true
      tv.textContainerInset = UIEdgeInsets(
        top: EditorLayout.verticalInset, left: EditorLayout.minInset,
        bottom: EditorLayout.verticalInset, right: EditorLayout.minInset)
      // Native bold/italic/underline in the selection edit menu. Note:
      // attribute-only edits made there bypass textViewDidChange, so the
      // binding catches up on the next text change.
      tv.allowsEditingTextAttributes = true
      tv.typingAttributes = TextStyle.body.attributes
      // The highlighter is the storage's delegate: every character edit routes
      // through its didProcessEditing, the single trigger for restyling.
      tv.textStorage.delegate = context.coordinator.highlighter
      // The coordinator is also the layout manager's delegate: it conceals
      // markdown markers at glyph-generation time. See `MarkerConcealment`.
      tv.layoutManager.delegate = context.coordinator
      context.coordinator.textView = tv
      context.coordinator.observeKeyboard(for: tv)
      // Seed the applied face and size so the first updateUIView only restyles
      // if the saved typography differs from the typing attributes set above.
      Typography.current = fontFamily
      Typography.baseSize = fontSize
      Typography.titleRatio = titleRatio
      Typography.codeRatio = codeRatio
      Typography.lineHeightMultiple = lineHeightMultiple
      Typography.colorScheme = syntaxColors
      Typography.revealMode = markerRevealMode
      Typography.maxTextWidth = maxTextWidth
      context.coordinator.appliedFont = fontFamily
      context.coordinator.appliedSize = fontSize
      context.coordinator.appliedTitleRatio = titleRatio
      context.coordinator.appliedCodeRatio = codeRatio
      context.coordinator.appliedLineHeightMultiple = lineHeightMultiple
      context.coordinator.appliedColorScheme = syntaxColors
      context.coordinator.appliedRevealMode = markerRevealMode
      context.coordinator.appliedMaxTextWidth = maxTextWidth
      context.coordinator.attach(to: settingsChannel)
      return tv
    }

    // Always called on the main thread; `assumeIsolated` because the protocol
    // requirement itself isn't isolated to it.
    static func dismantleUIView(_ tv: UITextView, coordinator: Coordinator) {
      MainActor.assumeIsolated { coordinator.dismantle() }
    }

    func updateUIView(_ tv: UITextView, context: Context) {
      context.coordinator.onScroll = onScroll
      context.coordinator.attach(to: settingsChannel)
      if abs(tv.contentInset.top - topContentInset) > 0.5 {
        tv.contentInset.top = topContentInset
        tv.verticalScrollIndicatorInsets.top = topContentInset
      }
      // A typeface change restyles the document in place; it doesn't touch the
      // Markdown source, so the text sync below still runs and finds no diff.
      context.coordinator.applyFont(
        fontFamily, size: fontSize, titleRatio: titleRatio, codeRatio: codeRatio,
        lineHeightMultiple: lineHeightMultiple, colorScheme: syntaxColors)
      context.coordinator.applyRevealMode(markerRevealMode)
      context.coordinator.applyMaxTextWidth(maxTextWidth)
      // While the text view is the live source of truth (typing in flight, its
      // binding sync still pending), don't feed the stale binding back into it.
      if context.coordinator.isSyncingFromTextView { return }
      context.coordinator.applyExternalText(text, to: tv.textStorage, in: tv)
    }
  }

  extension TextViewEditor.Coordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
      // The storage delegate has already restyled the text; coalesce the costly
      // binding conversion so it runs once typing settles, not per keystroke.
      scheduleBindingSync()
    }

    /// Intercept Return to continue a list. When we handle it ourselves (marker
    /// inserted or dropped), suppress the text view's own newline.
    func textView(
      _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
      guard text == "\n" else { return true }
      return !handleListNewline()
    }

    /// A caret move with no text edit (arrow keys, a tap) needs an explicit
    /// glyph invalidation to reveal or re-conceal nearby markers; an edit
    /// already gets one for free from `NSTextStorage`'s own edit-processing.
    func textViewDidChangeSelection(_ textView: UITextView) {
      // A table's hidden `|---|` row is laid out as a hairline, so a caret
      // landing there looks like a move that did nothing. UIKit has no
      // "will change" hook to redirect it in, so correct it afterwards; the
      // correction re-enters here once, and the corrected position isn't on a
      // hidden row, so it settles immediately.
      if let skipped = caretSkippingHiddenRow(from: lastSelectedRange, to: textView.selectedRange) {
        textView.selectedRange = skipped
        return
      }
      let new = textView.selectedRange
      invalidateConcealment(from: lastSelectedRange, to: new)
      lastSelectedRange = new
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      onScroll?(max(0, scrollView.contentOffset.y + scrollView.adjustedContentInset.top))
    }

    func observeKeyboard(for tv: UITextView) {
      let center = NotificationCenter.default
      observerTokens.append(
        center.addObserver(
          forName: UIResponder.keyboardWillChangeFrameNotification,
          object: nil, queue: .main
        ) { [weak tv] note in
          guard let tv,
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
            let window = tv.window
          else { return }
          // Convert keyboard frame to the text view's coordinate space so
          // the inset is correct regardless of safe-area or split-screen layout.
          let keyboardInView = tv.convert(frame, from: window.screen.coordinateSpace)
          let overlap = max(0, tv.bounds.maxY - keyboardInView.minY)
          tv.contentInset.bottom = overlap
          tv.verticalScrollIndicatorInsets.bottom = overlap
          tv.scrollRangeToVisible(tv.selectedRange)
        })
      observerTokens.append(
        center.addObserver(
          forName: UIResponder.keyboardWillHideNotification,
          object: nil, queue: .main
        ) { [weak tv] _ in
          tv?.contentInset.bottom = 0
          tv?.verticalScrollIndicatorInsets.bottom = 0
        })
    }
  }

  /// A `UITextView` that normalizes pasted rich text into the editor's type
  /// system instead of dumping in foreign fonts and attachments, keeps the
  /// text in a centered, readable column on wide (iPad) layouts, and opts out
  /// of intrinsic content sizing so SwiftUI lets it scroll.
  final class EditorTextView: UITextView {
    override var intrinsicContentSize: CGSize {
      CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      updateTextContainerInset()
    }

    /// Recomputes the centering inset from the current width and
    /// `Typography.maxTextWidth`. Called on every layout pass, and once more
    /// by `Coordinator.applyMaxTextWidth` when the max width itself changes
    /// without a layout pass behind it (e.g. a live settings change).
    func updateTextContainerInset() {
      let inset = max(EditorLayout.minInset, (bounds.width - Typography.maxTextWidth) / 2)
      if abs(textContainerInset.left - inset) > 0.5 {
        textContainerInset = UIEdgeInsets(
          top: EditorLayout.verticalInset, left: inset,
          bottom: EditorLayout.verticalInset, right: inset)
      }
    }

    override func paste(_ sender: Any?) {
      guard let pasted = UIPasteboard.general.editorAttributedString() else {
        super.paste(sender)
        return
      }
      let clean = TextStyle.sanitize(pasted: pasted)
      let range = selectedRange
      textStorage.replaceCharacters(in: range, with: clean)
      selectedRange = NSRange(location: range.location + clean.length, length: 0)
      delegate?.textViewDidChange?(self)
    }
  }

  extension UIPasteboard {
    /// Best available attributed representation of the pasteboard: RTF when
    /// present (attachments are stripped downstream), else plain text.
    fileprivate func editorAttributedString() -> NSAttributedString? {
      if let data = data(forPasteboardType: UTType.rtf.identifier),
        let attr = try? NSAttributedString(
          data: data,
          options: [.documentType: NSAttributedString.DocumentType.rtf],
          documentAttributes: nil)
      {
        return attr
      }
      return string.map { NSAttributedString(string: $0) }
    }
  }
#endif
