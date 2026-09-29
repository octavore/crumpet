import SwiftUI
import XCTest

@testable import Crumpet

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
final class CodeSyntaxHighlightingTests: XCTestCase {
  private let scheme = EditorColorScheme(
    text: .white, code: .gray,
    syntax: .init(
      keyword: .red, string: .green, number: .blue, comment: .yellow, function: .orange,
      property: .purple))

  override func setUp() {
    super.setUp()
    Typography.colorScheme = scheme
  }

  override func tearDown() {
    Typography.colorScheme = .standard
    super.tearDown()
  }

  private func styled(_ markdown: String) -> NSTextStorage {
    let storage = NSTextStorage(string: markdown)
    MarkdownHighlighter().highlight(storage)
    return storage
  }

  private func color(_ storage: NSTextStorage, of needle: String) -> PlatformColor? {
    let range = (storage.string as NSString).range(of: needle)
    XCTAssertNotEqual(range.location, NSNotFound, "\(needle) not found")
    return storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil)
      as? PlatformColor
  }

  func testJSONTokens() {
    let storage = styled("```json\n{\"name\": \"x\", \"n\": 42, \"ok\": true}\n```\n")
    XCTAssertEqual(color(storage, of: "\"name\""), PlatformColor(.purple))
    XCTAssertEqual(color(storage, of: "\"x\""), PlatformColor(.green))
    XCTAssertEqual(color(storage, of: "42"), PlatformColor(.blue))
    XCTAssertEqual(color(storage, of: "true"), PlatformColor(.red))
  }

  func testTOMLTokens() {
    let storage = styled(
      "```toml\n# note\n[server.http]\nname = \"x\"\nport = 8080\ndebug = true\n"
        + "since = 2024-01-02\n```\n")
    XCTAssertEqual(color(storage, of: "# note"), PlatformColor(.yellow))
    XCTAssertEqual(color(storage, of: "server"), PlatformColor(.purple))
    XCTAssertEqual(color(storage, of: "name"), PlatformColor(.purple))
    XCTAssertEqual(color(storage, of: "\"x\""), PlatformColor(.green))
    XCTAssertEqual(color(storage, of: "8080"), PlatformColor(.blue))
    XCTAssertEqual(color(storage, of: "true"), PlatformColor(.red))
    XCTAssertEqual(color(storage, of: "2024-01-02"), PlatformColor(.blue))
  }

  func testBashTokens() {
    let storage = styled("```bash\n# note\nif [ -f \"$HOME/x\" ]; then\n  ls -la\nfi\n```\n")
    XCTAssertEqual(color(storage, of: "# note"), PlatformColor(.yellow))
    XCTAssertEqual(color(storage, of: "if"), PlatformColor(.red))
    XCTAssertEqual(color(storage, of: "HOME"), PlatformColor(.purple))
    XCTAssertEqual(color(storage, of: "ls"), PlatformColor(.orange))
    XCTAssertEqual(color(storage, of: "-la"), PlatformColor(.blue))
  }

  func testUnknownLanguageKeepsCodeColor() {
    let storage = styled("```cobol\nif x then y\n```\n")
    XCTAssertEqual(color(storage, of: "if"), PlatformColor(.gray))
  }

  func testMissingLanguageKeepsCodeColor() {
    let storage = styled("```\n{\"a\": 1}\n```\n")
    XCTAssertEqual(color(storage, of: "1"), PlatformColor(.gray))
  }
}
