import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterJSON
import TreeSitterTOML

/// The kinds of token a code block highlight colors. Each maps to a field of
/// ``EditorColorScheme/SyntaxColors``.
enum SyntaxKind {
  case keyword
  case string
  case number
  case comment
  case function
  case property
}

/// A colored run of a code block, in UTF-16 code units relative to the start
/// of the code that was tokenized.
struct SyntaxToken: Equatable {
  var range: NSRange
  var kind: SyntaxKind
}

/// Tokenizes the contents of a fenced code block with the tree-sitter grammar
/// for the fence's language. Supports JSON, Bash, and TOML. Tokens come back in
/// document order with an enclosing token before the tokens inside it, so
/// applying them in sequence lets the inner color win.
final class CodeSyntaxHighlighter {
  private enum Grammar {
    case json
    case bash
    case toml
  }

  /// Code longer than this many UTF-16 code units is left uncolored.
  static let maxLength = 30_000

  private let jsonParser = Parser()
  private let bashParser = Parser()
  private let tomlParser = Parser()
  private var jsonReady = false
  private var bashReady = false
  private var tomlReady = false

  init() {
    do {
      try jsonParser.setLanguage(Language(tree_sitter_json()))
      jsonReady = true
    } catch {
      print("CodeSyntaxHighlighter: json setLanguage failed: \(error)")
    }
    do {
      try bashParser.setLanguage(Language(tree_sitter_bash()))
      bashReady = true
    } catch {
      print("CodeSyntaxHighlighter: bash setLanguage failed: \(error)")
    }
    do {
      try tomlParser.setLanguage(Language(tree_sitter_toml()))
      tomlReady = true
    } catch {
      print("CodeSyntaxHighlighter: toml setLanguage failed: \(error)")
    }
  }

  /// Whether `name`, the first word of a fence's info string, names a
  /// supported language.
  static func supports(_ name: String) -> Bool {
    language(named: name) != nil
  }

  /// The tokens of `code` in the language `name`, or an empty list for an
  /// unsupported language or code over ``maxLength``.
  func tokens(of code: NSString, language name: String) -> [SyntaxToken] {
    guard code.length > 0, code.length <= Self.maxLength,
      let language = Self.language(named: name)
    else { return [] }
    let parser: Parser
    switch language {
    case .json:
      guard jsonReady else { return [] }
      parser = jsonParser
    case .bash:
      guard bashReady else { return [] }
      parser = bashParser
    case .toml:
      guard tomlReady else { return [] }
      parser = tomlParser
    }
    guard let tree = parser.parse(code as String), let root = tree.rootNode else { return [] }
    var tokens: [SyntaxToken] = []
    switch language {
    case .json: walkJSON(root, into: &tokens)
    case .bash: walkBash(root, source: code, into: &tokens)
    case .toml: walkTOML(root, into: &tokens)
    }
    return tokens
  }

  private static func language(named name: String) -> Grammar? {
    switch name.lowercased() {
    case "json", "jsonc", "json5": .json
    case "bash", "sh", "shell", "zsh", "console": .bash
    case "toml": .toml
    default: nil
    }
  }

  // MARK: TOML

  private func walkTOML(_ node: Node, into tokens: inout [SyntaxToken]) {
    switch node.nodeType ?? "" {
    case "bare_key", "quoted_key":
      // Keys in pairs and in table headers (`[a.b]`, `[[a]]`).
      add(node, .property, to: &tokens)
      return
    case "string":
      add(node, .string, to: &tokens)
      return
    case "integer", "float", "offset_date_time", "local_date_time", "local_date", "local_time":
      add(node, .number, to: &tokens)
      return
    case "boolean":
      add(node, .keyword, to: &tokens)
      return
    case "comment":
      add(node, .comment, to: &tokens)
      return
    default:
      break
    }
    for index in 0..<node.childCount {
      if let child = node.child(at: index) { walkTOML(child, into: &tokens) }
    }
  }

  // MARK: JSON

  private func walkJSON(_ node: Node, into tokens: inout [SyntaxToken]) {
    switch node.nodeType ?? "" {
    case "pair":
      // The key is a string node; color it as a property and skip its
      // contents so escape sequences inside it keep the key color.
      let key = node.child(byFieldName: "key")
      if let key { add(key, .property, to: &tokens) }
      for index in 0..<node.childCount {
        if let child = node.child(at: index), child.id != key?.id { walkJSON(child, into: &tokens) }
      }
      return
    case "string":
      add(node, .string, to: &tokens)
      return
    case "number":
      add(node, .number, to: &tokens)
      return
    case "true", "false", "null":
      add(node, .keyword, to: &tokens)
      return
    case "comment":
      add(node, .comment, to: &tokens)
      return
    default:
      break
    }
    for index in 0..<node.childCount {
      if let child = node.child(at: index) { walkJSON(child, into: &tokens) }
    }
  }

  // MARK: Bash

  private static let bashKeywords: Set<String> = [
    "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in",
    "select", "then", "unset", "until", "while", "declare", "local", "readonly", "typeset",
  ]

  private func walkBash(_ node: Node, source: NSString, into tokens: inout [SyntaxToken]) {
    let type = node.nodeType ?? ""
    switch type {
    case "comment":
      add(node, .comment, to: &tokens)
      return
    case "raw_string", "ansi_c_string", "heredoc_body", "heredoc_start":
      add(node, .string, to: &tokens)
      return
    case "string":
      // Expansions inside a double-quoted string are colored on top of it.
      add(node, .string, to: &tokens)
    case "command_name":
      add(node, .function, to: &tokens)
      return
    case "variable_name", "special_variable_name":
      add(node, .property, to: &tokens)
      return
    case "number", "file_descriptor":
      add(node, .number, to: &tokens)
      return
    case "function_definition":
      let name = node.child(byFieldName: "name")
      if let name { add(name, .function, to: &tokens) }
      for index in 0..<node.childCount {
        if let child = node.child(at: index), child.id != name?.id {
          walkBash(child, source: source, into: &tokens)
        }
      }
      return
    case "word":
      // A command argument that starts with a dash is a flag.
      if node.parent?.nodeType == "command", isFlag(node, in: source) {
        add(node, .number, to: &tokens)
      }
      return
    default:
      if !node.isNamed, Self.bashKeywords.contains(type) {
        add(node, .keyword, to: &tokens)
        return
      }
    }
    for index in 0..<node.childCount {
      if let child = node.child(at: index) { walkBash(child, source: source, into: &tokens) }
    }
  }

  private func isFlag(_ node: Node, in source: NSString) -> Bool {
    let start = Int(node.byteRange.lowerBound) / 2
    return start < source.length && source.character(at: start) == 0x2D
  }

  // MARK: Tokens

  private func add(_ node: Node, _ kind: SyntaxKind, to tokens: inout [SyntaxToken]) {
    let range = node.byteRange
    let lower = Int(range.lowerBound) / 2
    let upper = Int(range.upperBound) / 2
    guard upper > lower else { return }
    tokens.append(SyntaxToken(range: NSRange(location: lower, length: upper - lower), kind: kind))
  }
}
