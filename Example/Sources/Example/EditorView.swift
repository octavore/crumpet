import CharmingEditor
import SwiftUI

/// The editing surface: the CharmingEditor library's `MarkdownEditor` bound
/// straight to the store's document.
struct EditorView: View {
  @Bindable var store: PageStore
  @State private var commands = EditorCommands()

  // The selected typeface and size, shared with SettingsView through the same
  // defaults keys; changing them there re-renders this view and restyles the
  // editor.
  @AppStorage(EditorFont.defaultsKey) private var fontFamily: EditorFont = .system
  @AppStorage(Typography.sizeDefaultsKey) private var fontSize: Double = .init(
    Typography.defaultBaseSize)
  @AppStorage(Typography.lineHeightDefaultsKey) private var lineHeight: Double = .init(
    Typography.defaultLineHeightMultiple)
  @AppStorage(MarkerRevealMode.defaultsKey) private var revealMode: MarkerRevealMode = .span
  @AppStorage(EditorColorScheme.colorfulDefaultsKey) private var colorfulSyntax = false

  #if os(iOS)
    @State private var showingSettings = false
  #endif

  var body: some View {
    MarkdownEditor(text: $store.text)
      .commands(commands)
      .editorFont(fontFamily)
      .editorFontSize(CGFloat(fontSize))
      .editorLineHeight(CGFloat(lineHeight))
      .markerRevealMode(revealMode)
      .editorColorScheme(colorfulSyntax ? .colorful : .standard)
      // Fills the window so the scrollbar sits at the window's edge; the
      // text itself is kept to a readable column inside the text view.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.editorBackground)
      // Opt out of SwiftUI's automatic keyboard avoidance; the UITextView
      // adjusts its own contentInset to keep content visible above the keyboard.
      #if os(iOS)
        .ignoresSafeArea(.keyboard)
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
