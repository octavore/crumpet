import XCTest

@testable import Crumpet

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// The attributes `MarkdownHighlighter` puts on images, and the sizing
/// `ImageStore` gives a loaded picture.
@MainActor
final class ImageTests: XCTestCase {

  // MARK: Helpers

  private func styled(_ markdown: String) -> NSTextStorage {
    let storage = NSTextStorage(string: markdown)
    MarkdownHighlighter().highlight(storage)
    return storage
  }

  private func blockSource(_ storage: NSTextStorage, at location: Int) -> String? {
    storage.attribute(.imageBlock, at: location, effectiveRange: nil) as? String
  }

  private func index(of needle: String, in haystack: String) -> Int {
    (haystack as NSString).range(of: needle).location
  }

  private func image(width: CGFloat, height: CGFloat) -> PlatformImage {
    #if canImport(UIKit)
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        .image { _ in }
    #elseif canImport(AppKit)
      return NSImage(size: NSSize(width: width, height: height))
    #endif
  }

  // MARK: Highlighter

  /// An image alone on its line marks its `!` with its destination, as the
  /// chip's icon, and the whole image as one chip.
  func testStandaloneImageIsBlock() {
    let md = "![alt](https://example.com/a.png)"
    let storage = styled(md)

    XCTAssertEqual(blockSource(storage, at: 0), "https://example.com/a.png")
    XCTAssertNotNil(storage.attribute(.imageChipIcon, at: 0, effectiveRange: nil))
    XCTAssertNil(blockSource(storage, at: 1))

    var chip = NSRange(location: NSNotFound, length: 0)
    XCTAssertNotNil(
      storage.attribute(
        .imageChip, at: 0, longestEffectiveRange: &chip,
        in: NSRange(location: 0, length: storage.length)))
    XCTAssertEqual(chip, NSRange(location: 0, length: storage.length))
  }

  /// A block image's alt text is marked as its caption and is concealable.
  func testBlockImageAltTextIsCaption() {
    let md = "![alt](a.png)"
    let storage = styled(md)
    let alt = index(of: "alt", in: md)

    for location in alt..<(alt + 3) {
      XCTAssertEqual(
        storage.attribute(.imageCaption, at: location, effectiveRange: nil) as? String, "a.png")
      XCTAssertNotNil(storage.attribute(.markdownMarker, at: location, effectiveRange: nil))
    }
  }

  /// An inline image's alt text is not a caption and stays visible.
  func testInlineImageAltTextIsNotCaption() {
    let md = "see ![alt](a.png) here"
    let storage = styled(md)
    let alt = index(of: "alt", in: md)

    XCTAssertNil(storage.attribute(.imageCaption, at: alt, effectiveRange: nil))
    XCTAssertNil(storage.attribute(.markdownMarker, at: alt, effectiveRange: nil))
  }

  /// An image with empty alt text is still a block image.
  func testEmptyAltImageIsBlock() {
    let storage = styled("![](https://example.com/a.png)")
    XCTAssertEqual(blockSource(storage, at: 0), "https://example.com/a.png")
  }

  /// A block image between other paragraphs is found on its own line.
  func testBlockImageBetweenParagraphs() {
    let md = "Before\n\n![](a.png)\n\nAfter"
    let storage = styled(md)
    XCTAssertEqual(blockSource(storage, at: index(of: "!", in: md)), "a.png")
  }

  /// An image with text on its line stays a chip.
  func testInlineImageIsNotBlock() {
    let md = "see ![alt](a.png) here"
    let storage = styled(md)
    let bang = index(of: "!", in: md)

    XCTAssertNil(blockSource(storage, at: bang))
    XCTAssertNotNil(storage.attribute(.imageChipIcon, at: bang, effectiveRange: nil))
    XCTAssertNotNil(storage.attribute(.imageChip, at: bang, effectiveRange: nil))
  }

  /// A list item's marker counts as other text on the line.
  func testImageInListItemIsNotBlock() {
    let md = "- ![alt](a.png)"
    let storage = styled(md)
    XCTAssertNil(blockSource(storage, at: index(of: "!", in: md)))
  }

  /// Two images on one line are both chips.
  func testTwoImagesOnALineAreNotBlock() {
    let md = "![a](a.png)![b](b.png)"
    let storage = styled(md)
    XCTAssertNil(blockSource(storage, at: 0))
    XCTAssertNil(blockSource(storage, at: index(of: "![b]", in: md)))
  }

  /// A destination in angle brackets is stored without them.
  func testAngleBracketDestinationIsUnwrapped() {
    let storage = styled("![alt](<images/a b.png>)")
    XCTAssertEqual(blockSource(storage, at: 0), "images/a b.png")
  }

  /// A plain link is not an image.
  func testLinkIsNotImage() {
    let storage = styled("[text](https://example.com)")
    XCTAssertNil(storage.attribute(.imageChip, at: 0, effectiveRange: nil))
    XCTAssertNil(blockSource(storage, at: 0))
  }

  /// Typing an image a character at a time ends with the same attributes a
  /// one-shot parse gives.
  func testTypedImageIsBlock() {
    let md = "![alt](a.png)"
    let storage = NSTextStorage(string: "")
    let highlighter = MarkdownHighlighter()
    storage.delegate = highlighter
    for ch in md {
      storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: String(ch))
    }
    highlighter.flushPendingParse(storage)

    XCTAssertEqual(blockSource(storage, at: 0), "a.png")
  }

  /// Adding text after a block image takes its block mark away.
  func testTextAfterImageRemovesBlock() {
    let storage = NSTextStorage(string: "![alt](a.png)")
    let highlighter = MarkdownHighlighter()
    highlighter.highlight(storage)
    storage.delegate = highlighter
    XCTAssertEqual(blockSource(storage, at: 0), "a.png")

    storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: " x")
    highlighter.flushPendingParse(storage)
    XCTAssertNil(blockSource(storage, at: 0))
  }

  // MARK: Sizing

  /// A picture narrower than the column keeps its natural size.
  func testDisplaySizeKeepsSmallImage() {
    let size = ImageStore.displaySize(of: image(width: 200, height: 100), maxWidth: 600)
    XCTAssertEqual(size, CGSize(width: 200, height: 100))
  }

  /// A picture wider than the column scales down, keeping its aspect ratio.
  func testDisplaySizeScalesWideImage() {
    let size = ImageStore.displaySize(of: image(width: 1200, height: 800), maxWidth: 600)
    XCTAssertEqual(size, CGSize(width: 600, height: 400))
  }

  /// No room to lay out gives no size.
  func testDisplaySizeWithNoWidth() {
    let size = ImageStore.displaySize(of: image(width: 200, height: 100), maxWidth: 0)
    XCTAssertEqual(size, .zero)
  }
}
