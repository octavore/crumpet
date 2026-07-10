import SwiftUI

/// Geometry shared by both platform backends: the text sits in a centered
/// column at most `maxTextWidth` wide, with `minInset` of breathing room on
/// narrow views, while the scroll view itself spans the whole window.
enum EditorLayout {
  static let maxTextWidth: CGFloat = 720
  static let minInset: CGFloat = 16
  static let verticalInset: CGFloat = 24
}

/// The AppKit/UIKit-backed editor behind the public `MarkdownEditor` view.
struct TextViewEditor: PlatformViewRepresentable {
  @Binding var text: AttributedString
  let commands: EditorCommands

  /// The user-selected typeface and body size. Set by `MarkdownEditor` after
  /// construction; the `init(text:commands:)` leaves them at the defaults.
  var fontFamily: EditorFont = .system
  var fontSize: CGFloat = Typography.defaultBaseSize

  init(text: Binding<AttributedString>, commands: EditorCommands) {
    self._text = text
    self.commands = commands
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text, commands: commands) }

  @MainActor
  final class Coordinator: NSObject {
    @Binding var text: AttributedString
    weak var textView: PlatformTextView?

    // The typeface and size currently applied to the text view, so a no-op
    // `updateXxxView` (the common case) doesn't needlessly restyle the document.
    var appliedFont: EditorFont?
    var appliedSize: CGFloat?

    // Derives formatting from the text as Markdown on every change.
    let highlighter = MarkdownHighlighter()

    // Converting the whole document to an `AttributedString` for the binding is
    // O(n); on a large document that dominated per-keystroke latency. Typing
    // mutates the text view's storage (the live source of truth) and restyles
    // synchronously, so we coalesce the binding write to fire once after typing
    // pauses instead of on every keystroke.
    private var bindingSyncTask: Task<Void, Never>?

    // True from a text-view edit until its debounced binding sync completes, so
    // updateXxxView won't rebuild the storage from the (stale) binding and
    // clobber in-progress typing.
    var isSyncingFromTextView = false

    // Block-based NotificationCenter tokens (iOS keyboard observers) to
    // unregister when the coordinator goes away. Empty on macOS. Mutated
    // only on the main actor; read once from the nonisolated deinit.
    nonisolated(unsafe) var observerTokens: [NSObjectProtocol] = []

    init(text: Binding<AttributedString>, commands: EditorCommands) {
      self._text = text
      super.init()
      commands.handler = { [weak self] in self?.handle($0) }
    }

    deinit {
      observerTokens.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Typeface

    /// Switches the editor to `family` at `size` if either isn't already active:
    /// updates the global typography state, restyles the document so every block
    /// picks up the new face/scale, and resets the typing attributes to match.
    /// No-op if nothing changed. Returns whether it made a change, so the caller
    /// can skip the rest of its update pass, which would otherwise rebuild the
    /// storage from the binding's now-stale fonts.
    @discardableResult
    func applyFont(_ family: EditorFont, size: CGFloat) -> Bool {
      guard appliedFont != family || appliedSize != size else { return false }
      appliedFont = family
      appliedSize = size
      Typography.current = family
      Typography.baseSize = size
      guard let tv = textView, let storage = tv.optionalTextStorage else { return false }
      tv.typingAttributes = TextStyle.body.attributes
      highlighter.highlight(storage)
      // Push the restyled fonts up so the binding matches the storage again.
      text = AttributedString(storage)
      return true
    }

    // MARK: Binding sync

    /// Coalesces the expensive binding write. Called on every text-view change;
    /// the actual `AttributedString` conversion runs once typing settles.
    func scheduleBindingSync() {
      isSyncingFromTextView = true
      bindingSyncTask?.cancel()
      bindingSyncTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        self?.flushBindingSync()
      }
    }

    /// Pushes the text view's current content up through the binding now,
    /// cancelling any pending debounced sync. Harmless when nothing is pending.
    func flushBindingSync() {
      bindingSyncTask?.cancel()
      bindingSyncTask = nil
      defer { isSyncingFromTextView = false }
      guard let storage = textView?.optionalTextStorage else { return }
      text = AttributedString(storage)
    }

    private func handle(_ command: EditorCommand) {
      switch command {
      case .toggleBold: toggleInlineMarker("**")
      case .toggleItalic: toggleInlineMarker("*")
      case .setBlockStyle(let style): applyBlockPrefix(style)
      }
    }

    // MARK: Inline markers

    /// Wraps the selection in `marker` on both sides, or removes the markers
    /// if the selection is already wrapped. With no selection, inserts the
    /// marker pair and places the cursor between them.
    private func toggleInlineMarker(_ marker: String) {
      guard let tv = textView, let storage = tv.optionalTextStorage else { return }
      let sel = tv.selectedRange
      let str = storage.mutableString
      let mLen = (marker as NSString).length

      guard sel.length > 0 else {
        // Caret: place a marker pair and put the cursor between them.
        replaceText(marker + marker, in: sel,
                    thenSelect: NSRange(location: sel.location + mLen, length: 0))
        return
      }

      // Markers just outside the selection: remove them.
      if sel.location >= mLen, sel.location + sel.length + mLen <= str.length {
        let before = str.substring(with: NSRange(location: sel.location - mLen, length: mLen))
        let after = str.substring(with: NSRange(location: sel.location + sel.length, length: mLen))
        if before == marker && after == marker {
          let inner = str.substring(with: sel)
          let outerRange = NSRange(location: sel.location - mLen, length: sel.length + mLen * 2)
          replaceText(inner, in: outerRange,
                      thenSelect: NSRange(location: sel.location - mLen, length: sel.length))
          return
        }
      }

      // Markers inside the selection: remove them.
      if sel.length >= mLen * 2 {
        let selectedStr = str.substring(with: sel)
        if selectedStr.hasPrefix(marker) && selectedStr.hasSuffix(marker) {
          let innerLen = sel.length - mLen * 2
          let inner = (selectedStr as NSString).substring(with: NSRange(location: mLen, length: innerLen))
          replaceText(inner, in: sel, thenSelect: NSRange(location: sel.location, length: innerLen))
          return
        }
      }

      // Wrap the selection.
      let selectedStr = str.substring(with: sel)
      replaceText("\(marker)\(selectedStr)\(marker)", in: sel,
                  thenSelect: NSRange(location: sel.location + mLen, length: sel.length))
    }

    // MARK: Block prefixes

    /// Replaces the heading prefix on the current paragraph with the one for
    /// `style` (e.g. `# ` for title, `## ` for heading, none for body).
    private func applyBlockPrefix(_ style: TextStyle) {
      guard let tv = textView, let storage = tv.optionalTextStorage else { return }
      let str = storage.mutableString
      let sel = tv.selectedRange
      let paraStart = str.paragraphRange(for: sel).location

      // Strip any existing heading prefix (longest first to avoid partial matches).
      let knownPrefixes = ["## ", "# "]
      var existingLen = 0
      for prefix in knownPrefixes {
        let pLen = (prefix as NSString).length
        guard paraStart + pLen <= str.length else { continue }
        if str.substring(with: NSRange(location: paraStart, length: pLen)) == prefix {
          existingLen = pLen
          break
        }
      }

      let newPrefix = style.markdownPrefix
      let newPrefixLen = (newPrefix as NSString).length
      let replacementRange = NSRange(location: paraStart, length: existingLen)

      // Keep the cursor in the content, not stranded inside the removed prefix.
      let delta = newPrefixLen - existingLen
      let adjustedSel: NSRange = {
        guard sel.location > paraStart + existingLen else {
          return NSRange(location: paraStart + newPrefixLen, length: 0)
        }
        return NSRange(location: sel.location + delta, length: sel.length)
      }()

      replaceText(newPrefix, in: replacementRange, thenSelect: adjustedSel)
    }

    // MARK: Plumbing

    /// Replaces raw text in the storage with full undo support and binding sync.
    private func replaceText(_ string: String, in range: NSRange, thenSelect selectRange: NSRange) {
      guard let tv = textView, let storage = tv.optionalTextStorage else { return }
      #if canImport(AppKit)
        guard tv.shouldChangeText(in: range, replacementString: string) else { return }
      #endif
      storage.beginEditing()
      storage.replaceCharacters(in: range, with: string)
      storage.endEditing()
      #if canImport(AppKit)
        tv.setSelectedRange(selectRange)
        tv.didChangeText()
      #else
        tv.selectedRange = selectRange
        scheduleBindingSync()
      #endif
    }
  }
}
