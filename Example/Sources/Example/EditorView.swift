import CharmingEditor
import SwiftUI

/// The editing surface: the CharmingEditor library's `MarkdownEditor` bound
/// straight to the store's document.
struct EditorView: View {
  @Bindable var store: PageStore
  @State private var commands = EditorCommands()

  // Shared with SettingsView through the same defaults keys; changing them
  // there re-renders this view and restyles the editor.
  @AppStorage(EditorSettings.defaultsKey) private var settings = EditorSettings()
  @AppStorage(EditorColorScheme.customColorsEnabledKey) private var customColorsEnabled = false
  @AppStorage(CustomColorScheme.defaultsKey) private var customColors = CustomColorScheme()

  #if os(iOS)
    @State private var showingSettings = false
  #endif

  private var colorScheme: EditorColorScheme {
    customColorsEnabled ? customColors.editorColorScheme : .standard
  }

  var body: some View {
    MarkdownEditor(text: $store.text)
      .commands(commands)
      .editorSettings(settings)
      .editorColorScheme(colorScheme)
      // Fills the window so the scrollbar sits at the window's edge; the
      // text itself is kept to a readable column inside the text view.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(colorScheme.background)
      // Opt out of SwiftUI's automatic keyboard avoidance; the UITextView
      // adjusts its own contentInset to keep content visible above the keyboard.
      #if os(iOS)
        .ignoresSafeArea(.keyboard)
      #endif
      // Paints the background under the title bar so a custom background
      // color (e.g. from a preset) reaches the traffic lights instead of
      // stopping short and leaving the window's default titlebar material.
      #if os(macOS)
        .ignoresSafeArea(edges: .top)
      #endif
      // Exposes this window's editor to the app-level Format menu.
      .focusedSceneValue(\.editorCommands, commands)
      #if os(iOS)
        .toolbar {
          ToolbarItemGroup(placement: .keyboard) {
            Menu {
              ForEach(TextStyle.allCases) { style in
                Button(style.displayName) {
                  commands.send(.setBlockStyle(style))
                }
              }
            } label: {
              Label("Style", systemImage: "textformat.size")
            }
            Spacer()
            Button {
              commands.send(.toggleBold)
            } label: {
              Label("Bold", systemImage: "bold")
            }
            Button {
              commands.send(.toggleItalic)
            } label: {
              Label("Italic", systemImage: "italic")
            }
            Button {
              showingSettings = true
            } label: {
              Label("Settings", systemImage: "gearshape")
            }
          }
        }
        .sheet(isPresented: $showingSettings) {
          SettingsView()
        }
      #endif
  }
}

extension FocusedValues {
  /// Lets app-level menu commands reach the editor in the focused window.
  @Entry var editorCommands: EditorCommands?
}
