import SwiftUI

/// A formatting action sent to an editor through ``EditorCommands/send(_:)``.
public enum EditorCommand {
  /// Toggles `**` bold markers. With no selection, inserts `****` and places
  /// the caret between the pairs. With a selection, removes the markers if they
  /// sit just outside or at both ends of the selection, and wraps the selection
  /// in them otherwise.
  case toggleBold
  /// Toggles `*` italic markers, with the same rules as ``toggleBold``.
  case toggleItalic
  /// Sets the block style of the paragraph containing the start of the
  /// selection by replacing its `#` or `##` prefix with the style's prefix
  /// (`# ` for title, `## ` for heading, none for body).
  case setBlockStyle(TextStyle)
  /// Inserts the Markdown text at the caret, replacing the selection, and
  /// leaves the caret after it.
  case insertText(String)
  /// Moves the caret to the start of the heading, scrolls it into view, and
  /// focuses the editor. If the document changed since `item` was read, the
  /// heading with the same level and title is used instead.
  case scrollToHeading(OutlineItem)
}

/// Bridge from SwiftUI controls into the active editor backend. The view
/// that owns the editor creates one and passes it down; the backend installs
/// a handler when its platform view is made.
///
/// Attach one instance to one editor with ``MarkdownEditor/commands(_:)``.
/// If several editors share an instance, commands go to the editor whose
/// platform view was created most recently.
@MainActor
public final class EditorCommands {
  var handler: ((EditorCommand) -> Void)?
  var textProvider: (() -> String?)?

  /// Creates a command bridge with no editor attached.
  public init() {}

  /// Headings of the attached editor's current text. Empty if no editor is
  /// attached.
  public var outline: [OutlineItem] {
    guard let text = textProvider?() else { return [] }
    return MarkdownOutline.items(in: text)
  }

  /// Applies `command` to the attached editor's text and selection. Does
  /// nothing if no editor is attached.
  public func send(_ command: EditorCommand) {
    handler?(command)
  }
}
