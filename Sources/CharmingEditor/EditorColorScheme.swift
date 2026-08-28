import SwiftUI

/// Foreground colors for the editor's markdown constructs.
///
/// Every field left at its default falls back to `text`, so today's uniform
/// look is the default and adopting the type is a no-op until you override the
/// constructs you care about:
///
/// ```swift
/// MarkdownEditor(text: $text)
///   .editorColorScheme(.init(heading: .blue, code: .pink, bold: .orange, italic: .teal))
/// ```
public struct EditorColorScheme: Sendable, Equatable {
  public var text: Color
  public var heading: Color
  public var code: Color
  public var bold: Color
  public var italic: Color
  /// The page background behind the document. Defaults to
  /// ``Color/editorBackground``, so it adapts to light/dark mode like the rest
  /// of the scheme until a theme overrides it.
  public var background: Color

  public init(
    text: Color = .primary,
    heading: Color? = nil,
    code: Color? = nil,
    bold: Color? = nil,
    italic: Color? = nil,
    background: Color = .editorBackground
  ) {
    self.text = text
    self.heading = heading ?? text
    self.code = code ?? text
    self.bold = bold ?? text
    self.italic = italic ?? text
    self.background = background
  }

  /// Every construct rendered in the same adaptive text color, on the
  /// adaptive page background.
  public static let standard = EditorColorScheme()

  /// Builds a scheme from a flat list of colors in the order `text, heading,
  /// code, bold, italic, background` — the layout expected of a pasted,
  /// Slack-style theme string. Nil if `strings` doesn't contain exactly 6
  /// entries or any of them isn't a parseable hex color (`#RGB`, `#RRGGBB`,
  /// or `#RRGGBBAA`, with or without the `#`).
  public init?(themeStrings strings: [String]) {
    guard strings.count == 6 else { return nil }
    let colors = strings.map { Color(hex: $0) }
    guard colors.allSatisfy({ $0 != nil }) else { return nil }
    self.init(
      text: colors[0]!, heading: colors[1]!, code: colors[2]!, bold: colors[3]!,
      italic: colors[4]!, background: colors[5]!)
  }

  /// Splits a comma- or whitespace-separated string of hex colors (Slack's
  /// "import theme" format) into the pieces ``init(themeStrings:)`` expects.
  public static func splitThemeString(_ raw: String) -> [String] {
    raw.split(whereSeparator: { $0 == "," || $0.isWhitespace })
      .map(String.init)
  }
}
