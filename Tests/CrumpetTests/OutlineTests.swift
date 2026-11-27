import Foundation
import Testing

@testable import Crumpet

@Suite struct OutlineTests {
  @Test func levelsAndTitles() {
    let items = MarkdownOutline.items(in: "# One\n\n## Two\n\n###### Six\n")
    #expect(items.map(\.level) == [1, 2, 6])
    #expect(items.map(\.title) == ["One", "Two", "Six"])
    #expect(items.map(\.id) == [0, 1, 2])
  }

  @Test func closingHashesAreStripped() {
    let items = MarkdownOutline.items(in: "## Title ##\n\n# C#\n")
    #expect(items.map(\.title) == ["Title", "C#"])
  }

  @Test func codeBlocksAreSkipped() {
    let items = MarkdownOutline.items(in: "```\n# not a heading\n```\n\n# Real\n")
    #expect(items.map(\.title) == ["Real"])
  }

  @Test func setextHeadingsAreSkipped() {
    #expect(MarkdownOutline.items(in: "Title\n=====\n\nBody\n").isEmpty)
  }

  @Test func nestedHeadingsAreFound() {
    let items = MarkdownOutline.items(in: "> # Quoted\n\n- # Listed\n")
    #expect(items.map(\.title) == ["Quoted", "Listed"])
  }

  @Test func rangesAreUTF16() {
    let text = "😀 日本語\n\n## After\n"
    let items = MarkdownOutline.items(in: text)
    #expect(items.count == 1)
    let range = items[0].range
    #expect((text as NSString).substring(with: range) == "## After")
  }

  @Test func emptyHeading() {
    let items = MarkdownOutline.items(in: "#\n\ntext\n")
    #expect(items.count == 1)
    #expect(items[0].title == "")
  }
}
