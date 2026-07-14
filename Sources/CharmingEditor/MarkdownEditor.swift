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
  // Named to avoid colliding with `View.colorScheme(_:)`, SwiftUI's own
  // environment-scheme modifier.
  private var syntaxColors: EditorColorScheme = .standard

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
    editor.syntaxColors = syntaxColors
    return editor
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

  /// Sets the foreground colors used for markdown constructs (headings, code,
  /// bold, italic). Defaults to ``EditorColorScheme/standard``, which renders
  /// everything in the same adaptive text color.
  public func editorColorScheme(_ colorScheme: EditorColorScheme) -> MarkdownEditor {
    var copy = self
    copy.syntaxColors = colorScheme
    return copy
  }
}
