import SwiftUI

/// Geometry shared by both platform backends: the text sits in a centered
/// column at most `Typography.maxTextWidth` wide, with `minInset` of
/// breathing room on narrow views, while the scroll view itself spans the
/// whole window.
enum EditorLayout {
  static let minInset: CGFloat = 16
  static let verticalInset: CGFloat = 24
}

/// The smallest single replacement that turns one string into another, found by
/// trimming the longest common prefix and suffix. Used to fold a change that
/// arrived through the binding into the text view as an ordinary edit, so it
/// costs what the edit is worth rather than what the document is worth.
enum TextDiff {
  struct Edit: Equatable {
    /// The range of the *current* text to replace.
    let replaced: NSRange
    /// The text to put there.
    let replacement: String
  }

  /// Nil when the two strings are already equal, so callers can treat "no diff"
  /// as "nothing to do" without touching the storage at all. That's the common
  /// case, since most update passes re-deliver text the editor itself just
  /// published.
  static func between(_ current: NSString, and new: NSString) -> Edit? {
    guard !current.isEqual(to: new as String) else { return nil }

    let shorter = min(current.length, new.length)
    var prefix = 0
    while prefix < shorter, current.character(at: prefix) == new.character(at: prefix) {
      prefix += 1
    }
    // Never cut a surrogate pair in half: back off onto the lead unit, so the
    // replaced range spans whole characters and the UTF-16 byte offsets the
    // highlighter hands tree-sitter stay on character boundaries.
    if prefix > 0, UTF16.isLeadSurrogate(current.character(at: prefix - 1)) { prefix -= 1 }

    var suffix = 0
    let maxSuffix = shorter - prefix
    while suffix < maxSuffix,
      current.character(at: current.length - 1 - suffix)
        == new.character(at: new.length - 1 - suffix)
    {
      suffix += 1
    }
    if suffix > 0, UTF16.isTrailSurrogate(current.character(at: current.length - suffix)) {
      suffix -= 1
    }

    return Edit(
      replaced: NSRange(location: prefix, length: current.length - prefix - suffix),
      replacement: new.substring(
        with: NSRange(location: prefix, length: new.length - prefix - suffix)))
  }
}

/// The AppKit/UIKit-backed editor behind the public `MarkdownEditor` view.
struct TextViewEditor: PlatformViewRepresentable {
  @Binding var text: String
  let commands: EditorCommands

  /// The user-selected typeface and body size. Set by `MarkdownEditor` after
  /// construction; the `init(text:commands:)` leaves them at the defaults.
  var fontFamily: EditorFont = .system
  var fontSize: CGFloat = Typography.defaultBaseSize
  var titleRatio: CGFloat = Typography.defaultTitleRatio
  var codeRatio: CGFloat = Typography.defaultCodeRatio
  var lineHeightMultiple: CGFloat = Typography.defaultLineHeightMultiple
  var markerRevealMode: MarkerRevealMode = .span
  var tablesEnabled: Bool = Typography.defaultTablesEnabled
  var listBulletStyle: ListBulletStyle = Typography.defaultListBulletStyle
  var maxTextWidth: CGFloat = Typography.defaultMaxTextWidth
  // Named to avoid colliding with `View.colorScheme(_:)`, SwiftUI's own
  // environment-scheme modifier (`TextViewEditor` conforms to `View` via
  // `PlatformViewRepresentable`).
  var syntaxColors: EditorColorScheme = .standard
  /// Called with the vertical scroll offset (0 at the top, increasing
  /// downward) whenever the document scrolls, so a host app can e.g. fade out
  /// its own chrome as the user scrolls into the document.
  var onScroll: ((CGFloat) -> Void)?
  /// Blank space held above the document's first line, inside the scroll view
  /// rather than around it, so content scrolls up under a host-supplied
  /// overlay bar of this height instead of stopping short of it.
  var topContentInset: CGFloat = 0
  /// Applies settings without waiting for a SwiftUI update, for a change this
  /// view would otherwise receive late. See ``EditorSettingsChannel``.
  var settingsChannel: EditorSettingsChannel?

  init(text: Binding<String>, commands: EditorCommands) {
    self._text = text
    self.commands = commands
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text, commands: commands) }

  @MainActor
  final class Coordinator: NSObject {
    @Binding var text: String
    weak var textView: PlatformTextView?

    /// The current `onScroll` callback, refreshed on every `updateXxxView` so
    /// it always reflects the latest closure the host view passed in.
    var onScroll: ((CGFloat) -> Void)?

    // The typeface and size currently applied to the text view, so a no-op
    // `updateXxxView` (the common case) doesn't needlessly restyle the document.
    var appliedFont: EditorFont?
    var appliedSize: CGFloat?
    var appliedTitleRatio: CGFloat?
    var appliedCodeRatio: CGFloat?
    var appliedLineHeightMultiple: CGFloat?
    var appliedColorScheme: EditorColorScheme?
    var appliedRevealMode: MarkerRevealMode?
    var appliedTablesEnabled: Bool?
    var appliedListBulletStyle: ListBulletStyle?
    var appliedMaxTextWidth: CGFloat?

    // The selection as of the last `textViewDidChangeSelection`, so a caret
    // move can be diffed against where it came from. See `MarkerConcealment`.
    var lastSelectedRange = NSRange(location: 0, length: 0)

    // Derives formatting from the text as Markdown on every change.
    let highlighter = MarkdownHighlighter()

    // The text storage of the TextKit 1 stack the editor builds by hand (see
    // `makeNSView` / `makeUIView`). Held here because nothing else does: a text
    // storage retains its layout managers, not the other way round, so a stack
    // assembled outside the text view's own initializer would otherwise lose
    // its storage the moment the local goes out of scope.
    var storage: NSTextStorage?

    // The binding carries only the Markdown source, so pushing it up is a cheap
    // string read rather than an attribute-run conversion. We still coalesce the
    // write: it re-renders the SwiftUI view tree, and there's no value in doing
    // that once per keystroke.
    private var bindingSyncTask: Task<Void, Never>?

    // True from a text-view edit until its debounced binding sync completes, so
    // updateXxxView won't rebuild the storage from the (stale) binding and
    // clobber in-progress typing.
    var isSyncingFromTextView = false

    // Block-based NotificationCenter tokens (iOS keyboard observers, macOS
    // scroll-offset observer) to unregister when the coordinator goes away.
    // Mutated only on the main actor; read once from the nonisolated deinit.
    nonisolated(unsafe) var observerTokens: [NSObjectProtocol] = []

    // The settings channel this editor is subscribed to, and the id that
    // identifies it there. Dropped in `dismantle`, which runs on the main
    // actor, unlike `deinit`.
    private var subscription: (channel: EditorSettingsChannel, id: UUID)?

    init(text: Binding<String>, commands: EditorCommands) {
      self._text = text
      super.init()
      commands.handler = { [weak self] in self?.handle($0) }
    }

    deinit {
      observerTokens.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Typeface

    /// Switches the editor to `family` at `size` with `lineHeightMultiple` and
    /// `colorScheme` if any of the four isn't already active: updates the global
    /// typography state, restyles the document so every block picks up the new
    /// face/scale/spacing/colors, and resets the typing attributes to match.
    /// No-op if nothing changed.
    ///
    /// The binding holds only the Markdown source, which a typeface change leaves
    /// untouched, so unlike the old attributed binding there is nothing to push
    /// back up here.
    func applyFont(
      _ family: EditorFont, size: CGFloat, titleRatio: CGFloat, codeRatio: CGFloat,
      lineHeightMultiple: CGFloat, colorScheme: EditorColorScheme
    ) {
      guard
        appliedFont != family || appliedSize != size || appliedTitleRatio != titleRatio
          || appliedCodeRatio != codeRatio
          || appliedLineHeightMultiple != lineHeightMultiple
          || appliedColorScheme != colorScheme
      else { return }
      appliedFont = family
      appliedSize = size
      appliedTitleRatio = titleRatio
      appliedCodeRatio = codeRatio
      appliedLineHeightMultiple = lineHeightMultiple
      appliedColorScheme = colorScheme
      Typography.current = family
      Typography.baseSize = size
      Typography.titleRatio = titleRatio
      Typography.codeRatio = codeRatio
      Typography.lineHeightMultiple = lineHeightMultiple
      Typography.colorScheme = colorScheme
      guard let tv = textView, let storage = tv.optionalTextStorage else { return }
      tv.setEditorBackground(PlatformColor(colorScheme.background))
      tv.typingAttributes = TextStyle.body.attributes
      highlighter.highlight(storage)
    }

    /// Switches which markers reveal on caret proximity (the span itself vs.
    /// the whole line), if it isn't already active. Marker concealment is a
    /// glyph-generation decision, not a text attribute (see
    /// `MarkerConcealment`), so unlike `applyFont` this needs no restyle —
    /// just notifying the layout manager, via the same
    /// `NSTextStorage.edited(_:range:changeInLength:)` path
    /// `invalidateConcealment` uses, that every marker's concealment needs
    /// re-deciding against the new rule.
    func applyRevealMode(_ mode: MarkerRevealMode) {
      guard appliedRevealMode != mode else { return }
      appliedRevealMode = mode
      Typography.revealMode = mode
      guard let tv = textView, let storage = tv.optionalTextStorage, storage.length > 0 else {
        return
      }
      storage.beginEditing()
      storage.edited(
        .editedAttributes, range: NSRange(location: 0, length: storage.length), changeInLength: 0)
      storage.endEditing()
      tv.refreshEditorDisplay()
    }

    /// Switches the glyph unordered list markers render as, if it isn't already
    /// active. Two things move: which glyph the layout manager draws for the
    /// marker (a glyph-generation decision keyed off `.listBulletMarker`, see
    /// `MarkerConcealment`) and the marker's font, kern, and baseline offset for
    /// a scaled style (real text attributes `MarkdownHighlighter.tagUnorderedBullet`
    /// stamps during styling). So this restyles the whole document for the
    /// attributes, then invalidates every glyph so the new marker glyph is
    /// regenerated even on markers whose attributes did not change.
    func applyListBulletStyle(_ style: ListBulletStyle) {
      guard appliedListBulletStyle != style else { return }
      appliedListBulletStyle = style
      Typography.listBulletStyle = style
      guard let tv = textView, let storage = tv.optionalTextStorage, storage.length > 0 else {
        return
      }
      highlighter.highlight(storage)
      storage.beginEditing()
      storage.edited(
        .editedAttributes, range: NSRange(location: 0, length: storage.length), changeInLength: 0)
      storage.endEditing()
      tv.refreshEditorDisplay()
    }

    /// Turns table rendering on or off, if it isn't already in that state.
    /// Tables are a parse-time decision (`MarkdownHighlighter` reads
    /// `Typography.tablesEnabled` as it styles each block), so this restyles
    /// the whole document to switch every table over.
    func applyTablesEnabled(_ enabled: Bool) {
      guard appliedTablesEnabled != enabled else { return }
      appliedTablesEnabled = enabled
      Typography.tablesEnabled = enabled
      guard let tv = textView, let storage = tv.optionalTextStorage else { return }
      highlighter.highlight(storage)
    }

    // MARK: Settings channel

    /// Subscribes to `channel`, replacing any previous subscription. Called
    /// when the platform view is made and again on every update, so an editor
    /// handed a different channel follows it. A nil channel just unsubscribes.
    func attach(to channel: EditorSettingsChannel?) {
      if let current = subscription {
        guard current.channel !== channel else { return }
        current.channel.unsubscribe(current.id)
        subscription = nil
      }
      guard let channel else { return }
      let id = channel.subscribe { [weak self] settings in self?.applySettings(settings) }
      subscription = (channel, id)
    }

    /// Unsubscribes. Called from the representable's `dismantle`, which runs on
    /// the main actor; `deinit` doesn't and so can't touch the channel.
    func dismantle() {
      guard let current = subscription else { return }
      current.channel.unsubscribe(current.id)
      subscription = nil
    }

    /// Applies a whole ``EditorSettings`` now, the same work `updateXxxView`
    /// does with the same values. The channel carries no colors, so the restyle
    /// reuses the scheme already in effect rather than reverting the document to
    /// the default one for the length of a drag.
    private func applySettings(_ settings: EditorSettings) {
      applyFont(
        settings.font, size: CGFloat(settings.fontSize),
        titleRatio: CGFloat(settings.titleRatio), codeRatio: CGFloat(settings.codeRatio),
        lineHeightMultiple: CGFloat(settings.lineHeight),
        colorScheme: appliedColorScheme ?? Typography.colorScheme)
      applyRevealMode(settings.markerRevealMode)
      applyTablesEnabled(settings.experimentalTables)
      applyListBulletStyle(settings.listBullet)
      applyMaxTextWidth(CGFloat(settings.maxWidth))
      redisplay()
    }

    /// Draws the restyle now. This runs while another window tracks the mouse,
    /// and a window other than the tracked one is not guaranteed a display pass
    /// out of that loop, so request one rather than wait.
    private func redisplay() {
      guard let tv = textView else { return }
      tv.refreshEditorDisplay()
      #if canImport(AppKit)
        tv.window?.displayIfNeeded()
      #endif
    }

    /// Changes the centered column's max width, if it isn't already active.
    /// `EditorTextView` recomputes its centering inset from `Typography
    /// .maxTextWidth` on every resize/layout pass already; this just forces
    /// that recomputation once more for a width change with no resize behind
    /// it (e.g. a settings change while the window sits still).
    func applyMaxTextWidth(_ width: CGFloat) {
      guard appliedMaxTextWidth != width else { return }
      appliedMaxTextWidth = width
      Typography.maxTextWidth = width
      (textView as? EditorTextView)?.updateTextContainerInset()
    }

    // MARK: Binding sync

    /// Coalesces the binding write. Called on every text-view change; the write
    /// itself runs once typing settles, so a burst of keystrokes re-renders the
    /// surrounding SwiftUI view tree once rather than per character.
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
      text = storage.string
    }

    // MARK: External text sync

    /// Brings the text view in line with `incoming` (the binding), for a change
    /// that came from outside the editor. Replaces only the characters that
    /// actually differ, found by trimming the common prefix and suffix, so an
    /// external edit costs what the edit is worth instead of rebuilding the
    /// whole document, which would also reparse it from scratch and drop the
    /// selection.
    ///
    /// The replacement runs through `NSTextStorage`, so the highlighter's
    /// `didProcessEditing` restyles it like any other edit; a change big enough to
    /// span paragraphs is settled by flushing the deferred parse rather than
    /// leaving it mis-styled until the debounce elapses.
    func applyExternalText(_ incoming: String, to storage: NSTextStorage, in tv: PlatformTextView) {
      guard let edit = TextDiff.between(storage.mutableString, and: incoming as NSString)
      else { return }

      let selection = tv.selectedRange
      storage.beginEditing()
      storage.replaceCharacters(in: edit.replaced, with: edit.replacement)
      storage.endEditing()
      highlighter.flushPendingParse(storage)

      // Keep the caret where it was, clamped into the new text: an external change
      // can leave the document shorter than the old selection reached.
      let end = min(selection.location + selection.length, storage.length)
      let location = min(selection.location, end)
      tv.setEditorSelectedRange(NSRange(location: location, length: end - location))
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
        replaceText(
          marker + marker, in: sel,
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
          replaceText(
            inner, in: outerRange,
            thenSelect: NSRange(location: sel.location - mLen, length: sel.length))
          return
        }
      }

      // Markers inside the selection: remove them.
      if sel.length >= mLen * 2 {
        let selectedStr = str.substring(with: sel)
        if selectedStr.hasPrefix(marker) && selectedStr.hasSuffix(marker) {
          let innerLen = sel.length - mLen * 2
          let inner = (selectedStr as NSString).substring(
            with: NSRange(location: mLen, length: innerLen))
          replaceText(inner, in: sel, thenSelect: NSRange(location: sel.location, length: innerLen))
          return
        }
      }

      // Wrap the selection.
      let selectedStr = str.substring(with: sel)
      replaceText(
        "\(marker)\(selectedStr)\(marker)", in: sel,
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

    // MARK: List continuation

    /// The list marker on a line, and what the *next* line should start with to
    /// continue the list.
    private struct ListItemPrefix {
      /// Characters from the line start through the marker and its trailing
      /// spacing (and any task checkbox): the run to drop when ending the list.
      let length: Int
      /// Text to open the continuation line: the same indentation and marker
      /// (an ordered number incremented, an unordered bullet repeated).
      let continuation: String
      /// Whether the item has no content after its marker, i.e. an empty bullet
      /// the user is pressing Enter on to leave the list.
      let contentEmpty: Bool
    }

    /// If the caret sits in a list item, handles Enter itself and returns true.
    /// On an empty item it drops the marker so the list ends; otherwise it splits
    /// the line and opens the next item with a fresh marker (the number bumped for
    /// an ordered list). Returns false for a non-list line, letting the text view
    /// insert an ordinary newline.
    func handleListNewline() -> Bool {
      guard let tv = textView, let storage = tv.optionalTextStorage else { return false }
      let str = storage.mutableString
      let sel = tv.selectedRange
      let para = str.paragraphRange(for: NSRange(location: sel.location, length: 0))

      // Parse the line without its trailing newline.
      var lineLength = para.length
      if lineLength > 0, str.character(at: para.location + lineLength - 1) == 0x0A {
        lineLength -= 1
      }
      let line =
        str.substring(with: NSRange(location: para.location, length: lineLength)) as NSString
      guard let prefix = parseListPrefix(line) else { return false }

      if prefix.contentEmpty {
        // Enter on an empty item ends the list: remove the marker, leaving a blank
        // line with the caret where the marker was.
        replaceText(
          "", in: NSRange(location: para.location, length: prefix.length),
          thenSelect: NSRange(location: para.location, length: 0))
        return true
      }

      let insert = "\n" + prefix.continuation
      replaceText(
        insert, in: sel,
        thenSelect: NSRange(location: sel.location + (insert as NSString).length, length: 0))
      return true
    }

    /// Recognizes an ordered (`1.`, `2)`) or unordered (`-`, `*`, `+`) list marker
    /// at the start of `line`, optionally followed by a task checkbox, and returns
    /// how to continue it. Nil when the line isn't a list item. A bullet must be
    /// followed by whitespace (or end the line) so `---` or `-word` aren't mistaken
    /// for one.
    private func parseListPrefix(_ line: NSString) -> ListItemPrefix? {
      let length = line.length
      func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
      func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }

      var i = 0
      while i < length, isSpace(line.character(at: i)) { i += 1 }
      let indentEnd = i
      guard i < length else { return nil }

      let first = line.character(at: i)
      var newMarker: String
      if first == 0x2D || first == 0x2A || first == 0x2B {  // - * +
        newMarker = line.substring(with: NSRange(location: i, length: 1))
        i += 1
      } else if isDigit(first) {
        let numberStart = i
        while i < length, isDigit(line.character(at: i)) { i += 1 }
        guard i < length else { return nil }
        let delim = line.character(at: i)
        guard delim == 0x2E || delim == 0x29 else { return nil }  // . )
        let number = Int(
          line.substring(with: NSRange(location: numberStart, length: i - numberStart)))
        i += 1
        newMarker = "\((number ?? 0) + 1)\(delim == 0x2E ? "." : ")")"
      } else {
        return nil
      }

      // A real marker is followed by whitespace or the line's end.
      guard i >= length || isSpace(line.character(at: i)) else { return nil }
      let markerEnd = i
      while i < length, isSpace(line.character(at: i)) { i += 1 }
      let spacingEnd = i

      // Optional task checkbox: [ ], [x], or [X]. A continued item starts unchecked.
      var task = ""
      if i + 2 < length, line.character(at: i) == 0x5B, line.character(at: i + 2) == 0x5D {
        let mark = line.character(at: i + 1)
        if mark == 0x20 || mark == 0x78 || mark == 0x58 {
          i += 3
          let boxEnd = i
          while i < length, isSpace(line.character(at: i)) { i += 1 }
          let boxSpacing = line.substring(with: NSRange(location: boxEnd, length: i - boxEnd))
          task = "[ ]" + (boxSpacing.isEmpty ? " " : boxSpacing)
        }
      }

      let indent = line.substring(with: NSRange(location: 0, length: indentEnd))
      var spacing = line.substring(
        with: NSRange(location: markerEnd, length: spacingEnd - markerEnd))
      if spacing.isEmpty { spacing = " " }  // "- " at end of line kept no run to copy

      return ListItemPrefix(
        length: i, continuation: indent + newMarker + spacing + task, contentEmpty: i >= length)
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
