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
      // Each tab sets its own size; the Settings window resizes to match.
      TabView {
        GeneralSettingsView()
          .padding(20)
          .frame(width: 420, height: 420, alignment: .top)
          .tabItem { Label("General", systemImage: "gearshape") }
        ThemeSettingsView()
          .frame(width: 560, height: 560, alignment: .top)
          .tabItem { Label("Theme", systemImage: "paintpalette") }
      }
      .navigationTitle("Settings")
    #else
      NavigationStack {
        TabView {
          GeneralSettingsView()
            .tabItem { Label("General", systemImage: "gearshape") }
          ThemeSettingsView()
            .tabItem { Label("Theme", systemImage: "paintpalette") }
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

/// The library's drop-in `EditorSettingsForm`, with its restore buttons
/// centered below it, bound to an `EditorSettings` persisted under one
/// `@AppStorage` key.
private struct GeneralSettingsView: View {
  @AppStorage(EditorSettings.defaultsKey) private var settings = EditorSettings()

  var body: some View {
    VStack(spacing: 16) {
      Form {
        EditorSettingsForm(settings: $settings)
      }
      EditorSettingsRestoreButtons(settings: $settings)
        .frame(maxWidth: .infinity)
    }
    .padding(20)
  }
}

/// The library's drop-in `EditorThemeForm`, with the Custom theme enabled, bound
/// to a theme, an appearance, and custom colors persisted under their own
/// `@AppStorage` keys.
private struct ThemeSettingsView: View {
  @AppStorage(EditorTheme.defaultsKey) private var theme = EditorTheme.system
  @AppStorage(EditorAppearance.defaultsKey) private var appearance = EditorAppearance.system
  @AppStorage(EditorCustomColors.defaultsKey) private var customColors = EditorCustomColors()

  var body: some View {
    // Grouped so the theme cards and preview span the full width. A grouped
    // form also scrolls when the Custom theme's rows exceed the window.
    Form {
      EditorThemeForm(theme: $theme, appearance: $appearance, customColors: $customColors)
    }
    .formStyle(.grouped)
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
