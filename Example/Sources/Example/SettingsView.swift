import CharmingEditor
import SwiftUI

/// The example's settings screen: a `TabView` shell with one tab per settings
/// group, matching macOS's standard Settings window layout (⌘,). On iOS the
/// same view is presented from `EditorView` as a sheet.
struct SettingsView: View {
  #if os(iOS)
    @Environment(\.dismiss) private var dismiss
  #endif

  var body: some View {
    #if os(macOS)
      TabView {
        GeneralSettingsView()
          .tabItem { Label("General", systemImage: "gearshape") }
        ColorSettingsView()
          .tabItem { Label("Colors", systemImage: "paintpalette") }
      }
      .padding(20)
      .frame(width: 420, height: 420, alignment: .top)
      .navigationTitle("Settings")
    #else
      NavigationStack {
        TabView {
          GeneralSettingsView()
            .tabItem { Label("General", systemImage: "gearshape") }
          ColorSettingsView()
            .tabItem { Label("Colors", systemImage: "paintpalette") }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
      }
    #endif
  }
}

/// The library's drop-in `EditorSettingsForm`, bound to an `EditorSettings`
/// persisted under one `@AppStorage` key.
private struct GeneralSettingsView: View {
  @AppStorage(EditorSettings.defaultsKey) private var settings = EditorSettings()

  var body: some View {
    Form {
      EditorSettingsForm(settings: $settings)
    }
    .padding(20)
  }
}

/// Host-specific: shows how an app builds its own `EditorColorScheme` through
/// live `ColorPicker` rows rather than a fixed palette, persisting the result
/// as hex strings under one `@AppStorage` key.
private struct ColorSettingsView: View {
  @AppStorage(EditorColorScheme.customColorsEnabledKey) private var enabled = false
  @AppStorage(CustomColorScheme.defaultsKey) private var customColors = CustomColorScheme()
  @State private var selectedPreset = ""

  var body: some View {
    Form {
      Toggle("Use Custom Colors", isOn: $enabled)

      Picker("Preset", selection: $selectedPreset) {
        Text("Choose a Preset…").tag("")
        ForEach(ColorPreset.all) { preset in
          Text(preset.name).tag(preset.name)
        }
      }
      .fixedSize()
      .onChange(of: selectedPreset) { _, name in
        guard let preset = ColorPreset.all.first(where: { $0.name == name }) else { return }
        customColors = preset.scheme
        enabled = true
      }

      Section {
        colorRow("Text", \.text)
        colorRow("Heading", \.heading)
        colorRow("Code", \.code)
        colorRow("Bold", \.bold)
        colorRow("Italic", \.italic)
        colorRow("List Bullet", \.listBullet)
        colorRow("Background", \.background, fallback: .editorBackground)
      }
      .disabled(!enabled)

      Button("Reset to Defaults") {
        customColors = CustomColorScheme()
        selectedPreset = ""
      }
      .disabled(!enabled)
    }
    .padding(20)
  }

  private func colorRow(
    _ title: String, _ keyPath: WritableKeyPath<CustomColorScheme, String?>,
    fallback: Color = .primary
  ) -> some View {
    ColorPicker(
      title,
      selection: Binding(
        get: { customColors[keyPath: keyPath].flatMap { Color(hex: $0) } ?? fallback },
        set: { customColors[keyPath: keyPath] = $0.toHex() }))
  }
}

/// A named set of hex colors for the five customizable constructs, drawn from
/// a well-known color scheme. Choosing a preset in `ColorSettingsView` applies
/// it as the current `CustomColorScheme`.
private struct ColorPreset: Identifiable {
  let name: String
  let text: String
  let heading: String
  let code: String
  let bold: String
  let italic: String
  let listBullet: String
  let background: String

  var id: String { name }

  var scheme: CustomColorScheme {
    CustomColorScheme(
      text: text, heading: heading, code: code, bold: bold, italic: italic,
      listBullet: listBullet, background: background)
  }

  // Each palette's `text` is chosen for contrast against its own
  // `background`, independent of the system's light/dark appearance —
  // without it, a light preset in dark mode (or a dark preset in light mode)
  // inherits `.primary`, which can land unreadably close to the background.
  static let all: [ColorPreset] = [
    ColorPreset(
      name: "Nord", text: "#D8DEE9", heading: "#88C0D0", code: "#BF616A", bold: "#EBCB8B",
      italic: "#A3BE8C", listBullet: "#81A1C1", background: "#2E3440"),
    ColorPreset(
      name: "Dracula", text: "#F8F8F2", heading: "#BD93F9", code: "#FF79C6", bold: "#F1FA8C",
      italic: "#50FA7B", listBullet: "#8BE9FD", background: "#282A36"),
    ColorPreset(
      name: "Solarized", text: "#586E75", heading: "#268BD2", code: "#DC322F", bold: "#B58900",
      italic: "#859900", listBullet: "#2AA198", background: "#FDF6E3"),
    ColorPreset(
      name: "Monokai", text: "#F8F8F2", heading: "#66D9EF", code: "#F92672", bold: "#E6DB74",
      italic: "#A6E22E", listBullet: "#FD971F", background: "#272822"),
    ColorPreset(
      name: "Gruvbox", text: "#EBDBB2", heading: "#83A598", code: "#FB4934", bold: "#FABD2F",
      italic: "#B8BB26", listBullet: "#D3869B", background: "#282828"),
  ]
}

extension CustomColorScheme {
  fileprivate init(
    text: String, heading: String, code: String, bold: String, italic: String,
    listBullet: String, background: String
  ) {
    self.init()
    self.text = text
    self.heading = heading
    self.code = code
    self.bold = bold
    self.italic = italic
    self.listBullet = listBullet
    self.background = background
  }
}

extension EditorSettings {
  /// The `@AppStorage` key the example persists its settings under.
  static let defaultsKey = "editorSettings"
}

extension EditorColorScheme {
  /// Whether the example applies `CustomColorScheme`'s colors instead of
  /// ``EditorColorScheme/standard``.
  static let customColorsEnabledKey = "customColorsEnabled"
}

/// A user-editable `EditorColorScheme`, stored as hex strings so it round-trips
/// through `@AppStorage`. A nil field means "not customized yet": the color
/// picker falls back to `.primary` for display, but the built scheme leaves
/// that construct at `EditorColorScheme`'s own adaptive default.
struct CustomColorScheme: Equatable, RawRepresentable {
  var text: String?
  var heading: String?
  var code: String?
  var bold: String?
  var italic: String?
  var listBullet: String?
  var background: String?

  init() {}

  // `Storage` carries the actual `Codable` conformance. `CustomColorScheme`
  // itself must stay non-`Codable`: combined with `RawRepresentable`, Swift's
  // synthesized `encode(to:)` would just encode `rawValue`, whose getter
  // encodes `self` to produce that string — infinite recursion.
  private struct Storage: Codable {
    var text: String?
    var heading: String?
    var code: String?
    var bold: String?
    var italic: String?
    var listBullet: String?
    var background: String?
  }

  init?(rawValue: String) {
    guard let data = rawValue.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(Storage.self, from: data)
    else { return nil }
    text = decoded.text
    heading = decoded.heading
    code = decoded.code
    bold = decoded.bold
    italic = decoded.italic
    listBullet = decoded.listBullet
    background = decoded.background
  }

  var rawValue: String {
    let storage = Storage(
      text: text, heading: heading, code: code, bold: bold, italic: italic,
      listBullet: listBullet, background: background)
    guard let data = try? JSONEncoder().encode(storage),
      let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
  }

  var editorColorScheme: EditorColorScheme {
    EditorColorScheme(
      text: text.flatMap { Color(hex: $0) } ?? .primary,
      heading: heading.flatMap { Color(hex: $0) },
      code: code.flatMap { Color(hex: $0) },
      bold: bold.flatMap { Color(hex: $0) },
      italic: italic.flatMap { Color(hex: $0) },
      listBullet: listBullet.flatMap { Color(hex: $0) },
      background: background.flatMap { Color(hex: $0) } ?? .editorBackground)
  }

  /// The `@AppStorage` key the example persists the custom palette under.
  static let defaultsKey = "customColorScheme"
}

extension Color {
  /// Encodes this color as `#RRGGBBAA`, the inverse of `Color(hex:)`.
  /// Resolves against a default `EnvironmentValues`, so a `Color` that
  /// depends on the environment (e.g. `.primary`) is captured at whatever it
  /// resolves to right now, not kept dynamic.
  fileprivate func toHex() -> String {
    let resolved = resolve(in: EnvironmentValues())
    return String(
      format: "#%02X%02X%02X%02X",
      Int((resolved.red * 255).rounded()),
      Int((resolved.green * 255).rounded()),
      Int((resolved.blue * 255).rounded()),
      Int((resolved.opacity * 255).rounded()))
  }
}
