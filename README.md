# CharmingEditor

A SwiftUI Markdown editor for macOS and iOS. It renders and edits Markdown with live syntax highlighting from [tree-sitter].

- **`MarkdownEditor`**: a drop-in SwiftUI view backed by a native `NSTextView`/`UITextView`, with paste normalization and incremental re-highlighting.
- Adjustable typeface (`system`, `serif`, `rounded`, `monospaced`) and base point size, with titles, headings, and code scaling from it; the title and code ratios are tunable (`editorTitleRatio`, `editorCodeRatio`).
- Adjustable line height (`editorLineHeight`), a max width for the centered text column (`editorMaxWidth`), and the minimum horizontal padding around it (`editorHorizontalPadding`).
- Adjustable foreground colors per construct (text, heading, code, bold, italic) and the page background via `editorColorScheme`; build a scheme from a pasted Slack theme string (all eight colors) with `EditorColorScheme(themeStrings:)`.
- Control when concealed Markdown markers (`**`, `*`, `` ` ``) reveal themselves via `markerRevealMode`: when the caret touches the marker (`.span`), anywhere on its line (`.line`), or always (`.always`).
- A top content inset (`editorTopContentInset`) for scrolling under an overlaying bar, and an `onScroll` hook that reports the vertical offset.
- A drop-in `EditorSettingsForm` and an `@AppStorage`-ready `EditorSettings` bundle, so users configure the editor without wiring each modifier by hand.
- Experimental pipe-table rendering (`experimentalTables`): `|`-delimited tables lay out as a grid with the separators and the `|---|` row hidden. Off by default; when off, a table stays plain text with its markup visible.
- Bold, italic, and block-style commands to send from your own menus, toolbars, or keyboard shortcuts.
- Enter in a list continues it and bumps ordered-list numbers; Enter on an empty item clears the marker.

## Installation

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/octavore/CharmingEditor", from: "0.1.0")
```

and depend on the `CharmingEditor` product from your target.

## Usage

```swift
import CharmingEditor
import SwiftUI

struct ContentView: View {
  // The binding holds the Markdown source; formatting is derived from it.
  @State private var text = "# Hello\n\nStart typing…"

  var body: some View {
    MarkdownEditor(text: $text)
      .editorFont(.serif)
      .editorFontSize(18)
      .editorLineHeight(1.4)
      .editorColorScheme(.init(heading: .blue, code: .pink, bold: .orange, italic: .teal))
  }
}
```

### View modifiers

| Modifier                       | Effect                                                                |
| ------------------------------ | --------------------------------------------------------------------- |
| `.editorFont(_:)`              | Typeface: `.system`, `.serif`, `.rounded`, `.monospaced`.             |
| `.editorFontSize(_:)`          | Base body point size; titles, headings, and code scale from it.       |
| `.editorTitleRatio(_:)`        | Title size as a multiple of the base size.                            |
| `.editorCodeRatio(_:)`         | Inline and block code size as a multiple of the base size.            |
| `.editorLineHeight(_:)`        | Body line height as a multiple of the font's natural line height.     |
| `.editorMaxWidth(_:)`          | Max width of the centered text column.                                |
| `.editorHorizontalPadding(_:)` | Minimum breathing room on each side of the text column.               |
| `.markerRevealMode(_:)`        | When concealed markers reveal: `.span`, `.line`, `.always`.           |
| `.experimentalTables(_:)`      | Render pipe tables as a grid (experimental, off by default).          |
| `.editorColorScheme(_:)`       | Per-construct foreground colors and the page background.              |
| `.editorTopContentInset(_:)`   | Insets the document's top edge to scroll under an overlaying bar.     |
| `.onScroll(_:)`                | Reports the vertical scroll offset (0 at the top).                    |
| `.commands(_:)`                | Attaches an `EditorCommands` to send formatting actions from your UI. |
| `.editorSettings(_:)`          | Applies an `EditorSettings` bundle (every typography option at once). |

### Importing a theme

`EditorColorScheme` parses a pasted Slack theme string: eight hex colors in Slack's own order (Column BG, Menu BG Hover, Active Item, Active Item Text, Hover Item, Text Color, Active Presence, Mention Badge). They map onto the editor as `background`, `heading`, `bold`, `text`, `italic`, and `code`; the two hover-background slots go unused.

```swift
let strings = EditorColorScheme.splitThemeString(pasted)
if let scheme = EditorColorScheme(themeStrings: strings) {
  // apply scheme
}
```

### A drop-in settings panel

To let your users tune the editor without wiring each modifier by hand, persist one `EditorSettings` value and hand it to the editor. `EditorSettings` is `RawRepresentable` as JSON, so it stores directly in `@AppStorage`. Render `EditorSettingsForm` in your own `Form` to edit it. Colors stay separate; keep using `.editorColorScheme(_:)` for those.

```swift
struct EditorScreen: View {
  @AppStorage("editorSettings") private var settings = EditorSettings()
  @State private var text = ""

  var body: some View {
    MarkdownEditor(text: $text).editorSettings(settings)
  }
}

struct SettingsScreen: View {
  @AppStorage("editorSettings") private var settings = EditorSettings()

  var body: some View {
    Form {
      EditorSettingsForm(settings: $settings)   // font, sizes, ratios, widths, reveal mode, tables, list bullet, restore-defaults
      Toggle("My Own Option", isOn: $somethingElse)  // add your rows alongside
    }
  }
}
```

`EditorSettingsForm` renders bare rows, not a container, so it inherits the chrome of whatever `Form`, `List`, or `Section` you place it in. The example app's `SettingsView` uses this directly.

### Formatting commands

To manage formatting from your own UI, hold an `EditorCommands`, attach it to the editor, and call `send(_:)`:

```swift
struct EditorScreen: View {
  @State private var text = ""
  @State private var commands = EditorCommands()

  var body: some View {
    MarkdownEditor(text: $text)
      .commands(commands)
      .toolbar {
        Button("Bold") { commands.send(.toggleBold) }
        Button("Italic") { commands.send(.toggleItalic) }
        Menu("Style") {
          ForEach(TextStyle.allCases) { style in
            Button(style.displayName) { commands.send(.setBlockStyle(style)) }
          }
        }
      }
  }
}
```

## Example app

The [`Example/`](Example) directory is a standalone Swift package that imports `CharmingEditor` as a dependency, the same way a real app would (see [`Example/Package.swift`](Example/Package.swift)). It contains an editor and a settings screen, with no network access and no persistence.

Build and run it from the `Example/` directory:

```sh
cd Example
swift build              # compile the app against the library
strudel build            # macOS app bundle
strudel run              # run macOS app bundle
strudel run --sim        # iOS Simulator
strudel run --device     # connected device
```

## Development

The library and example are separate packages. From the repo root:

```sh
swift build                        # build the library
swift test --skip PerformanceTests # run the library tests
swift build --package-path Example # build the standalone example
```

[tree-sitter]: https://tree-sitter.github.io/tree-sitter/
