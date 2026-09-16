import Crumpet
import SwiftUI

@main
struct ExampleApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  #endif
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

#if os(macOS)
  final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
      // Prevents AppKit from reopening the color panel at launch with no
      // picker attached. Must run before window restoration.
      NSColorPanel.shared.isRestorable = false
    }
  }
#endif

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
