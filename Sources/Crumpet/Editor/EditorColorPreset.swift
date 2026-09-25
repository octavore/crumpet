import Foundation
import SwiftUI

/// A built-in color scheme taken from the Tinted Theming collection.
///
/// Each case loads a scheme file bundled under `Resources/Schemes`, parsed with
/// ``EditorColorScheme/init(tintedYAML:)``:
///
/// ```swift
/// MarkdownEditor(text: $text)
///   .editorColorScheme(EditorColorScheme(.nord))
/// ```
///
/// Schemes come from https://github.com/tinted-theming/schemes (MIT license):
///
/// - Default Dark: base16/default-dark.yaml by Chris Kempson
/// - Default Light: base16/default-light.yaml by Chris Kempson
/// - Solarized Dark: base16/solarized-dark.yaml by Ethan Schoonover
/// - Solarized Light: base16/solarized-light.yaml by Ethan Schoonover
/// - Gruvbox Dark: tinted8/gruvbox-dark.yaml by morhetz
/// - Gruvbox Light: base24/gruvbox-light.yaml by morhetz
/// - Dracula: base24/dracula.yaml by clach04
/// - Nord: tinted8/nord.yaml by Arctic Ice Studio
/// - Nord Light: base16/nord-light.yaml by threddast
///
/// The Solarized presets use the base16 files. The base24 Solarized files are
/// terminal palettes whose `base05` is the same mid-gray in both variants,
/// which is unreadable on the light background.
public enum EditorColorPreset: String, CaseIterable, Identifiable, Sendable {
  case defaultDark
  case defaultLight
  case solarizedDark
  case solarizedLight
  case gruvboxDark
  case gruvboxLight
  case dracula
  case nord
  case nordLight

  public var id: String { rawValue }

  /// The name shown in menus and pickers.
  public var displayName: String {
    switch self {
    case .defaultDark: "Default Dark"
    case .defaultLight: "Default Light"
    case .solarizedDark: "Solarized Dark"
    case .solarizedLight: "Solarized Light"
    case .gruvboxDark: "Gruvbox Dark"
    case .gruvboxLight: "Gruvbox Light"
    case .dracula: "Dracula"
    case .nord: "Nord"
    case .nordLight: "Nord Light"
    }
  }

  /// The scheme file's name in `Resources/Schemes`, without the extension.
  var fileName: String {
    switch self {
    case .defaultDark: "default-dark"
    case .defaultLight: "default-light"
    case .solarizedDark: "solarized-dark"
    case .solarizedLight: "solarized-light"
    case .gruvboxDark: "gruvbox-dark"
    case .gruvboxLight: "gruvbox-light"
    case .dracula: "dracula"
    case .nord: "nord"
    case .nordLight: "nord-light"
    }
  }

  /// The scheme parsed from the bundled file, or nil if the file is missing or
  /// fails to parse.
  func loadScheme() -> EditorColorScheme? {
    guard
      let url = Bundle.module.url(
        forResource: fileName, withExtension: "yaml", subdirectory: "Schemes"),
      let yaml = try? String(contentsOf: url, encoding: .utf8)
    else { return nil }
    return EditorColorScheme(tintedYAML: yaml)
  }

  /// Every preset's scheme, loaded once.
  fileprivate static let schemes: [EditorColorPreset: EditorColorScheme] = Dictionary(
    uniqueKeysWithValues: allCases.map { ($0, $0.loadScheme() ?? .standard) })
}

extension EditorColorPreset {
  /// A light preset and a dark preset that belong together, for switching with
  /// the appearance. Pass one to `MarkdownEditor.editorColorScheme(_:)`. A
  /// family with one variant uses the same preset for both.
  public enum Family: String, CaseIterable, Identifiable, Sendable {
    case classic
    case solarized
    case gruvbox
    case nord
    case dracula

    public var id: String { rawValue }

    /// The name shown in menus and pickers.
    public var displayName: String {
      switch self {
      case .classic: "Default"
      case .solarized: "Solarized"
      case .gruvbox: "Gruvbox"
      case .nord: "Nord"
      case .dracula: "Dracula"
      }
    }

    /// The preset used in light mode.
    public var light: EditorColorPreset {
      switch self {
      case .classic: .defaultLight
      case .solarized: .solarizedLight
      case .gruvbox: .gruvboxLight
      case .nord: .nordLight
      case .dracula: .dracula
      }
    }

    /// The preset used in dark mode.
    public var dark: EditorColorPreset {
      switch self {
      case .classic: .defaultDark
      case .solarized: .solarizedDark
      case .gruvbox: .gruvboxDark
      case .nord: .nord
      case .dracula: .dracula
      }
    }

    /// Whether the family has distinct light and dark presets.
    public var hasLightAndDark: Bool { light != dark }

    /// The preset for `appearance`.
    public func preset(for appearance: ColorScheme) -> EditorColorPreset {
      appearance == .dark ? dark : light
    }
  }
}

extension EditorColorScheme {
  /// Creates the scheme for a built-in preset. Falls back to ``standard`` if
  /// the bundled scheme file is missing or fails to parse.
  public init(_ preset: EditorColorPreset) {
    self = EditorColorPreset.schemes[preset] ?? .standard
  }
}
