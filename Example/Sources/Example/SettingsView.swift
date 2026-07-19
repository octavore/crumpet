import CharmingEditor
import SwiftUI

/// The example's settings: just the editor typeface and size. Both are persisted
/// via `@AppStorage` under the CharmingEditor library's keys, the same keys
/// `EditorView` reads, so a change here restyles the editor live.
///
/// Presented as the standard Settings window (⌘,) on macOS and as a sheet on
/// iOS; both render this same view.
struct SettingsView: View {
  @AppStorage(EditorFont.defaultsKey) private var fontFamily: EditorFont = .system
  @AppStorage(Typography.sizeDefaultsKey) private var fontSize: Double = .init(
    Typography.defaultBaseSize)
  @AppStorage(Typography.lineHeightDefaultsKey) private var lineHeight: Double = .init(
    Typography.defaultLineHeightMultiple)
  @AppStorage(MarkerRevealMode.defaultsKey) private var revealMode: MarkerRevealMode = .span
  @AppStorage(EditorColorScheme.colorfulDefaultsKey) private var colorfulSyntax = false

  #if os(iOS)
    @Environment(\.dismiss) private var dismiss
  #endif

  var body: some View {
    #if os(macOS)
      Form {
        fontPicker
        fontSizeStepper
        lineHeightStepper
        revealModePicker
        colorfulToggle
      }
      .padding(20)
      .frame(width: 380)
    #else
      NavigationStack {
        Form {
          fontPicker
          fontSizeStepper
          lineHeightStepper
          revealModePicker
          colorfulToggle
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

  private var fontPicker: some View {
    Picker("Editor Font", selection: $fontFamily) {
      ForEach(EditorFont.allCases) { font in
        // Render each option in its own typeface so the menu previews the choice.
        Text(font.displayName).font(font.previewFont).tag(font)
      }
    }
    #if os(iOS)
      .pickerStyle(.inline)
    #endif
  }

  private var fontSizeStepper: some View {
    Stepper(value: $fontSize, in: Typography.sizeRange, step: 1) {
      Text("Text Size: \(Int(fontSize)) pt")
    }
  }

  private var lineHeightStepper: some View {
    Stepper(value: $lineHeight, in: Typography.lineHeightRange, step: 0.05) {
      Text("Line Height: \(lineHeight, specifier: "%.2f")×")
    }
  }

  private var revealModePicker: some View {
    Picker("Reveal Markers", selection: $revealMode) {
      ForEach(MarkerRevealMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }
    #if os(iOS)
      .pickerStyle(.inline)
    #endif
  }

  private var colorfulToggle: some View {
    Toggle("Colorful Syntax", isOn: $colorfulSyntax)
  }
}

/// The example's demo palette, showing how a host app defines its own
/// `EditorColorScheme` via the library's public initializer.
extension EditorColorScheme {
  static let colorfulDefaultsKey = "colorfulSyntax"

  static let colorful = EditorColorScheme(
    heading: .blue,
    code: .pink,
    bold: .orange,
    italic: .teal
  )
}
