import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Draws image chips, block images, and link icons over concealed Markdown
/// syntax.
final class EditorLayoutManager: NSLayoutManager {
  /// The pictures block images display.
  let images = ImageStore()

  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    guard let storage = textStorage, storage.length > 0,
      let context = currentGraphicsContext
    else { return }

    let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    drawImageChips(in: visible, storage: storage, at: origin, into: context)
    drawLinkIcons(in: visible, storage: storage, at: origin, into: context)
  }

  // MARK: Link icons

  /// Draws a link icon after the text of each link whose syntax is concealed.
  /// A link is concealed when the `]` ending its text is a control glyph, which
  /// keeps this in agreement with the reveal mode and the caret.
  private func drawLinkIcons(
    in visible: NSRange, storage: NSTextStorage, at origin: CGPoint, into context: CGContext
  ) {
    let color = PlatformColor(Typography.colorScheme.link)
    storage.enumerateAttribute(.linkChipIcon, in: visible) { value, run, _ in
      guard value != nil else { return }
      let icon = glyphIndexForCharacter(at: run.location)
      guard propertyForGlyph(at: icon).contains(.controlCharacter) else { return }

      let line = lineFragmentRect(forGlyphAt: icon, effectiveRange: nil)
      let position = location(forGlyphAt: icon)
      let baseline = CGPoint(
        x: origin.x + line.minX + position.x, y: origin.y + line.minY + position.y)
      let font =
        storage.attribute(.font, at: run.location, effectiveRange: nil) as? PlatformFont
        ?? TextStyle.body.font
      context.saveGState()
      defer { context.restoreGState() }
      ImageChip.drawIcon(
        named: ImageChip.linkSymbolName, at: baseline, font: font, color: color)
    }
  }

  // MARK: Image chips

  /// Draws each image whose syntax is concealed. A block image whose picture
  /// has loaded draws the picture. Any other image fills a rounded chip and
  /// draws the chip's icon in the space its `!` reserves. An image is concealed
  /// when its `!` glyph is a control glyph, which keeps this in agreement with
  /// the reveal mode and the caret without recomputing either.
  private func drawImageChips(
    in visible: NSRange, storage: NSTextStorage, at origin: CGPoint, into context: CGContext
  ) {
    guard let container = textContainers.first else { return }
    let color = PlatformColor(Typography.colorScheme.link)
    storage.enumerateAttribute(.imageChip, in: visible) { value, run, _ in
      guard value != nil else { return }
      // The run is clipped to `visible`, so an image that starts above the
      // screen needs its full range to find its `!`.
      var image = run
      _ = storage.attribute(
        .imageChip, at: run.location, longestEffectiveRange: &image,
        in: storage.mutableString.paragraphRange(for: run))
      let icon = glyphIndexForCharacter(at: image.location)
      guard propertyForGlyph(at: icon).contains(.controlCharacter) else { return }

      context.saveGState()
      defer { context.restoreGState() }
      let line = lineFragmentRect(forGlyphAt: icon, effectiveRange: nil)
      let position = location(forGlyphAt: icon)
      let baseline = CGPoint(
        x: origin.x + line.minX + position.x, y: origin.y + line.minY + position.y)

      if let source = storage.attribute(.imageBlock, at: image.location, effectiveRange: nil)
        as? String, let picture = images.image(for: source)
      {
        let size = ImageStore.displaySize(
          of: picture, maxWidth: container.size.width - 2 * container.lineFragmentPadding)
        let rect = CGRect(origin: CGPoint(x: baseline.x, y: baseline.y - size.height), size: size)
        context.addPath(
          CGPath(
            roundedRect: rect, cornerWidth: ImageStore.cornerRadius,
            cornerHeight: ImageStore.cornerRadius, transform: nil))
        context.clip()
        #if canImport(UIKit)
          picture.draw(in: rect)
        #elseif canImport(AppKit)
          picture.draw(
            in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
            hints: nil)
        #endif
        return
      }

      context.setFillColor(color.withAlphaComponent(0.15).cgColor)
      let glyphs = glyphRange(forCharacterRange: image, actualCharacterRange: nil)
      enumerateEnclosingRects(
        forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
        in: container
      ) { rect, _ in
        let chip = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: 1)
        let path = CGPath(
          roundedRect: chip, cornerWidth: chip.height / 2, cornerHeight: chip.height / 2,
          transform: nil)
        context.addPath(path)
        context.fillPath()
      }

      let font =
        storage.attribute(.font, at: image.location, effectiveRange: nil) as? PlatformFont
        ?? TextStyle.body.font
      ImageChip.drawIcon(named: ImageChip.symbolName, at: baseline, font: font, color: color)
    }
  }
}

/// The icon at the front of a concealed image's chip, and the icon after a
/// concealed link's text. Layout reserves ``iconAdvance(for:)`` for it and
/// `EditorLayoutManager` draws it there.
enum ImageChip {
  static let symbolName = "photo"
  static let linkSymbolName = "link"

  /// The width a concealed `!` or link-ending `]` takes in `font`: the icon
  /// plus a gap between it and the neighboring text.
  static func iconAdvance(for font: PlatformFont) -> CGFloat {
    (font.pointSize * 1.3).rounded()
  }

  /// Draws the icon in the space starting at `baseline`, centered on the cap
  /// height of `font`.
  static func drawIcon(
    named symbolName: String, at baseline: CGPoint, font: PlatformFont, color: PlatformColor
  ) {
    let height = (font.capHeight * 1.2).rounded()
    #if canImport(UIKit)
      let config = UIImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
      guard
        let image = UIImage(systemName: symbolName, withConfiguration: config)?
          .withTintColor(color, renderingMode: .alwaysOriginal)
      else { return }
    #elseif canImport(AppKit)
      let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
      guard
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
          .withSymbolConfiguration(config)
      else { return }
    #endif
    guard image.size.height > 0 else { return }
    let width = height * image.size.width / image.size.height
    let rect = CGRect(
      x: baseline.x + (iconAdvance(for: font) - width) / 2 - 1,
      y: baseline.y - font.capHeight / 2 - height / 2,
      width: width, height: height)
    #if canImport(UIKit)
      image.draw(in: rect)
    #elseif canImport(AppKit)
      image.draw(
        in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
        hints: nil)
    #endif
  }
}
