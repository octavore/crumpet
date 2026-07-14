import SwiftUI

/// Foreground colors for the editor's markdown constructs.
///
/// Every field left at its default falls back to `text`, so today's uniform
/// look is the default and adopting the type is a no-op until you override the
/// constructs you care about:
///
/// ```swift
/// MarkdownEditor(text: $text)
///   .editorColorScheme(.init(heading: .blue, code: .pink, bold: .orange, italic: .teal))
/// ```
public struct EditorColorScheme: Sendable, Equatable {
  public var text: Color
  public var heading: Color
  public var code: Color
  public var bold: Color
  public var italic: Color

  public init(
    text: Color = .primary,
    heading: Color? = nil,
    code: Color? = nil,
    bold: Color? = nil,
    italic: Color? = nil
  ) {
    self.text = text
    self.heading = heading ?? text
    self.code = code ?? text
    self.bold = bold ?? text
    self.italic = italic ?? text
  }

  /// Every construct rendered in the same adaptive text color.
  public static let standard = EditorColorScheme()
}
