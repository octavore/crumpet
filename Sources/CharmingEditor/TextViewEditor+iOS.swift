#if canImport(UIKit)
  import SwiftUI
  import UIKit
  import UniformTypeIdentifiers

  extension TextViewEditor {
    func makeUIView(context: Context) -> UITextView {
      let tv = EditorTextView()
      tv.delegate = context.coordinator
      tv.backgroundColor = .clear
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
      context.coordinator.textView = tv
      context.coordinator.observeKeyboard(for: tv)
      // Seed the applied face and size so the first updateUIView only restyles
      // if the saved typography differs from the typing attributes set above.
      Typography.current = fontFamily
      Typography.baseSize = fontSize
      context.coordinator.appliedFont = fontFamily
      context.coordinator.appliedSize = fontSize
      return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
      // Switch typeface first; if it changed, the document was just restyled and
      // the binding resynced, so skip the storage rebuild below.
      if context.coordinator.applyFont(fontFamily, size: fontSize) { return }
      // While the text view is the live source of truth (typing in flight, its
      // binding sync still pending), don't rebuild the storage from the binding.
      if context.coordinator.isSyncingFromTextView { return }
      let desired = NSAttributedString(text)
      guard tv.attributedText != desired else { return }
      let selected = tv.selectedRange
      tv.attributedText = desired
      context.coordinator.highlighter.highlight(tv.textStorage)
      tv.selectedRange = selected
    }
  }

  extension TextViewEditor.Coordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
      // The storage delegate has already restyled the text; coalesce the costly
      // binding conversion so it runs once typing settles, not per keystroke.
      scheduleBindingSync()
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
      let inset = max(EditorLayout.minInset, (bounds.width - EditorLayout.maxTextWidth) / 2)
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
