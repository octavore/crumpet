import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// The user-selectable typeface for the editor. Each case maps to one of the
/// system's built-in font *designs*, so every style in the type scale gets a
/// matching face at its own size and weight (a serif title and serif body, etc.)
/// while still adapting to Dynamic Type and dark mode like the system font.
public enum EditorFont: String, CaseIterable, Identifiable, Sendable {
  case system
  case serif
  case rounded
  case monospaced

  public var id: String { rawValue }

  /// Key under which the choice is persisted (shared by `@AppStorage` in the UI
  /// and the `UserDefaults` read that seeds `Typography.current` at launch).
  public static let defaultsKey = "editorFont"

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

/// Global, app-wide typography state. `TextStyle.font` reads `current`, so
/// changing it and restyling the document switches the whole editor's typeface.
/// Seeded from `UserDefaults` at launch so the first render already uses the
/// saved font, then kept in sync by the editor when the setting changes.
public enum Typography {
  /// Key under which the body point size is persisted (shared by `@AppStorage`
  /// in the UI and the `UserDefaults` read that seeds `baseSize` at launch).
  public static let sizeDefaultsKey = "editorFontSize"
  public static let defaultBaseSize: CGFloat = 17
  public static let sizeRange: ClosedRange<Double> = 12...28

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
}

/// The editor's type scale: every block of text is one of these styles.
/// A style owns both the font and the paragraph treatment (line height,
/// spacing), so changing the scale here restyles the whole app.
public enum TextStyle: String, CaseIterable, Identifiable, Sendable {
  case title
  case heading
  case body

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .title: "Title"
    case .heading: "Heading"
    case .body: "Body"
    }
  }

  // Title and heading keep their proportions to the body (28:22:17 at the
  // default size) as the user-chosen base size changes.
  var font: PlatformFont {
    let base = Typography.baseSize
    return switch self {
    case .title: Typography.current.font(ofSize: (base * 28 / 17).rounded(), weight: .bold)
    case .heading:
      Typography.current.font(ofSize: (base * 22 / 17).rounded(), weight: .semibold)
    case .body: Typography.current.font(ofSize: base, weight: .regular)
    }
  }

  // No paragraph spacing anywhere: in a markdown editor the blank line between
  // paragraphs is itself visible text, so added spacing would double up.
  var paragraphStyle: NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    if self == .body {
      style.lineHeightMultiple = 1.25
    }
    return style
  }

  var attributes: [NSAttributedString.Key: Any] {
    [
      .font: font,
      .paragraphStyle: paragraphStyle,
      .foregroundColor: PlatformColor.editorText,
    ]
  }

  /// Menu shortcut: ⌥⌘1 title, ⌥⌘2 heading, ⌥⌘0 body.
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
