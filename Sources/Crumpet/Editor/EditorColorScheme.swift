import SwiftUI

/// Foreground colors for the editor's markdown constructs.
///
/// Every construct color left at its default falls back to `text`, so the
/// default scheme renders all text in one color until you override the
/// constructs you care about:
///
/// ```swift
/// MarkdownEditor(text: $text)
///   .editorColorScheme(
///     .init(heading: .blue, code: .pink, bold: .orange, italic: .teal, listBullet: .green))
/// ```
public struct EditorColorScheme: Sendable, Equatable {
  /// Body text, ordered list markers, and every construct without its own
  /// color.
  public var text: Color
  /// Title and heading text.
  public var heading: Color
  /// Inline code spans and code blocks.
  public var code: Color
  /// Bold (`**`) text.
  public var bold: Color
  /// Italic (`*`) text.
  public var italic: Color
  /// Link and image text (`[text](url)`, `![alt](url)`, autolinks).
  public var link: Color
  /// Unordered list bullet glyphs (`-`, `*`, `+`, rendered as
  /// ``ListBulletStyle`` markers). Ordered markers (`1.`, `2)`) stay in
  /// `text`, since they're literal source characters, not a drawn glyph.
  public var listBullet: Color
  /// The page background behind the document. Defaults to
  /// ``Color/editorBackground``, so it adapts to light/dark mode like the rest
  /// of the scheme until a theme overrides it.
  public var background: Color
  /// Syntax highlighting inside fenced code blocks that name a supported
  /// language (`json`, `bash`, `sh`, `shell`, `zsh`, `toml`). Each color left at its
  /// default falls back to `code`.
  public var syntax: SyntaxColors

  /// Colors for the token kinds of highlighted code blocks.
  public struct SyntaxColors: Sendable, Equatable {
    /// Language keywords and literal constants such as `true` and `null`.
    public var keyword: Color
    /// String literals.
    public var string: Color
    /// Numbers and command-line flags.
    public var number: Color
    /// Comments.
    public var comment: Color
    /// Command names and function names.
    public var function: Color
    /// Variables and object keys.
    public var property: Color

    /// Creates syntax colors. Each color left `nil` falls back to `fallback`.
    public init(
      keyword: Color? = nil, string: Color? = nil, number: Color? = nil,
      comment: Color? = nil, function: Color? = nil, property: Color? = nil,
      fallback: Color = .primary
    ) {
      self.keyword = keyword ?? fallback
      self.string = string ?? fallback
      self.number = number ?? fallback
      self.comment = comment ?? fallback
      self.function = function ?? fallback
      self.property = property ?? fallback
    }
  }

  /// Creates a scheme. Each construct color left `nil` falls back to `text`,
  /// and each syntax color left `nil` falls back to `code`.
  public init(
    text: Color = .primary,
    heading: Color? = nil,
    code: Color? = nil,
    bold: Color? = nil,
    italic: Color? = nil,
    link: Color? = nil,
    listBullet: Color? = nil,
    background: Color = .editorBackground,
    syntax: SyntaxColors? = nil
  ) {
    self.text = text
    self.heading = heading ?? text
    self.code = code ?? text
    self.bold = bold ?? text
    self.italic = italic ?? text
    self.link = link ?? text
    self.listBullet = listBullet ?? text
    self.background = background
    self.syntax = syntax ?? SyntaxColors(fallback: code ?? text)
  }

  /// Every construct rendered in the same adaptive text color, on the
  /// adaptive page background.
  public static let standard = EditorColorScheme()

  /// Builds a scheme from a Tinted Theming (base16 or base24) palette, keyed
  /// `base00` through `base0F`. Keys are case-insensitive and values are hex
  /// colors with or without a leading `#`. The slots map onto the editor as:
  ///
  /// - `base00`: `background`
  /// - `base05`: `text`
  /// - `base0D`: `heading`
  /// - `base0B`: `code`
  /// - `base09`: `bold`
  /// - `base0E`: `italic`
  /// - `base0C`: `link`
  /// - `base08`: `listBullet`
  ///
  /// Code block syntax colors use `base0E` (keyword), `base0B` (string),
  /// `base09` (number), `base03` (comment), `base0D` (function), and `base08`
  /// (property). A `syntax.keyword`, `syntax.string`, `syntax.constant.numeric`,
  /// `syntax.comment`, or `syntax.entity.name.function` entry takes precedence
  /// over the slot for its kind. A missing or unparseable syntax color falls
  /// back to `code`.
  ///
  /// The other slots are unused. Nil unless all eight construct slots are
  /// present and parse with ``SwiftUI/Color/init(hex:)``.
  public init?(tintedPalette palette: [String: String]) {
    let normalized = Dictionary(
      palette.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    func color(_ slot: String) -> Color? { normalized[slot].flatMap { Color(hex: $0) } }
    guard
      let background = color("base00"), let text = color("base05"),
      let heading = color("base0d"), let code = color("base0b"),
      let bold = color("base09"), let italic = color("base0e"),
      let link = color("base0c"), let bullet = color("base08")
    else { return nil }
    func syntaxColor(_ scope: String, _ slot: String) -> Color? {
      color("syntax." + scope) ?? color(slot)
    }
    let syntax = SyntaxColors(
      keyword: syntaxColor("keyword", "base0e"), string: syntaxColor("string", "base0b"),
      number: syntaxColor("constant.numeric", "base09"), comment: syntaxColor("comment", "base03"),
      function: syntaxColor("entity.name.function", "base0d"), property: color("base08"),
      fallback: code)
    self.init(
      text: text, heading: heading, code: code, bold: bold, italic: italic, link: link,
      listBullet: bullet, background: background, syntax: syntax)
  }

  /// Builds a scheme from the text of a Tinted Theming scheme file in the
  /// base16, base24, or tinted8 system.
  ///
  /// For base16 and base24, reads every `baseXX: "value"` line, whether at the
  /// top level or nested under `palette:`. For tinted8, reads the named colors
  /// under the top-level `palette:` and the top-level `variant:`, and maps them
  /// as ``init(tintedPalette:)`` slots:
  ///
  /// - `black` and `white`: `base00` and `base05`, swapped when `variant` is
  ///   `light`
  /// - `red`, `orange`, `green`, `cyan`, `blue`, `magenta`: `base08`, `base09`,
  ///   `base0B`, `base0C`, `base0D`, `base0E`
  /// - `gray`: `base03`
  ///
  /// The top-level `syntax:` section overrides the syntax color of its kind for
  /// the scopes `keyword`, `string`, `constant.numeric`, `comment`, and
  /// `entity.name.function`.
  ///
  /// All other lines are ignored. Quotes and trailing `#` comments are stripped
  /// from values. Nil under the same conditions as ``init(tintedPalette:)``.
  public init?(tintedYAML yaml: String) {
    var base: [String: String] = [:]
    var named: [String: String] = [:]
    var variant = ""
    var section = ""
    var scopes: [String: String] = [:]
    for line in yaml.split(whereSeparator: \.isNewline) {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces)
      guard !key.isEmpty, !key.hasPrefix("#") else { continue }
      let value = Self.yamlScalar(line[line.index(after: colon)...])
      let topLevel = !(line.first?.isWhitespace ?? false)
      if topLevel {
        section = key
        if key == "variant" { variant = value.lowercased() }
      } else if section == "palette" {
        named[key] = value
      } else if section == "syntax" {
        scopes[key] = value
      }
      if key.lowercased().hasPrefix("base"), key.count == 6 { base[key] = value }
    }
    if base.isEmpty {
      guard let black = named["black"], let white = named["white"] else { return nil }
      let (background, text) = variant == "light" ? (white, black) : (black, white)
      base = ["base00": background, "base05": text]
      let slots = [
        "red": "base08", "orange": "base09", "green": "base0B", "cyan": "base0C",
        "blue": "base0D", "magenta": "base0E",
      ]
      for (name, slot) in slots { base[slot] = named[name] }
      base["base03"] = named["gray"]
      for (scope, value) in scopes { base["syntax." + scope] = value }
    }
    self.init(tintedPalette: base)
  }

  /// A YAML scalar value with surrounding quotes or a trailing `#` comment
  /// removed.
  private static func yamlScalar(_ raw: Substring) -> String {
    var value = raw.trimmingCharacters(in: .whitespaces)
    if let quote = value.first, quote == "\"" || quote == "'" {
      value.removeFirst()
      if let end = value.firstIndex(of: quote) { value = String(value[..<end]) }
    } else if let comment = value.range(of: " #") {
      value = String(value[..<comment.lowerBound])
    }
    return value.trimmingCharacters(in: .whitespaces)
  }
}
