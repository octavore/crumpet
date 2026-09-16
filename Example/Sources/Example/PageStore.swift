import Foundation
import SwiftUI

/// Owns the single in-memory document this example edits. This is a demo of
/// the Crumpet library, not a real app, so nothing is persisted.
@MainActor
@Observable
final class PageStore {
  /// The editor's document: the Markdown source, which is the whole of the
  /// document's state. The editor writes back through its binding as you type.
  var text = PageStore.welcomeMarkdown

  private static let welcomeMarkdown = """
    # Welcome to Crumpet

    This is a live **Markdown** editor. Formatting is derived from the *source* \
    as you type: headings, `code`, **bold**, *italic*, and \
    [links](https://github.com/octavore/crumpet) all update inline.

    ## Try it

    - Toggle **bold** (⌘B) and *italic* (⌘I)
    - Change the block style with ⌥ ⌘ 1 / ⌥ ⌘ 2
    - Customize typography and colors in settings (⌘,)

    ## Tables

    | Shortcut | Does | Notes |
    | :-- | :-: | --: |
    | ⌘B | **bold** | wraps the selection |
    | ⌘I | *italic* | same, with one `*` |
    | ⌥⌘1 | title | the whole line |
    """
}
