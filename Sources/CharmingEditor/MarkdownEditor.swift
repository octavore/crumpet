import SwiftUI

/// A SwiftUI Markdown editor.
///
/// Renders and edits Markdown text with live syntax highlighting on macOS and
/// iOS. The document is exposed as a plain `String` binding holding the Markdown
/// source; formatting is derived from that source on every edit rather than
/// stored as rich-text attributes, so the source is the whole document state.
///
/// ```swift
/// struct ContentView: View {
///   @State private var text = "# Hello\n\nStart typing…"
///   var body: some View {
///     MarkdownEditor(text: $text)
///       .editorFont(.serif)
///       .editorFontSize(18)
///       .editorLineHeight(1.4)
///   }
/// }
/// ```
///
/// To drive bold/italic/block-style formatting from your own menus or toolbar,
/// hold an ``EditorCommands`` and attach it with ``commands(_:)``, then call
/// `send(_:)` on it.
public struct MarkdownEditor: View {
  @Binding private var text: String
  private var commands: EditorCommands?
  private var font: EditorFont = .system
  private var fontSize: CGFloat = Typography.defaultBaseSize
  private var titleRatio: CGFloat = Typography.defaultTitleRatio
  private var codeRatio: CGFloat = Typography.defaultCodeRatio
  private var lineHeightMultiple: CGFloat = Typography.defaultLineHeightMultiple
  private var markerRevealMode: MarkerRevealMode = .span
  // Named to avoid colliding with `View.colorScheme(_:)`, SwiftUI's own
  // environment-scheme modifier.
  private var syntaxColors: EditorColorScheme = .standard
  private var onScroll: ((CGFloat) -> Void)?
  private var topContentInset: CGFloat = 0

  /// Creates an editor over `text`, the Markdown source.
  public init(text: Binding<String>) {
    self._text = text
  }

  public var body: some View {
    // `body` is main-actor isolated, so constructing the fallback commands here
    // (rather than as an `init` default) keeps the initializer non-isolated.
    var editor = TextViewEditor(text: $text, commands: commands ?? EditorCommands())
    editor.fontFamily = font
    editor.fontSize = fontSize
    editor.titleRatio = titleRatio
    editor.codeRatio = codeRatio
    editor.lineHeightMultiple = lineHeightMultiple
    editor.markerRevealMode = markerRevealMode
    editor.syntaxColors = syntaxColors
    editor.onScroll = onScroll
    editor.topContentInset = topContentInset
    return editor.background(syntaxColors.background)
  }

  /// Routes formatting commands (bold, italic, block style) from your UI into
  /// this editor. Create one ``EditorCommands``, attach it here, and call
  /// `send(_:)` on it from a button or menu.
  public func commands(_ commands: EditorCommands) -> MarkdownEditor {
    var copy = self
    copy.commands = commands
    return copy
  }

  /// Sets the editor typeface. Defaults to ``EditorFont/system``.
  public func editorFont(_ font: EditorFont) -> MarkdownEditor {
    var copy = self
    copy.font = font
    return copy
  }

  /// Sets the base body point size; titles and headings scale proportionally.
  /// Defaults to ``Typography/defaultBaseSize``.
  public func editorFontSize(_ size: CGFloat) -> MarkdownEditor {
    var copy = self
    copy.fontSize = size
    return copy
  }

  /// Sets the title size as a multiple of the base body size. Defaults to
  /// ``Typography/defaultTitleRatio`` (28:17, title's original fixed
  /// proportion). Heading stays at its own fixed 22:17 proportion.
  public func editorTitleRatio(_ ratio: CGFloat) -> MarkdownEditor {
    var copy = self
    copy.titleRatio = ratio
    return copy
  }

  /// Sets inline and block code's size as a multiple of the base body size,
  /// applied regardless of the surrounding construct's own size. Defaults to
  /// ``Typography/defaultCodeRatio`` (1:1 with the body).
  public func editorCodeRatio(_ ratio: CGFloat) -> MarkdownEditor {
    var copy = self
    copy.codeRatio = ratio
    return copy
  }

  /// Sets the body line height, as a multiple of the font's natural line
  /// height. Defaults to ``Typography/defaultLineHeightMultiple``.
  public func editorLineHeight(_ multiple: CGFloat) -> MarkdownEditor {
    var copy = self
    copy.lineHeightMultiple = multiple
    return copy
  }

  /// Sets whether a concealed markdown marker (the `**`, `*`, or `` ` ``
  /// around bold, italic, and inline code) reveals itself only when the
  /// caret touches its own delimiters, or anywhere on its line. Defaults to
  /// ``MarkerRevealMode/span``.
  public func markerRevealMode(_ mode: MarkerRevealMode) -> MarkdownEditor {
    var copy = self
    copy.markerRevealMode = mode
    return copy
  }

  /// Sets the foreground colors used for markdown constructs (headings, code,
  /// bold, italic). Defaults to ``EditorColorScheme/standard``, which renders
  /// everything in the same adaptive text color.
  public func editorColorScheme(_ colorScheme: EditorColorScheme) -> MarkdownEditor {
    var copy = self
    copy.syntaxColors = colorScheme
    return copy
  }

  /// Calls `action` with the vertical scroll offset (0 at the top, increasing
  /// downward) whenever the document scrolls. Useful for e.g. fading out a
  /// surrounding toolbar as the user scrolls into the document.
  public func onScroll(_ action: @escaping (CGFloat) -> Void) -> MarkdownEditor {
    var copy = self
    copy.onScroll = action
    return copy
  }

  /// Insets the document's top edge by `inset` points without shrinking the
  /// scroll view, so the document starts below an overlaying bar of that
  /// height but still scrolls up underneath it. Offsets reported by
  /// ``onScroll(_:)`` stay 0-based at the top of the document.
  public func editorTopContentInset(_ inset: CGFloat) -> MarkdownEditor {
    var copy = self
    copy.topContentInset = inset
    return copy
  }
}
