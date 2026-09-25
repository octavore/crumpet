import SwiftUI

/// Whether the editor follows the system's light or dark appearance or stays in
/// one of them. Set it with `MarkdownEditor.editorAppearance(_:)`.
public enum EditorAppearance: String, CaseIterable, Identifiable, Sendable {
  /// Follows the system appearance.
  case system
  /// Always light.
  case light
  /// Always dark.
  case dark

  public var id: String { rawValue }

  /// The name shown in menus and pickers.
  public var displayName: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  /// The appearance in effect when the system appearance is `system`.
  public func resolved(_ system: ColorScheme) -> ColorScheme {
    switch self {
    case .system: system
    case .light: .light
    case .dark: .dark
    }
  }

  /// The fixed appearance, or nil for ``system``.
  var override: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}
