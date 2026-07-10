import Foundation
import SwiftUI

/// Owns the single in-memory document this example edits. This is a demo of
/// the CharmingEditor library, not a real app, so nothing is persisted.
@MainActor
@Observable
final class PageStore {
  /// The editor's document. The editor writes back through its binding as
  /// you type.
  var text = AttributedString(PageStore.welcomeMarkdown)

  private static let welcomeMarkdown = """
    # Welcome to CharmingEditor

    This is a live **Markdown** editor. Formatting is derived from the *source*
    as you type — headings, `code`, **bold**, and *italic* all update inline.

    ## Try it

    - Toggle **bold** (⌘B) and *italic* (⌘I)
    - Change the block style with ⌥ ⌘ 1 / ⌥ ⌘ 2 / ⌥ ⌘ 0
    """
}
