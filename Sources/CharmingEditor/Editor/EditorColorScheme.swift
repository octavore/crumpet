import SwiftUI

/// Foreground colors for the editor's markdown constructs.
///
/// Every field left at its default falls back to `text`, so today's uniform
/// look is the default and adopting the type is a no-op until you override the
/// constructs you care about:
///
/// ```swift
/// MarkdownEditor(text: $text)
///   .editorColorScheme(
///     .init(heading: .blue, code: .pink, bold: .orange, italic: .teal, listBullet: .green))
/// ```
public struct EditorColorScheme: Sendable, Equatable {
  public var text: Color
  public var heading: Color
  public var code: Color
  public var bold: Color
  public var italic: Color
  /// Unordered list bullet glyphs (`-`, `*`, `+`, rendered as
  /// ``ListBulletStyle`` markers). Ordered markers (`1.`, `2)`) stay in
  /// `text`, since they're literal source characters, not a drawn glyph.
  public var listBullet: Color
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
    listBullet: Color? = nil,
    background: Color = .editorBackground
  ) {
    self.text = text
    self.heading = heading ?? text
    self.code = code ?? text
    self.bold = bold ?? text
    self.italic = italic ?? text
    self.listBullet = listBullet ?? text
    self.background = background
  }

  /// Every construct rendered in the same adaptive text color, on the
  /// adaptive page background.
  public static let standard = EditorColorScheme()

  /// Builds a scheme from a pasted Slack theme string: an array of hex colors.
  /// Slack assigns the colors in this order:
  ///
  /// 1. Column BG - sidebar background
  /// 2. Menu BG Hover - selected/hover background
  /// 3. Active Item - active channel text
  /// 4. Active Item Text - active channel background
  /// 5. Hover Item - hovered channel background
  /// 6. Text Color - default sidebar text
  /// 7. Active Presence - online status dot
  /// 8. Mention Badge - notification badge
  /// 9. Top Nav Background - the top navigation bar across the window
  /// 10. Top Nav Text - foreground text and search-bar frame in that strip
  ///
  /// These map onto the editor as `background` (1), `heading` (3), `bold` (4),
  /// `text` (6), `italic` (7), and `code` (8); slots 2 and 5 are hover-only
  /// backgrounds and slots 9 and 10 top-nav styling, all unused. Nil unless
  /// `strings` has at least eight entries and every one is a parseable hex
  /// color (`#RGB`, `#RRGGBB`, or `#RRGGBBAA`, with or without the `#`).
  public init?(themeStrings strings: [String]) {
    guard strings.count >= 8 else { return nil }
    let colors = strings.map { Color(hex: $0) }
    guard colors.allSatisfy({ $0 != nil }) else { return nil }
    self.init(
      text: colors[5]!, heading: colors[2]!, code: colors[7]!, bold: colors[3]!,
      italic: colors[6]!, background: colors[0]!)
  }

  /// Splits a comma- or whitespace-separated string of hex colors (Slack's
  /// "import theme" format) into the pieces ``init(themeStrings:)`` expects.
  public static func splitThemeString(_ raw: String) -> [String] {
    raw.split(whereSeparator: { $0 == "," || $0.isWhitespace })
      .map(String.init)
  }
}
