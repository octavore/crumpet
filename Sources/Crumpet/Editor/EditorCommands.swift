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

  /// Creates a command bridge with no editor attached.
  public init() {}

  /// Applies `command` to the attached editor's text and selection. Does
  /// nothing if no editor is attached.
  public func send(_ command: EditorCommand) {
    handler?(command)
  }
}
