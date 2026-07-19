import SwiftUI

// One name for the platform's representable + font so the editor backend
// reads the same on macOS (AppKit) and iOS (UIKit).
#if canImport(UIKit)
  import UIKit
  typealias PlatformViewRepresentable = UIViewRepresentable
  typealias PlatformFont = UIFont
  typealias PlatformColor = UIColor
  typealias PlatformTextView = UITextView
  typealias FontTraits = UIFontDescriptor.SymbolicTraits
  typealias FontDesign = UIFontDescriptor.SystemDesign

  extension FontTraits {
    static let boldTrait = traitBold
    static let italicTrait = traitItalic
  }

  extension PlatformColor {
    /// High-contrast body text and the page it sits on. Both adapt to light
    /// and dark mode so the editor is always readable.
    static var editorText: PlatformColor { .label }
    static var editorBackground: PlatformColor { .systemBackground }
  }
#elseif canImport(AppKit)
  import AppKit
  typealias PlatformViewRepresentable = NSViewRepresentable
  typealias PlatformFont = NSFont
  typealias PlatformColor = NSColor
  typealias PlatformTextView = NSTextView
  typealias FontTraits = NSFontDescriptor.SymbolicTraits
  typealias FontDesign = NSFontDescriptor.SystemDesign

  extension FontTraits {
    static let boldTrait = bold
    static let italicTrait = italic
  }

  extension PlatformColor {
    /// High-contrast body text and the page it sits on. Both adapt to light
    /// and dark mode so the editor is always readable.
    static var editorText: PlatformColor { .labelColor }
    static var editorBackground: PlatformColor { .textBackgroundColor }
  }
#endif

extension PlatformTextView {
  // UITextView.textStorage is non-optional; NSTextView.textStorage is optional.
  // Declaring the return as Optional? lets shared code bind both uniformly.
  var optionalTextStorage: NSTextStorage? { textStorage }

  // UITextView assigns the selection; NSTextView goes through setSelectedRange,
  // which also scrolls and notifies. One name so shared code can move the caret.
  func setEditorSelectedRange(_ range: NSRange) {
    #if canImport(UIKit)
      selectedRange = range
    #elseif canImport(AppKit)
      setSelectedRange(range)
    #endif
  }

  // Forces a repaint of the currently visible text. Concealing or revealing a
  // marker changes glyph widths, which can reflow a wrapped line's soft breaks
  // and shift every visual line below it; the layout manager's own display
  // invalidation for an attribute-only edit doesn't always cover that shift,
  // leaving stale pixels (lines that look duplicated) until the next draw. One
  // name so shared concealment code can force the redraw without an #if.
  func refreshEditorDisplay() {
    #if canImport(UIKit)
      setNeedsDisplay()
    #elseif canImport(AppKit)
      setNeedsDisplay(visibleRect)
    #endif
  }

  // UITextView.selectedRange is a property; NSTextView reads it via the
  // NSText-era selectedRange() method. One name so shared code can read the
  // caret without an #if.
  var editorSelectedRange: NSRange {
    #if canImport(UIKit)
      selectedRange
    #elseif canImport(AppKit)
      selectedRange()
    #endif
  }
}

extension Color {
  /// The editor's page background, adapting to light and dark mode. Match your
  /// surrounding chrome to it so the editor blends into the window.
  public static var editorBackground: Color { Color(PlatformColor.editorBackground) }
}

extension PlatformFont {
  var traits: FontTraits { fontDescriptor.symbolicTraits }

  /// Same face and size with exactly `traits`. Falls back to `self` when the
  /// face has no variant for the requested traits.
  func with(traits: FontTraits) -> PlatformFont {
    #if canImport(UIKit)
      guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
      return PlatformFont(descriptor: descriptor, size: pointSize)
    #elseif canImport(AppKit)
      let descriptor = fontDescriptor.withSymbolicTraits(traits)
      return PlatformFont(descriptor: descriptor, size: pointSize) ?? self
    #endif
  }

  func toggling(_ trait: FontTraits) -> PlatformFont {
    with(traits: traits.symmetricDifference(trait))
  }

  /// A system font of the given size and weight in one of the built-in system
  /// *designs* (default, serif, rounded, monospaced). Falls back to the plain
  /// system font if the design has no variant at this size/weight.
  static func designed(ofSize size: CGFloat, weight: Weight, design: FontDesign) -> PlatformFont {
    let base = systemFont(ofSize: size, weight: weight)
    guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
    #if canImport(UIKit)
      return PlatformFont(descriptor: descriptor, size: size)
    #elseif canImport(AppKit)
      return PlatformFont(descriptor: descriptor, size: size) ?? base
    #endif
  }
}
