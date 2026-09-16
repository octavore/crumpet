import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// The user-selectable typeface for the editor. Each case maps to one of the
/// system's built-in font designs, so every style in the type scale gets a
/// matching face at its own size and weight (a serif title and serif body).
/// Sizes come from the editor's base size, not Dynamic Type.
public enum EditorFont: String, CaseIterable, Identifiable, Codable, Sendable {
  /// The default system design (San Francisco).
  case system
  /// The system serif design (New York).
  case serif
  /// The system rounded design (SF Pro Rounded).
  case rounded
  /// The system monospaced design (SF Mono).
  case monospaced

  /// The raw value, for use in `ForEach` and pickers.
  public var id: String { rawValue }

  /// The `UserDefaults` key the editor reads at launch to pick its initial
  /// typeface before the first ``MarkdownEditor/editorFont(_:)`` applies.
  public static let defaultsKey = "editorFont"

  /// A title-case name for menus and pickers.
  public var displayName: String {
    switch self {
    case .system: "System"
    case .serif: "Serif"
    case .rounded: "Rounded"
    case .monospaced: "Monospaced"
    }
  }

  private var design: FontDesign {
    switch self {
    case .system: .default
    case .serif: .serif
    case .rounded: .rounded
    case .monospaced: .monospaced
    }
  }

  /// The platform font for this face at a given size and weight.
  func font(ofSize size: CGFloat, weight: PlatformFont.Weight) -> PlatformFont {
    .designed(ofSize: size, weight: weight, design: design)
  }

  /// A SwiftUI font for previewing the face in the settings picker.
  public var previewFont: Font {
    switch self {
    case .system: .system(size: 15)
    case .serif: .system(size: 15, design: .serif)
    case .rounded: .system(size: 15, design: .rounded)
    case .monospaced: .system(size: 15, design: .monospaced)
    }
  }
}

/// When a concealed markdown marker (the `**`, `*`, or `` ` `` around bold,
/// italic, and inline code) reveals itself.
public enum MarkerRevealMode: String, CaseIterable, Identifiable, Codable, Sendable {
  /// Markers reveal when the caret touches the marked span, from the opening
  /// delimiter through the closing one.
  case span
  /// Markers reveal when the caret is anywhere on their line.
  case line
  /// Markers are never concealed; the raw Markdown source is always visible.
  case always

  /// The raw value, for use in `ForEach` and pickers.
  public var id: String { rawValue }

  /// The `UserDefaults` key the editor reads at launch to pick its initial
  /// reveal mode before the first ``MarkdownEditor/markerRevealMode(_:)``
  /// applies.
  public static let defaultsKey = "markerRevealMode"

  /// A title-case name for menus and pickers.
  public var displayName: String {
    switch self {
    case .span: "Touching the Marker"
    case .line: "Anywhere on the Line"
    case .always: "Always"
    }
  }
}

/// The glyph an unordered list's marker (`-`, `*`, or `+`) renders as. The
/// author's character is left in the text; only what the layout manager draws
/// changes, the same mechanism ``MarkerRevealMode`` uses to hide emphasis
/// delimiters. Ordered markers (`1.`, `2)`) are never touched.
public enum ListBulletStyle: String, CaseIterable, Identifiable, Codable, Sendable {
  /// Leave the marker as the author typed it.
  case asTyped
  /// A filled circle (U+2022 •).
  case disc
  /// A hollow circle (U+25E6 ◦).
  case ring
  /// A small filled square (U+25AA ▪).
  case square
  /// An en dash (U+2013 –).
  case dash

  /// The raw value, for use in `ForEach` and pickers.
  public var id: String { rawValue }

  /// The `UserDefaults` key the editor reads at launch to pick its initial
  /// bullet style before the first ``MarkdownEditor/editorSettings(_:)``
  /// applies.
  public static let defaultsKey = "editorListBulletStyle"

  /// A title-case name for menus and pickers.
  public var displayName: String {
    switch self {
    case .asTyped: "As Typed"
    case .disc: "Disc"
    case .ring: "Ring"
    case .square: "Square"
    case .dash: "Dash"
    }
  }

  /// The replacement character, or nil to leave the marker glyph alone. Each
  /// case is a single Unicode scalar present in the system faces.
  var markerScalar: Unicode.Scalar? {
    switch self {
    case .asTyped: nil
    case .disc: Unicode.Scalar(0x2022)  // •
    case .ring: Unicode.Scalar(0x25E6)  // ◦
    case .square: Unicode.Scalar(0x25AA)  // ▪
    case .dash: Unicode.Scalar(0x2013)  // –
    }
  }

  /// Point-size multiple for the replacement glyph, relative to the body font.
  /// The disc glyph reads small at body size, so it takes a nudge up; the
  /// other shapes already sit right.
  var markerScale: CGFloat {
    switch self {
    case .disc: 1.6
    default: 1
    }
  }

  /// Trailing space between the marker glyph and the item text, as a multiple
  /// of the body size, applied as kerning on the marker character.
  var markerTrailingKern: CGFloat {
    switch self {
    case .asTyped: 0
    case .disc, .ring, .square: 0.2
    case .dash: 0.12
    }
  }
}

/// Defaults, slider ranges, and `UserDefaults` keys for the editor's
/// typography options.
///
/// The editor also holds its current typography here as app-wide state. It
/// seeds that state from the `UserDefaults` keys below at launch, so the first
/// render uses values an app saved under those keys, and the editor's
/// modifiers overwrite it once they apply. The ranges are the ones
/// ``EditorSettingsForm`` offers; the modifiers accept values outside them.
public enum Typography {
  /// The `UserDefaults` key for the base body point size.
  public static let sizeDefaultsKey = "editorFontSize"
  /// The default base body point size.
  public static let defaultBaseSize: CGFloat = 17
  /// The base body point sizes ``EditorSettingsForm`` offers.
  public static let sizeRange: ClosedRange<Double> = 12...28

  /// The `UserDefaults` key for the line height multiple.
  public static let lineHeightDefaultsKey = "editorLineHeightMultiple"
  /// The default line height, as a multiple of the font's natural line height.
  public static let defaultLineHeightMultiple: CGFloat = 1.25
  /// The line height multiples ``EditorSettingsForm`` offers.
  public static let lineHeightRange: ClosedRange<Double> = 1.0...2.0

  /// The `UserDefaults` key for the title size ratio.
  public static let titleRatioDefaultsKey = "editorTitleRatio"
  /// The default title size as a multiple of the base size (28:17, so a
  /// 28 pt title over a 17 pt body).
  public static let defaultTitleRatio: CGFloat = 28.0 / 17.0
  /// The title size ratios ``EditorSettingsForm`` offers.
  public static let titleRatioRange: ClosedRange<Double> = 1.0...2.5

  /// The `UserDefaults` key for the code size ratio.
  public static let codeRatioDefaultsKey = "editorCodeRatio"
  /// The default code size as a multiple of the base size.
  public static let defaultCodeRatio: CGFloat = 1.0
  /// The code size ratios ``EditorSettingsForm`` offers.
  public static let codeRatioRange: ClosedRange<Double> = 0.6...1.6

  /// The `UserDefaults` key for the max text column width.
  public static let maxTextWidthDefaultsKey = "editorMaxTextWidth"
  /// The default max width of the centered text column, in points.
  public static let defaultMaxTextWidth: CGFloat = 720
  /// The max text column widths ``EditorSettingsForm`` offers, in points.
  public static let maxTextWidthRange: ClosedRange<Double> = 400...1200

  /// The `UserDefaults` key for the minimum horizontal padding.
  public static let horizontalPaddingDefaultsKey = "editorHorizontalPadding"
  /// The default minimum padding on each side of the text column, in points.
  public static let defaultHorizontalPadding: CGFloat = 16
  /// The horizontal paddings ``EditorSettingsForm`` offers, in points.
  public static let horizontalPaddingRange: ClosedRange<Double> = 0...160

  /// The `UserDefaults` key for the vertical padding.
  public static let verticalPaddingDefaultsKey = "editorVerticalPadding"
  /// The default padding above and below the text column, in points.
  public static let defaultVerticalPadding: CGFloat = 24
  /// The vertical paddings ``EditorSettingsForm`` offers, in points.
  public static let verticalPaddingRange: ClosedRange<Double> = 0...160

  /// The `UserDefaults` key for the experimental tables flag.
  public static let tablesDefaultsKey = "editorTablesEnabled"
  /// Table rendering is experimental, so it stays off unless a host opts in.
  public static let defaultTablesEnabled = false

  /// The default list bullet style. Its `UserDefaults` key is
  /// ``ListBulletStyle/defaultsKey``.
  public static let defaultListBulletStyle: ListBulletStyle = .asTyped

  // Read and written only on the main actor (the editor and its highlighter),
  // but `TextStyle.font` is nonisolated, so opt out of the global-actor check.
  nonisolated(unsafe) static var current: EditorFont = {
    UserDefaults.standard.string(forKey: EditorFont.defaultsKey)
      .flatMap(EditorFont.init(rawValue:)) ?? .system
  }()

  /// The body point size; title and heading scale proportionally from it.
  nonisolated(unsafe) static var baseSize: CGFloat = {
    let saved = UserDefaults.standard.double(forKey: sizeDefaultsKey)
    return saved > 0 ? CGFloat(saved) : defaultBaseSize
  }()

  /// The foreground colors applied to markdown constructs. Set by the editor
  /// from ``MarkdownEditor/editorColorScheme(_:)``.
  nonisolated(unsafe) static var colorScheme: EditorColorScheme = .standard

  /// The body line height, as a multiple of the font's natural line height.
  nonisolated(unsafe) static var lineHeightMultiple: CGFloat = {
    let saved = UserDefaults.standard.double(forKey: lineHeightDefaultsKey)
    return saved > 0 ? CGFloat(saved) : defaultLineHeightMultiple
  }()

  /// Title's size as a multiple of `baseSize`. Heading scales proportionally
  /// with it, floored at 1x so it never shrinks to body size or below.
  nonisolated(unsafe) static var titleRatio: CGFloat = {
    let saved = UserDefaults.standard.double(forKey: titleRatioDefaultsKey)
    return saved > 0 ? CGFloat(saved) : defaultTitleRatio
  }()

  /// Inline and block code's size as a multiple of `baseSize`, applied
  /// regardless of the surrounding construct's own size — a code span inside
  /// a title renders at the code size, not the title's.
  nonisolated(unsafe) static var codeRatio: CGFloat = {
    let saved = UserDefaults.standard.double(forKey: codeRatioDefaultsKey)
    return saved > 0 ? CGFloat(saved) : defaultCodeRatio
  }()

  /// Whether a concealed marker reveals at the span or the whole line. Read
  /// by ``TextViewEditor/Coordinator`` on every glyph-generation pass, so
  /// changing it takes effect on the next keystroke or selection change with
  /// no separate invalidation.
  nonisolated(unsafe) static var revealMode: MarkerRevealMode = {
    UserDefaults.standard.string(forKey: MarkerRevealMode.defaultsKey)
      .flatMap(MarkerRevealMode.init(rawValue:)) ?? .span
  }()

  /// The width of the centered text column the document lays out in, in
  /// points; the scroll view itself still fills the window. Read by
  /// `EditorTextView` on every resize (macOS) / layout pass (iOS) to
  /// recompute the centering inset.
  nonisolated(unsafe) static var maxTextWidth: CGFloat = {
    let saved = UserDefaults.standard.double(forKey: maxTextWidthDefaultsKey)
    return saved > 0 ? CGFloat(saved) : defaultMaxTextWidth
  }()

  /// The minimum breathing room on each side of the text column, in points.
  /// It sets the side inset on narrow views and is the floor the centering
  /// inset never drops below on wide ones. Read by `EditorTextView` on every
  /// resize (macOS) / layout pass (iOS).
  nonisolated(unsafe) static var horizontalPadding: CGFloat = {
    let saved = UserDefaults.standard.object(forKey: horizontalPaddingDefaultsKey) as? Double
    return saved.map { CGFloat($0) } ?? defaultHorizontalPadding
  }()

  /// The padding above and below the text column, in points. Read by
  /// `EditorTextView` on every resize (macOS) / layout pass (iOS).
  nonisolated(unsafe) static var verticalPadding: CGFloat = {
    let saved = UserDefaults.standard.object(forKey: verticalPaddingDefaultsKey) as? Double
    return saved.map { CGFloat($0) } ?? defaultVerticalPadding
  }()

  /// Whether Markdown pipe tables render as a laid-out grid. Experimental: when
  /// off, a table stays plain monospaced-free text with its `|` and `|---|`
  /// rows visible. Read by `MarkdownHighlighter` on every parse, so changing it
  /// and restyling the document switches every table over.
  nonisolated(unsafe) static var tablesEnabled: Bool = {
    UserDefaults.standard.object(forKey: tablesDefaultsKey) as? Bool ?? defaultTablesEnabled
  }()

  /// The glyph an unordered list marker renders as. Read by
  /// ``TextViewEditor/Coordinator`` on every glyph-generation pass (see
  /// ``MarkerConcealment``), so changing it takes effect on the next layout
  /// with only a glyph invalidation, no restyle.
  nonisolated(unsafe) static var listBulletStyle: ListBulletStyle = {
    UserDefaults.standard.string(forKey: ListBulletStyle.defaultsKey)
      .flatMap(ListBulletStyle.init(rawValue:)) ?? defaultListBulletStyle
  }()
}

/// The editor's type scale: every block of text is one of these styles.
/// A style owns both the font and the paragraph treatment (line height,
/// spacing). Send ``EditorCommand/setBlockStyle(_:)`` to change a paragraph's
/// style.
public enum TextStyle: String, CaseIterable, Identifiable, Sendable {
  /// A `# ` heading, bold, sized by the title ratio.
  case title
  /// A `## ` heading, semibold, at 22:17 of the base size, scaled with the
  /// title ratio and floored at 1x.
  case heading
  /// A paragraph with no heading prefix, at the base size.
  case body

  /// The raw value, for use in `ForEach` and pickers.
  public var id: String { rawValue }

  /// A title-case name for menus and pickers.
  public var displayName: String {
    switch self {
    case .title: "Title"
    case .heading: "Heading"
    case .body: "Body"
    }
  }

  // Title's proportion is user-tunable via `Typography.titleRatio`. Heading
  // tracks it proportionally from its 22:17 baseline at the default title
  // ratio, floored at 1x so it never shrinks to body size or below. Both
  // scale as the base size changes.
  var font: PlatformFont {
    let base = Typography.baseSize
    let headingScale = Typography.titleRatio / Typography.defaultTitleRatio
    let headingRatio = max(1.0, 22.0 / 17.0 * headingScale)
    return switch self {
    case .title:
      Typography.current.font(ofSize: (base * Typography.titleRatio).rounded(), weight: .bold)
    case .heading:
      Typography.current.font(ofSize: (base * headingRatio).rounded(), weight: .semibold)
    case .body: Typography.current.font(ofSize: base, weight: .regular)
    }
  }

  // No paragraph spacing anywhere: in a markdown editor the blank line between
  // paragraphs is itself visible text, so added spacing would double up.
  //
  // The line height multiple applies to every style, not just body: headings,
  // code blocks (which inherit the body paragraph style set before `applyCode`
  // swaps in the monospaced font) and list items (which start from this style
  // in `applyListIndent`) should all grow or shrink together. Title is the
  // exception: at its larger point size the same multiple reads as looser
  // than body, so it gets a small fixed reduction, floored at 1x.
  var paragraphStyle: NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.lineHeightMultiple =
      self == .title
      ? max(1.0, Typography.lineHeightMultiple - 0.15)
      : Typography.lineHeightMultiple
    return style
  }

  var attributes: [NSAttributedString.Key: Any] {
    let color: Color = self == .body ? Typography.colorScheme.text : Typography.colorScheme.heading
    return [
      .font: font,
      .paragraphStyle: paragraphStyle,
      .foregroundColor: PlatformColor(color),
    ]
  }

  /// A suggested menu shortcut key: `1` for title, `2` for heading, and `0`
  /// for body. The editor installs no shortcuts; pair the key with modifiers
  /// in your own `keyboardShortcut(_:modifiers:)`. The example app uses ⌥⌘.
  public var shortcutKey: KeyEquivalent {
    switch self {
    case .title: "1"
    case .heading: "2"
    case .body: "0"
    }
  }

  var markdownPrefix: String {
    switch self {
    case .title: "# "
    case .heading: "## "
    case .body: ""
    }
  }

  /// Normalizes externally-pasted rich text into the editor's type system.
  ///
  /// We default to the body style, and copy over only bold/italic/underline traits from the
  /// pasted content. All `NSTextAttachment`s (inline images, list markers, etc) and fonts
  /// are dropped. Support for these are TODO.
  static func sanitize(pasted input: NSAttributedString) -> NSAttributedString {
    let output = NSMutableAttributedString()
    let full = NSRange(location: 0, length: input.length)

    input.enumerateAttributes(in: full) { attrs, range, _ in
      // Skip attachment runs outright; strip any stray U+FFFC elsewhere.
      if attrs[.attachment] != nil { return }

      let text = (input.string as NSString)
        .substring(with: range)
        .replacingOccurrences(of: "\u{FFFC}", with: "")

      // Skip empty string
      guard !text.isEmpty else { return }

      // get default body text style
      var clean = body.attributes

      // copy bold/italic traits from the original font
      let traits =
        (attrs[.font] as? PlatformFont)?
        .traits.intersection([.boldTrait, .italicTrait]) ?? []
      if !traits.isEmpty {
        clean[.font] = body.font.with(traits: traits)
      }
      // copy underline if present
      if let underline = attrs[.underlineStyle] as? Int, underline != 0 {
        clean[.underlineStyle] = underline
      }
      output.append(NSAttributedString(string: text, attributes: clean))
    }
    return output
  }
}
