import SwiftUI

public enum EditorCommand {
  case toggleBold
  case toggleItalic
  case setBlockStyle(TextStyle)
}

/// Bridge from SwiftUI controls into the active editor backend. The view
/// that owns the editor creates one and passes it down; the backend installs
/// a handler when its platform view is made.
@MainActor
public final class EditorCommands {
  var handler: ((EditorCommand) -> Void)?

  public init() {}

  public func send(_ command: EditorCommand) {
    handler?(command)
  }
}
