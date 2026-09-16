import CharmingEditor
import SwiftUI

/// The example's settings screen. The typography rows are the library's
/// `EditorSettingsForm`, bound to an `EditorSettings` persisted under one
/// `@AppStorage` key. The colorful-syntax toggle is host-specific and shows how
/// an app adds its own rows alongside the drop-in ones.
///
/// Presented as the standard Settings window (⌘,) on macOS and as a sheet on
/// iOS; both render this same view.
struct SettingsView: View {
  @AppStorage(EditorSettings.defaultsKey) private var settings = EditorSettings()
  @AppStorage(EditorColorScheme.colorfulDefaultsKey) private var colorfulSyntax = false

  #if os(iOS)
    @Environment(\.dismiss) private var dismiss
  #endif

  var body: some View {
    #if os(macOS)
      Form {
        EditorSettingsForm(settings: $settings)
        Toggle("Colorful Syntax", isOn: $colorfulSyntax)
      }
      .padding(20)
      .frame(width: 380)
    #else
      NavigationStack {
        Form {
          EditorSettingsForm(settings: $settings)
          Toggle("Colorful Syntax", isOn: $colorfulSyntax)
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

extension EditorSettings {
  /// The `@AppStorage` key the example persists its settings under.
  static let defaultsKey = "editorSettings"
}

/// The example's demo palette, showing how a host app defines its own
/// `EditorColorScheme` via the library's public initializer.
extension EditorColorScheme {
  static let colorfulDefaultsKey = "colorfulSyntax"

  static let colorful = EditorColorScheme(
    heading: .blue,
    code: .pink,
    bold: .orange,
    italic: .teal,
    listBullet: .green
  )
}
