import Foundation

/// Attributes the highlighter adds for rendering. None of them change the
/// Markdown source. See ``MarkerConcealment``.
extension NSAttributedString.Key {
  /// The block attributes the last whole-document parse gave this character's
  /// paragraph. The keystroke path restores them instead of re-deciding the
  /// paragraph's block type.
  static let blockBase = NSAttributedString.Key("CrumpetBlockBase")

  /// Marks a syntax character the layout manager conceals when the caret is
  /// away. The value is the reveal span, stored relative to the marker (see
  /// ``MarkerSpan``).
  static let markdownMarker = NSAttributedString.Key("CrumpetMarkdownMarker")

  /// Marks an unordered list bullet, drawn as the glyph ``ListBulletStyle``
  /// selects.
  static let listBulletMarker = NSAttributedString.Key("CrumpetListBulletMarker")

  /// Covers a whole image, drawn as a chip while its syntax is concealed. The
  /// value is a token unique to the image.
  static let imageChip = NSAttributedString.Key("CrumpetImageChip")

  /// Marks an image's `!`, drawn as the chip's icon while concealed.
  static let imageChipIcon = NSAttributedString.Key("CrumpetImageChipIcon")

  /// Marks the `]` that ends a link's text, drawn as a link icon while
  /// concealed.
  static let linkChipIcon = NSAttributedString.Key("CrumpetLinkChipIcon")

  /// Marks the `!` of an image alone on its line. The value is the image's
  /// destination. Once `ImageStore` loads it, the line displays the picture.
  static let imageBlock = NSAttributedString.Key("CrumpetImageBlock")

  /// Marks the alt text of an image alone on its line. The value is the
  /// destination. The alt text is the chip's label until the picture loads.
  static let imageCaption = NSAttributedString.Key("CrumpetImageCaption")
}

/// Encodes a marker's reveal span relative to the marker, so it stays correct
/// when an edit above shifts the marker without restyling it. The stored
/// range's `location` is the marker's offset into the span and its `length`
/// is the span's length.
enum MarkerSpan {
  static func value(span: NSRange, marker: NSRange) -> NSValue {
    NSValue(range: NSRange(location: marker.location - span.location, length: span.length))
  }

  /// The absolute span for a marker whose run starts at `markerStart`.
  static func span(from value: NSValue, markerStart: Int) -> NSRange {
    let relative = value.rangeValue
    return NSRange(location: markerStart - relative.location, length: relative.length)
  }
}
