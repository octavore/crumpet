import Crumpet
import SwiftUI

@main
struct ExampleApp: App {
  @State private var store = PageStore()

  var body: some Scene {
    WindowGroup {
      EditorView(store: store)
    }
    #if os(macOS)
      .windowStyle(.hiddenTitleBar)
    #endif
    .commands {
      FormatCommands()
    }

    // macOS shows this as the standard Settings window (⌘,). On iOS the same
    // view is presented from EditorView as a sheet.
    #if os(macOS)
      Settings {
        SettingsView()
      }
    #endif
  }
}

/// App-level Format menu (and hardware-keyboard shortcuts on iPad). Reaches
/// the focused window's editor through the focused-scene value, so the menu
/// stays decoupled from whichever backend is active.
struct FormatCommands: Commands {
  @FocusedValue(\.editorCommands) private var commands

  var body: some Commands {
    CommandMenu("Format") {
      Button("Bold") { commands?.send(.toggleBold) }
        .keyboardShortcut("b")
      Button("Italic") { commands?.send(.toggleItalic) }
        .keyboardShortcut("i")
      Divider()
      ForEach(TextStyle.allCases) { style in
        Button(style.displayName) { commands?.send(.setBlockStyle(style)) }
          .keyboardShortcut(style.shortcutKey, modifiers: [.command, .option])
      }
    }
  }
}
