# CharmingEditor

A SwiftUI Markdown editor for macOS and iOS. It renders and edits Markdown
with live syntax highlighting driven by [tree-sitter].

- **`MarkdownEditor`**: a drop-in SwiftUI view backed by a native
  `NSTextView`/`UITextView`, with paste normalization and incremental re-highlighting.
- Adjustable typeface (`system`, `serif`, `rounded`, `monospaced`) and base
  point size, with titles and headings scaling proportionally.
- Adjustable foreground colors per construct (heading, code, bold, italic) via
  `editorColorScheme`.
- Bold, italic, and block-style commands you can drive from your own menus,
  toolbars, or keyboard shortcuts.
- Pressing Enter in a list continues it automatically (bumping ordered-list
  numbers), and clears the marker when you press Enter on an empty item.

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
      .editorColorScheme(.init(heading: .blue, code: .pink, bold: .orange, italic: .teal))
  }
}
```

### Formatting commands

To manage formatting from your own UI, hold an `EditorCommands`, attach it to
the editor, and call `send(_:)`:

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

The [`Example/`](Example) directory is a standalone Swift package that
imports `CharmingEditor` as a dependency, the same way a real app would (see
[`Example/Package.swift`](Example/Package.swift)). It's just an editor and a
font settings screen, with no network and no persistence.

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
