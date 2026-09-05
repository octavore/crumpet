import SwiftUI

/// A bundle of the editor's user-tunable typography options, ready to persist
/// as one value and apply to a ``MarkdownEditor`` in a single call.
///
/// It exists so a host app can offer a settings screen without wiring each
/// option by hand. Store one with `@AppStorage` (the type is
/// ``Swift/RawRepresentable`` as JSON), edit it with ``EditorSettingsForm``,
/// and pass it to ``MarkdownEditor/editorSettings(_:)``:
///
/// ```swift
/// struct EditorScreen: View {
///   @AppStorage("editorSettings") private var settings = EditorSettings()
///   @State private var text = ""
///   var body: some View {
///     MarkdownEditor(text: $text).editorSettings(settings)
///   }
/// }
///
/// struct SettingsScreen: View {
///   @AppStorage("editorSettings") private var settings = EditorSettings()
///   var body: some View {
///     Form { EditorSettingsForm(settings: $settings) }
///   }
/// }
/// ```
///
/// Colors are deliberately out of scope: palettes are host-defined, so keep
/// using ``MarkdownEditor/editorColorScheme(_:)`` for those.
public struct EditorSettings: Codable, Equatable, Sendable {
  /// The editor typeface.
  public var font: EditorFont
  /// Base body point size in points; titles, headings, and code scale from it.
  public var fontSize: Double
  /// Body line height as a multiple of the font's natural line height.
  public var lineHeight: Double
  /// Title size as a multiple of the base body size.
  public var titleRatio: Double
  /// Inline and block code size as a multiple of the base body size.
  public var codeRatio: Double
  /// Max width of the centered text column, in points.
  public var maxWidth: Double
  /// When concealed markdown markers reveal themselves.
  public var markerRevealMode: MarkerRevealMode
  /// Experimental: render Markdown pipe tables as a laid-out grid. Off by
  /// default; when off a table stays plain text with its `|` separators and
  /// `|---|` row visible.
  public var experimentalTables: Bool
  /// The glyph unordered list markers (`-`, `*`, `+`) render as. Defaults to
  /// ``ListBulletStyle/asTyped``, which leaves the author's character alone.
  public var listBullet: ListBulletStyle

  public init(
    font: EditorFont = .system,
    fontSize: Double = Double(Typography.defaultBaseSize),
    lineHeight: Double = Double(Typography.defaultLineHeightMultiple),
    titleRatio: Double = Double(Typography.defaultTitleRatio),
    codeRatio: Double = Double(Typography.defaultCodeRatio),
    maxWidth: Double = Double(Typography.defaultMaxTextWidth),
    markerRevealMode: MarkerRevealMode = .span,
    experimentalTables: Bool = Typography.defaultTablesEnabled,
    listBullet: ListBulletStyle = Typography.defaultListBulletStyle
  ) {
    self.font = font
    self.fontSize = fontSize
    self.lineHeight = lineHeight
    self.titleRatio = titleRatio
    self.codeRatio = codeRatio
    self.maxWidth = maxWidth
    self.markerRevealMode = markerRevealMode
    self.experimentalTables = experimentalTables
    self.listBullet = listBullet
  }

  // An explicit `Codable` implementation, not the compiler-synthesized one.
  // Because the type is also `RawRepresentable` with a `Codable` `RawValue`,
  // the standard library would otherwise route `encode(to:)` through `rawValue`,
  // which itself calls `JSONEncoder().encode(self)`, recursing until the stack
  // overflows. Spelling the members out keeps encoding tied to the stored
  // properties.
  private enum CodingKeys: String, CodingKey {
    case font, fontSize, lineHeight, titleRatio, codeRatio, maxWidth, markerRevealMode
    case experimentalTables, listBullet
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = EditorSettings()
    font = try c.decodeIfPresent(EditorFont.self, forKey: .font) ?? d.font
    fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
    lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight) ?? d.lineHeight
    titleRatio = try c.decodeIfPresent(Double.self, forKey: .titleRatio) ?? d.titleRatio
    codeRatio = try c.decodeIfPresent(Double.self, forKey: .codeRatio) ?? d.codeRatio
    maxWidth = try c.decodeIfPresent(Double.self, forKey: .maxWidth) ?? d.maxWidth
    markerRevealMode =
      try c.decodeIfPresent(MarkerRevealMode.self, forKey: .markerRevealMode) ?? d.markerRevealMode
    experimentalTables =
      try c.decodeIfPresent(Bool.self, forKey: .experimentalTables) ?? d.experimentalTables
    listBullet =
      try c.decodeIfPresent(ListBulletStyle.self, forKey: .listBullet) ?? d.listBullet
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(font, forKey: .font)
    try c.encode(fontSize, forKey: .fontSize)
    try c.encode(lineHeight, forKey: .lineHeight)
    try c.encode(titleRatio, forKey: .titleRatio)
    try c.encode(codeRatio, forKey: .codeRatio)
    try c.encode(maxWidth, forKey: .maxWidth)
    try c.encode(markerRevealMode, forKey: .markerRevealMode)
    try c.encode(experimentalTables, forKey: .experimentalTables)
    try c.encode(listBullet, forKey: .listBullet)
  }
}

extension EditorSettings: RawRepresentable {
  /// JSON round-trip so the value can back an `@AppStorage` property. A missing
  /// or unparseable key falls back to the `@AppStorage` default rather than
  /// throwing.
  public init?(rawValue: String) {
    guard
      let data = rawValue.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(EditorSettings.self, from: data)
    else { return nil }
    self = decoded
  }

  public var rawValue: String {
    guard
      let data = try? JSONEncoder().encode(self),
      let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
  }
}

/// A drop-in group of rows for editing an ``EditorSettings``: a font picker,
/// size and ratio sliders, a marker-reveal picker, a list-bullet picker, and a
/// restore-defaults button.
///
/// It renders bare rows, not a container, so place it inside your own `Form`,
/// `List`, or `Section` and it inherits that chrome.
public struct EditorSettingsForm: View {
  @Binding private var settings: EditorSettings

  public init(settings: Binding<EditorSettings>) {
    self._settings = settings
  }

  public var body: some View {
    Picker("Editor Font", selection: $settings.font) {
      ForEach(EditorFont.allCases) { font in
        // Render each option in its own typeface so the menu previews it.
        Text(font.displayName).font(font.previewFont).tag(font)
      }
    }
    #if os(iOS)
      .pickerStyle(.inline)
    #endif

    SteppedSlider(
      "Text Size", value: $settings.fontSize, in: Typography.sizeRange, step: 1,
      format: { "\(Int($0)) pt" })
    SteppedSlider(
      "Line Height", value: $settings.lineHeight, in: Typography.lineHeightRange, step: 0.05,
      format: { String(format: "%.2f×", $0) })
    SteppedSlider(
      "Title Size", value: $settings.titleRatio, in: Typography.titleRatioRange, step: 0.05,
      format: { String(format: "%.2f×", $0) })
    SteppedSlider(
      "Code Size", value: $settings.codeRatio, in: Typography.codeRatioRange, step: 0.05,
      format: { String(format: "%.2f×", $0) })
    SteppedSlider(
      "Max Width", value: $settings.maxWidth, in: Typography.maxTextWidthRange, step: 20,
      format: { "\(Int($0)) pt" })

    Picker("Reveal Markers", selection: $settings.markerRevealMode) {
      ForEach(MarkerRevealMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }
    #if os(iOS)
      .pickerStyle(.inline)
    #endif

    LabeledContent("Tables") {
      Toggle("Render pipe tables as a grid (experimental)", isOn: $settings.experimentalTables)
    }

    Picker("List Bullet", selection: $settings.listBullet) {
      ForEach(ListBulletStyle.allCases) { style in
        Text(style.displayName).tag(style)
      }
    }
    #if os(iOS)
      .pickerStyle(.inline)
    #endif

    LabeledContent("Defaults") {
      Button("Restore") { settings = EditorSettings() }
        .disabled(settings == EditorSettings())
    }
  }
}

/// A `LabeledContent` row holding a `Slider` that snaps to `step` without
/// drawing tick marks, with the current value shown after the track. The label
/// sits in the form's leading label column like the picker rows.
private struct SteppedSlider: View {
  private let title: String
  @Binding private var value: Double
  private let range: ClosedRange<Double>
  private let step: Double
  private let format: (Double) -> String

  // The `Slider` drives this continuous value directly. It never reads back the
  // snapped value mid-drag, so it keeps publishing updates as you scrub. The
  // snapped result is written to `value` on every change.
  @State private var sliderValue: Double

  init(
    _ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
    format: @escaping (Double) -> String
  ) {
    self.title = title
    self._value = value
    self.range = range
    self.step = step
    self.format = format
    self._sliderValue = State(initialValue: value.wrappedValue)
  }

  private func snap(_ raw: Double) -> Double {
    min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
  }

  var body: some View {
    LabeledContent(title) {
      HStack {
        Slider(value: $sliderValue, in: range)
          .onChange(of: sliderValue) { _, raw in
            let snapped = snap(raw)
            if snapped != value { value = snapped }
          }
          .onChange(of: value) { _, external in
            // Resync when the value changes from outside, e.g. Restore Defaults.
            if snap(sliderValue) != external { sliderValue = external }
          }
        Text(format(value))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .frame(minWidth: 52, alignment: .trailing)
      }
    }
  }
}
