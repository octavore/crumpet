import SwiftUI
import XCTest

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@testable import CharmingEditor

/// The binding carries the Markdown source, so a change arriving through it has
/// to be folded into the text view as an edit rather than a wholesale rebuild:
/// rebuilding would reparse the entire document, discard the undo stack, and
/// strand the caret. `TextDiff` decides how small that edit can be; these tests
/// pin the diff itself and then the end-to-end sync built on it.
@MainActor
final class ExternalTextSyncTests: XCTestCase {

  // MARK: The diff

  func testNoDiffForIdenticalText() {
    XCTAssertNil(
      TextDiff.between("# Title\n\nbody", and: "# Title\n\nbody"),
      "identical text must produce no edit, so the common update pass never touches the storage")
  }

  func testDiffReplacesOnlyTheChangedMiddle() {
    let edit = TextDiff.between("# Title\n\nhello world", and: "# Title\n\nhello brave world")
    XCTAssertEqual(
      edit,
      TextDiff.Edit(replaced: NSRange(location: 15, length: 0), replacement: "brave "),
      "a mid-document insertion must not disturb the shared prefix or suffix")
  }

  func testDiffOfDeletion() {
    let edit = TextDiff.between("abcdef", and: "abef")
    XCTAssertEqual(
      edit, TextDiff.Edit(replaced: NSRange(location: 2, length: 2), replacement: ""))
  }

  func testDiffIntoEmptyDocumentIsWholeText() {
    let edit = TextDiff.between("", and: "# Title")
    XCTAssertEqual(
      edit, TextDiff.Edit(replaced: NSRange(location: 0, length: 0), replacement: "# Title"),
      "the initial load must arrive as one whole-document edit, which triggers a full parse")
  }

  func testDiffKeepsSurrogatePairsWhole() {
    // Two emoji sharing a lead surrogate: a naive UTF-16 prefix scan would stop
    // between the pair's units and split the character.
    let edit = TextDiff.between("a👍b", and: "a👎b")
    guard let edit else { return XCTFail("expected an edit") }
    XCTAssertEqual(
      edit.replaced, NSRange(location: 1, length: 2),
      "the replaced range must cover the whole surrogate pair, not just its trailing unit")
    XCTAssertEqual(edit.replacement, "👎")

    let result = NSMutableString(string: "a👍b")
    result.replaceCharacters(in: edit.replaced, with: edit.replacement)
    XCTAssertEqual(result as String, "a👎b")
  }

  // MARK: End to end

  #if canImport(AppKit)
    private func makeEditor(_ markdown: String) -> (TextViewEditor.Coordinator, NSTextView) {
      var stored = markdown
      let binding = Binding(get: { stored }, set: { stored = $0 })
      let coord = TextViewEditor.Coordinator(text: binding, commands: EditorCommands())
      let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
      tv.isRichText = true
      tv.typingAttributes = TextStyle.body.attributes
      tv.textStorage?.delegate = coord.highlighter
      coord.textView = tv
      coord.applyExternalText(markdown, to: tv.textStorage!, in: tv)
      return (coord, tv)
    }

    private func isMono(_ storage: NSTextStorage, at loc: Int) -> Bool {
      let f = storage.attribute(.font, at: loc, effectiveRange: nil) as? PlatformFont
      return f?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false
    }

    func testExternalChangeStylesTheNewText() {
      let (coord, tv) = makeEditor("a plain line\n")
      let storage = tv.textStorage!

      coord.applyExternalText("a plain line\nwith `code` in it\n", to: storage, in: tv)

      XCTAssertEqual(storage.string, "a plain line\nwith `code` in it\n")
      let code = (storage.string as NSString).range(of: "code").location
      XCTAssertTrue(
        isMono(storage, at: code),
        "text arriving through the binding must be highlighted like typed text")
    }

    func testExternalChangeKeepsTheCaret() {
      let (coord, tv) = makeEditor("hello world")
      tv.setSelectedRange(NSRange(location: 11, length: 0))

      coord.applyExternalText("hello brave world", to: tv.textStorage!, in: tv)

      XCTAssertEqual(
        tv.selectedRange().location, 11,
        "an external edit must not fling the caret back to the start of the document")
    }

    func testExternalChangeClampsACaretPastTheNewEnd() {
      let (coord, tv) = makeEditor("a long line of text")
      tv.setSelectedRange(NSRange(location: 19, length: 0))

      coord.applyExternalText("short", to: tv.textStorage!, in: tv)

      XCTAssertEqual(
        tv.selectedRange(), NSRange(location: 5, length: 0),
        "a shorter document must clamp the selection instead of leaving it out of bounds")
    }

    func testBindingCarriesTheMarkdownSource() {
      let (coord, tv) = makeEditor("")
      tv.insertText("# Title", replacementRange: tv.selectedRange())
      coord.flushBindingSync()

      XCTAssertEqual(coord.text, "# Title", "the binding must hold the Markdown source verbatim")
      // The value the editor just published, redelivered by SwiftUI, must be a
      // no-op — this is the path that used to rebuild the whole document.
      XCTAssertNil(TextDiff.between(tv.textStorage!.mutableString, and: coord.text as NSString))
    }
  #endif
}
