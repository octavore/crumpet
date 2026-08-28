# CharmingEditor

A SwiftUI Markdown editor for macOS and iOS. It renders and edits Markdown with live syntax highlighting driven by [tree-sitter].

- **`MarkdownEditor`**: a drop-in SwiftUI view backed by a native `NSTextView`/`UITextView`, with paste normalization and incremental re-highlighting.
- Adjustable typeface (`system`, `serif`, `rounded`, `monospaced`) and base point size, with titles, headings, and code scaling by tunable ratios (`editorTitleRatio`, `editorCodeRatio`).
- Adjustable line height (`editorLineHeight`) and a max width for the centered text column (`editorMaxWidth`).
- Adjustable foreground colors per construct (text, heading, code, bold, italic) plus page background via `editorColorScheme`; build a scheme from a pasted Slack-style theme string with `EditorColorScheme(themeStrings:)`.
- Control when concealed Markdown markers (`**`, `*`, `` ` ``) reveal themselves via `markerRevealMode`: when the caret touches the marker (`.span`), anywhere on its line (`.line`), or never conceal at all (`.always`).
- A top content inset (`editorTopContentInset`) for scrolling under an overlaying bar, and an `onScroll` hook reporting the vertical offset.
- Bold, italic, and block-style commands you can drive from your own menus, toolbars, or keyboard shortcuts.
- Pressing Enter in a list continues it automatically (bumping ordered-list numbers), and clears the marker when you press Enter on an empty item.

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

| Modifier                     | Effect                                                                |
| ---------------------------- | --------------------------------------------------------------------- |
| `.editorFont(_:)`            | Typeface: `.system`, `.serif`, `.rounded`, `.monospaced`.             |
| `.editorFontSize(_:)`        | Base body point size; titles, headings, and code scale from it.       |
| `.editorTitleRatio(_:)`      | Title size as a multiple of the base size.                            |
| `.editorCodeRatio(_:)`       | Inline and block code size as a multiple of the base size.            |
| `.editorLineHeight(_:)`      | Body line height as a multiple of the font's natural line height.     |
| `.editorMaxWidth(_:)`        | Max width of the centered text column.                                |
| `.markerRevealMode(_:)`      | When concealed markers reveal: `.span`, `.line`, `.always`.           |
| `.editorColorScheme(_:)`     | Per-construct foreground colors and page background.                  |
| `.editorTopContentInset(_:)` | Insets the document's top edge so it scrolls under an overlaying bar. |
| `.onScroll(_:)`              | Called with the vertical scroll offset (0 at the top).                |
| `.commands(_:)`              | Attaches an `EditorCommands` for driving formatting from your UI.     |

### Importing a theme

`EditorColorScheme` parses a pasted Slack-style theme string (hex colors in the order `text, heading, code, bold, italic, background`):

```swift
let strings = EditorColorScheme.splitThemeString(pasted)
if let scheme = EditorColorScheme(themeStrings: strings) {
  // apply scheme
}
```

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

The [`Example/`](Example) directory is a standalone Swift package that imports `CharmingEditor` as a dependency, the same way a real app would (see [`Example/Package.swift`](Example/Package.swift)). It's just an editor and a font settings screen, with no network and no persistence.

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
