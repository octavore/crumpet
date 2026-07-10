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

  #if os(iOS)
    @Environment(\.dismiss) private var dismiss
  #endif

  var body: some View {
    #if os(macOS)
      Form {
        fontPicker
        fontSizeStepper
      }
      .padding(20)
      .frame(width: 380)
    #else
      NavigationStack {
        Form {
          fontPicker
          fontSizeStepper
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
}
