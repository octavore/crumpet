import Crumpet
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

/// The library's drop-in `EditorThemeForm`, with the Custom theme enabled, bound
/// to a theme, an appearance, and custom colors persisted under their own
/// `@AppStorage` keys.
private struct ColorSettingsView: View {
  @AppStorage(EditorTheme.defaultsKey) private var theme = EditorTheme.system
  @AppStorage(EditorAppearance.defaultsKey) private var appearance = EditorAppearance.system
  @AppStorage(EditorCustomColors.defaultsKey) private var customColors = EditorCustomColors()

  var body: some View {
    Form {
      EditorThemeForm(theme: $theme, appearance: $appearance, customColors: $customColors)
    }
    .padding(20)
  }
}

extension EditorSettings {
  /// The `@AppStorage` key the example persists its settings under.
  static let defaultsKey = "editorSettings"
}

extension EditorTheme {
  /// The `@AppStorage` key the example persists the theme under.
  static let defaultsKey = "editorTheme"
}

extension EditorAppearance {
  /// The `@AppStorage` key the example persists the appearance under.
  static let defaultsKey = "editorAppearance"
}

extension EditorCustomColors {
  /// The `@AppStorage` key the example persists the custom colors under.
  static let defaultsKey = "customColorScheme"
}
