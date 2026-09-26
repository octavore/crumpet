import SwiftUI

/// The editor's color theme: the adaptive system colors, a built-in preset
/// family, or a host-provided ``EditorCustomColors``.
///
/// It is ``Swift/RawRepresentable`` as a `String`, so it can back an
/// `@AppStorage` property. Edit it with ``EditorThemeForm`` and apply it with
/// ``MarkdownEditor/editorTheme(_:customColors:)``:
///
/// ```swift
/// struct EditorScreen: View {
///   @AppStorage("editorTheme") private var theme = EditorTheme.system
///   @AppStorage("editorAppearance") private var appearance = EditorAppearance.system
///   @State private var text = ""
///   var body: some View {
///     MarkdownEditor(text: $text)
///       .editorTheme(theme)
///       .editorAppearance(appearance)
///   }
/// }
///
/// struct ThemeScreen: View {
///   @AppStorage("editorTheme") private var theme = EditorTheme.system
///   @AppStorage("editorAppearance") private var appearance = EditorAppearance.system
///   var body: some View {
///     Form { EditorThemeForm(theme: $theme, appearance: $appearance) }
///   }
/// }
/// ```
public enum EditorTheme: Hashable, Sendable {
  /// ``EditorColorScheme/standard``.
  case system
  /// A built-in light and dark preset pair.
  case preset(EditorColorPreset.Family)
  /// The colors in an ``EditorCustomColors``.
  case custom

  /// Whether ``EditorAppearance`` changes the theme's colors. False only for a
  /// preset family with a single variant.
  public var followsAppearance: Bool {
    if case .preset(let family) = self { return family.hasLightAndDark }
    return true
  }

  /// The scheme the theme uses under `appearance`. `customColors` supplies the
  /// colors for ``custom`` and is ignored otherwise.
  public func colorScheme(
    for appearance: ColorScheme, customColors: EditorCustomColors = EditorCustomColors()
  ) -> EditorColorScheme {
    switch self {
    case .system: .standard
    case .preset(let family): EditorColorScheme(family.preset(for: appearance))
    case .custom: customColors.colorScheme
    }
  }
}

extension EditorTheme: RawRepresentable {
  /// Reads `""` as ``system``, `"custom"` as ``custom``, and a family's raw
  /// value as ``preset(_:)``. Nil for any other string.
  public init?(rawValue: String) {
    switch rawValue {
    case "": self = .system
    case "custom": self = .custom
    default:
      guard let family = EditorColorPreset.Family(rawValue: rawValue) else { return nil }
      self = .preset(family)
    }
  }

  /// The string ``init(rawValue:)`` reads back.
  public var rawValue: String {
    switch self {
    case .system: ""
    case .custom: "custom"
    case .preset(let family): family.rawValue
    }
  }
}

/// A user-editable ``EditorColorScheme``, stored as hex strings so it can back
/// an `@AppStorage` property (the type is ``Swift/RawRepresentable`` as JSON).
/// A nil color leaves that construct at ``EditorColorScheme``'s adaptive
/// default.
public struct EditorCustomColors: Sendable {
  public var text: String?
  public var heading: String?
  public var code: String?
  public var bold: String?
  public var italic: String?
  public var link: String?
  public var listBullet: String?
  public var background: String?

  /// Creates colors with every construct at its default.
  public init() {}

  /// Copies every color of `scheme` as a hex string.
  public init(_ scheme: EditorColorScheme) {
    text = scheme.text.hexString()
    heading = scheme.heading.hexString()
    code = scheme.code.hexString()
    bold = scheme.bold.hexString()
    italic = scheme.italic.hexString()
    link = scheme.link.hexString()
    listBullet = scheme.listBullet.hexString()
    background = scheme.background.hexString()
  }

  /// The scheme built from these colors. A nil or unparseable color falls back
  /// to the default.
  public var colorScheme: EditorColorScheme {
    func color(_ hex: String?) -> Color? { hex.flatMap { Color(hex: $0) } }
    return EditorColorScheme(
      text: color(text) ?? .primary, heading: color(heading), code: color(code),
      bold: color(bold), italic: color(italic), link: color(link),
      listBullet: color(listBullet), background: color(background) ?? .editorBackground)
  }

  // Explicit `Codable` and `==` for the same reasons as on `EditorSettings`:
  // `RawRepresentable` would otherwise supply versions that go through
  // `rawValue`, which encodes `self`.
  private enum CodingKeys: String, CodingKey {
    case text, heading, code, bold, italic, link, listBullet, background
  }
}

extension EditorCustomColors: Codable {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    text = try c.decodeIfPresent(String.self, forKey: .text)
    heading = try c.decodeIfPresent(String.self, forKey: .heading)
    code = try c.decodeIfPresent(String.self, forKey: .code)
    bold = try c.decodeIfPresent(String.self, forKey: .bold)
    italic = try c.decodeIfPresent(String.self, forKey: .italic)
    link = try c.decodeIfPresent(String.self, forKey: .link)
    listBullet = try c.decodeIfPresent(String.self, forKey: .listBullet)
    background = try c.decodeIfPresent(String.self, forKey: .background)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(text, forKey: .text)
    try c.encodeIfPresent(heading, forKey: .heading)
    try c.encodeIfPresent(code, forKey: .code)
    try c.encodeIfPresent(bold, forKey: .bold)
    try c.encodeIfPresent(italic, forKey: .italic)
    try c.encodeIfPresent(link, forKey: .link)
    try c.encodeIfPresent(listBullet, forKey: .listBullet)
    try c.encodeIfPresent(background, forKey: .background)
  }
}

extension EditorCustomColors: Equatable {
  public static func == (lhs: EditorCustomColors, rhs: EditorCustomColors) -> Bool {
    lhs.text == rhs.text && lhs.heading == rhs.heading && lhs.code == rhs.code
      && lhs.bold == rhs.bold && lhs.italic == rhs.italic && lhs.link == rhs.link
      && lhs.listBullet == rhs.listBullet && lhs.background == rhs.background
  }
}

extension EditorCustomColors: RawRepresentable {
  /// Decodes the JSON in ``rawValue``. Nil when the string is not valid JSON.
  public init?(rawValue: String) {
    guard
      let data = rawValue.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(EditorCustomColors.self, from: data)
    else { return nil }
    self = decoded
  }

  /// The colors encoded as a JSON object string, or `"{}"` if encoding fails.
  public var rawValue: String {
    guard
      let data = try? JSONEncoder().encode(self),
      let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
  }
}

/// A drop-in group of rows for choosing an ``EditorTheme`` and an
/// ``EditorAppearance``. Themes are shown as a grid of swatch cards next to a
/// preview of the selected theme, both drawn in the selected appearance. The
/// appearance picker is disabled for a theme with a single variant.
///
/// Pass `customColors` to add a Custom theme with a color picker for each
/// construct, a menu that copies a preset's colors, and a reset button. The
/// color rows show only while Custom is selected.
///
/// It renders bare rows, not a container, so place it inside your own `Form`,
/// `List`, or `Section` and it inherits that chrome. On macOS the card and
/// preview row has no label, so it spans the full width in a
/// `.formStyle(.grouped)` form.
public struct EditorThemeForm: View {
  @Binding private var theme: EditorTheme
  @Binding private var appearance: EditorAppearance
  private let customColors: Binding<EditorCustomColors>?

  /// Creates the rows with the system and preset themes only.
  public init(theme: Binding<EditorTheme>, appearance: Binding<EditorAppearance>) {
    self._theme = theme
    self._appearance = appearance
    self.customColors = nil
  }

  /// Creates the rows with a Custom theme that edits `customColors`.
  public init(
    theme: Binding<EditorTheme>, appearance: Binding<EditorAppearance>,
    customColors: Binding<EditorCustomColors>
  ) {
    self._theme = theme
    self._appearance = appearance
    self.customColors = customColors
  }

  @Environment(\.colorScheme) private var systemAppearance

  /// Every selectable theme, in display order.
  private var themes: [EditorTheme] {
    [.system] + EditorColorPreset.Family.allCases.map { .preset($0) }
      + (customColors == nil ? [] : [.custom])
  }

  private func title(for theme: EditorTheme) -> String {
    switch theme {
    case .system: "System"
    case .preset(let family): family.displayName
    case .custom: "Custom"
    }
  }

  /// The theme rows, without a containing `Form`.
  public var body: some View {
    let resolved = appearance.resolved(systemAppearance)
    let custom = customColors?.wrappedValue ?? EditorCustomColors()
    let preview = ThemePreview(
      scheme: theme.colorScheme(for: resolved, customColors: custom), appearance: resolved)
    let cards = ForEach(themes, id: \.self) { option in
      ThemeCard(
        title: title(for: option),
        scheme: option.colorScheme(for: resolved, customColors: custom),
        appearance: resolved,
        isSelected: option == theme
      ) {
        theme = option
      }
    }

    #if os(macOS)
      // The cards on the left and the preview on the right, stretched to the
      // height of the card grid.
      HStack(alignment: .top, spacing: 16) {
        LazyVGrid(
          columns: Array(repeating: GridItem(.fixed(84), spacing: 10), count: 2), spacing: 10
        ) {
          cards
        }
        .fixedSize()
        preview
      }
      .fixedSize(horizontal: false, vertical: true)
      .padding(.vertical, 4)
    #else
      VStack(spacing: 12) {
        preview.frame(height: 170)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 10) {
          cards
        }
      }
      .padding(.vertical, 4)
    #endif

    if theme != .custom {
      Picker("Appearance", selection: $appearance) {
        ForEach(EditorAppearance.allCases) { appearance in
          Text(appearance.displayName).tag(appearance)
        }
      }
      .disabled(!theme.followsAppearance)
      #if os(iOS)
        .pickerStyle(.inline)
      #endif
    }

    if theme == .custom, let customColors {
      CustomColorRows(colors: customColors)
    }
  }
}

/// A selectable swatch for one theme: a heading sample in the heading color and
/// bars in the text, bold, italic, code, and link colors, on the theme's
/// background. Adaptive colors resolve in `appearance`.
private struct ThemeCard: View {
  let title: String
  let scheme: EditorColorScheme
  let appearance: ColorScheme
  let isSelected: Bool
  let action: () -> Void

  private var barColors: [Color] {
    [scheme.text, scheme.bold, scheme.italic, scheme.code, scheme.link]
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: 5) {
        swatch
        Text(title)
          .font(.caption)
          .lineLimit(1)
          .foregroundStyle(isSelected ? .primary : .secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var swatch: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Aa")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(scheme.heading)
      HStack(spacing: 3) {
        ForEach(barColors.indices, id: \.self) { index in
          Capsule().fill(barColors[index]).frame(height: 4)
        }
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(scheme.background)
    .overlay {
      RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12))
    }
    .environment(\.colorScheme, appearance)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .padding(3)
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
    }
  }
}

/// Sample rendered text in `scheme`: a heading, a paragraph with bold and
/// italic text and a link, a bulleted list, and a code block. Adaptive colors resolve in
/// `appearance`.
///
/// It is drawn with SwiftUI `Text`, not a ``MarkdownEditor``, because the
/// editor's typography and colors live in process-wide `Typography` state that
/// a second editor instance would overwrite.
private struct ThemePreview: View {
  let scheme: EditorColorScheme
  let appearance: ColorScheme

  var body: some View {
    let bold = Text("bold").bold().foregroundStyle(scheme.bold)
    let italic = Text("italic").italic().foregroundStyle(scheme.italic)
    let link = Text("link \(Image(systemName: "link"))").foregroundStyle(scheme.link)

    VStack(alignment: .leading, spacing: 10) {
      Text("Heading")
        .font(.title2.bold())
        .foregroundStyle(scheme.heading)
      Text("Body text with \(bold), \(italic), and a \(link).")
        .foregroundStyle(scheme.text)
        .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 4) {
        ForEach(["List item", "Another item"], id: \.self) { item in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(scheme.listBullet)
            Text(item).foregroundStyle(scheme.text)
          }
        }
      }
      Text("func greet() {\n  print(\"Hello\")\n}")
        .font(.callout.monospaced())
        .foregroundStyle(scheme.code)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(scheme.background)
    .overlay {
      RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12))
    }
    .environment(\.colorScheme, appearance)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .accessibilityHidden(true)
  }
}

/// The Custom theme's rows: a base menu, one color picker per construct, and
/// a reset button. Applying a base or resetting changes `revision`, which
/// recreates the pickers so they show the new colors.
private struct CustomColorRows: View {
  @Binding var colors: EditorCustomColors
  @State private var revision = 0
  @State private var basePreset: EditorColorPreset?

  /// Starts with the preset whose colors equal `colors`, if any.
  init(colors: Binding<EditorCustomColors>) {
    self._colors = colors
    self._basePreset = State(
      initialValue: EditorColorPreset.allCases.first {
        EditorCustomColors(EditorColorScheme($0)) == colors.wrappedValue
      })
  }

  /// The colors of the base preset, or the defaults when no base is chosen.
  private var baseColors: EditorCustomColors {
    basePreset.map { EditorCustomColors(EditorColorScheme($0)) } ?? EditorCustomColors()
  }

  /// Choosing a preset copies its colors.
  private var base: Binding<EditorColorPreset?> {
    Binding(
      get: { basePreset },
      set: { preset in
        basePreset = preset
        colors = baseColors
        revision += 1
      })
  }

  var body: some View {
    Picker("Base", selection: base) {
      Text("Choose...").tag(EditorColorPreset?.none)
      ForEach(EditorColorPreset.allCases) { preset in
        Text(preset.displayName).tag(EditorColorPreset?.some(preset))
      }
    }

    Group {
      ColorPickerRow("Text", hex: $colors.text)
      ColorPickerRow("Heading", hex: $colors.heading)
      ColorPickerRow("Code", hex: $colors.code)
      ColorPickerRow("Bold", hex: $colors.bold)
      ColorPickerRow("Italic", hex: $colors.italic)
      ColorPickerRow("Link", hex: $colors.link)
      ColorPickerRow("List Bullet", hex: $colors.listBullet)
      ColorPickerRow("Background", hex: $colors.background, fallback: .editorBackground)
    }
    .id(revision)

    Button("Reset") {
      colors = baseColors
      revision += 1
    }
    .disabled(colors == baseColors)
  }
}

/// A `ColorPicker` bound to a hex string. The picker edits a local `Color`,
/// and changes are written to `hex` after a 200ms pause. Writing on every
/// drag update re-renders the form and makes the picker's reticle jitter.
private struct ColorPickerRow: View {
  let title: String
  @Binding var hex: String?
  let fallback: Color
  @State private var color: Color
  @State private var pendingWrite: Task<Void, Never>?

  init(_ title: String, hex: Binding<String?>, fallback: Color = .primary) {
    self.title = title
    self._hex = hex
    self.fallback = fallback
    self._color = State(initialValue: hex.wrappedValue.flatMap { Color(hex: $0) } ?? fallback)
  }

  var body: some View {
    ColorPicker(title, selection: $color)
      .onChange(of: color) { _, newValue in
        pendingWrite?.cancel()
        pendingWrite = Task {
          try? await Task.sleep(for: .milliseconds(200))
          guard !Task.isCancelled else { return }
          let newHex = newValue.hexString()
          if newHex != hex { hex = newHex }
        }
      }
      .onChange(of: hex) { _, newValue in
        let external = newValue.flatMap { Color(hex: $0) } ?? fallback
        if external.hexString() != color.hexString() { color = external }
      }
  }
}

extension Color {
  /// Encodes this color as `#RRGGBBAA`, the inverse of `Color(hex:)`.
  /// Resolves against a default `EnvironmentValues`, so a `Color` that
  /// depends on the environment (e.g. `.primary`) is captured at whatever it
  /// resolves to now, not kept dynamic.
  fileprivate func hexString() -> String {
    let resolved = resolve(in: EnvironmentValues())
    // Components are gamma-encoded extended sRGB, matching `Color(hex:)`.
    // Wide-gamut picks can fall outside 0...1, so they are clamped.
    func byte(_ component: Float) -> Int {
      Int((min(max(component, 0), 1) * 255).rounded())
    }
    return String(
      format: "#%02X%02X%02X%02X",
      byte(resolved.red), byte(resolved.green), byte(resolved.blue), byte(resolved.opacity))
  }
}
