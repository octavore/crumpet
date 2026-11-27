import Crumpet
import SwiftUI

/// The editing surface: the Crumpet library's `MarkdownEditor` bound
/// straight to the store's document.
struct EditorView: View {
  @Bindable var store: PageStore
  @State private var commands = EditorCommands()

  // Shared with SettingsView through the same defaults keys; changing them
  // there re-renders this view and restyles the editor.
  @AppStorage(EditorSettings.defaultsKey) private var settings = EditorSettings()
  @AppStorage(EditorTheme.defaultsKey) private var theme = EditorTheme.system
  @AppStorage(EditorAppearance.defaultsKey) private var editorAppearance = EditorAppearance.system
  @AppStorage(EditorCustomColors.defaultsKey) private var customColors = EditorCustomColors()
  @Environment(\.colorScheme) private var systemAppearance

  @State private var showingOutline = false
  @State private var outlineItems: [OutlineItem] = []

  /// Toolbar button that toggles the outline popover.
  private var outlineButton: some View {
    Button {
      showingOutline.toggle()
    } label: {
      Label("Outline", systemImage: "list.bullet.indent")
    }
    .help("Outline")
    .popover(isPresented: $showingOutline, arrowEdge: .bottom) {
      OutlineView(items: outlineItems) { item in
        showingOutline = false
        commands.send(.scrollToHeading(item))
      }
    }
  }

  #if os(iOS)
    @State private var showingSettings = false
  #endif

  /// The light or dark appearance the editor is using.
  private var appearance: ColorScheme { editorAppearance.resolved(systemAppearance) }

  /// The scheme in effect now, used to paint the surface around the editor.
  private var colorScheme: EditorColorScheme {
    theme.colorScheme(for: appearance, customColors: customColors)
  }

  var body: some View {
    MarkdownEditor(text: $store.text)
      .commands(commands)
      .editorSettings(settings)
      .editorTheme(theme, customColors: customColors)
      .editorAppearance(editorAppearance)
      // Fills the window so the scrollbar sits at the window's edge; the
      // text itself is kept to a readable column inside the text view.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // Resolves an adaptive background in the editor's appearance, which can
      // differ from the window's.
      .background { colorScheme.background.environment(\.colorScheme, appearance) }
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
      // Lets the editor background show through the window toolbar, and hides
      // the window title so the toolbar row holds only the outline button.
      #if os(macOS)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationTitle("")
        .toolbar {
          ToolbarItem(placement: .primaryAction) { outlineButton }
        }
      #endif
      // Snapshots the headings when the popover opens.
      .onChange(of: showingOutline) { _, isShowing in
        if isShowing { outlineItems = commands.outline }
      }
      // Exposes this window's editor to the app-level Format menu.
      .focusedSceneValue(\.editorCommands, commands)
      .focusedSceneValue(\.showingOutline, $showingOutline)
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
            outlineButton
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
  /// Lets the View menu toggle the outline popover in the focused window.
  @Entry var showingOutline: Binding<Bool>?
}
