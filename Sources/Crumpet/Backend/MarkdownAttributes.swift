import Foundation

extension NSAttributedString.Key {
  /// The block-level attributes (font, paragraph style, color) the last
  /// whole-document parse gave the paragraph this character belongs to,
  /// stamped on the text alongside them. It lets the per-keystroke path strip
  /// and re-derive a paragraph's inline markup without having to re-decide
  /// what kind of block the paragraph is, the one judgement a
  /// single-paragraph parse cannot make correctly, because the answer can
  /// live several paragraphs away.
  ///
  /// Internal to the editor: it travels with the text in the storage, but nothing
  /// outside the highlighter reads it, and pasted text is normalized by
  /// `TextStyle.sanitize` before it ever arrives.
  static let blockBase = NSAttributedString.Key("CrumpetBlockBase")

  /// Marks a markdown delimiter character (the `**`, `*`, or `` ` `` around
  /// bold, italic, and inline code) so the layout manager can conceal it when
  /// the caret isn't nearby. The value describes the whole span the delimiter
  /// belongs to (opening delimiter through closing), so `.span` reveal mode can
  /// uncover both delimiters together. It is stored relative to the marker's
  /// own run (see ``MarkerSpan``), so it stays correct when an edit elsewhere
  /// shifts the marker without restyling it. Purely a
  /// rendering hint: the character stays in the text storage, so the Markdown
  /// source and the `String` binding built from it are untouched. See
  /// ``MarkerConcealment``.
  static let markdownMarker = NSAttributedString.Key("CrumpetMarkdownMarker")

  /// Marks the bullet character (`-`, `*`, `+`) of an unordered list item so the
  /// layout manager can substitute the glyph ``ListBulletStyle`` selects. The
  /// value is an ignored `true`. Purely a rendering hint: the source character
  /// is untouched, like ``markdownMarker``. See ``MarkerConcealment``.
  static let listBulletMarker = NSAttributedString.Key("CrumpetListBulletMarker")

  /// Covers a whole image (`![alt](url)`). While the image's syntax is
  /// concealed, `EditorLayoutManager` draws a rounded chip behind what remains
  /// visible, the icon and the alt text. The value is a token unique to the
  /// image. See ``MarkerConcealment``.
  static let imageChip = NSAttributedString.Key("CrumpetImageChip")

  /// Marks an image's `!` so the concealed state draws it as the chip's icon
  /// glyph. The value is an ignored `true`. When the image's syntax is revealed,
  /// the source `!` shows as typed.
  static let imageChipIcon = NSAttributedString.Key("CrumpetImageChipIcon")

  /// Marks the `]` that ends a link's text so the concealed state draws it as
  /// a link icon after the text. The value is an ignored `true`. When the
  /// link's syntax is revealed, the source `]` shows as typed.
  static let linkChipIcon = NSAttributedString.Key("CrumpetLinkChipIcon")

  /// Marks the `!` of an image alone on its line. The value is the image's
  /// destination as written, which `ImageStore` loads. While the image's
  /// syntax is concealed and the picture has loaded, the line displays the
  /// picture in place of the chip.
  static let imageBlock = NSAttributedString.Key("CrumpetImageBlock")

  /// Marks the alt text of an image alone on its line. The value is the
  /// image's destination, like ``imageBlock``. The alt text also carries a
  /// ``markdownMarker``, which conceals it only once the picture has loaded.
  /// Until then it shows as the chip's label.
  static let imageCaption = NSAttributedString.Key("CrumpetImageCaption")
}

/// Encodes a marker's reveal span relative to the marker itself. An absolute
/// range would go stale when an edit above shifts the marker: the incremental
/// highlighter only restyles the edited paragraphs, so a heading or emphasis
/// further down keeps its old value and would reveal for the wrong characters.
///
/// The stored `NSRange` has `location` set to how far into the span the marker
/// starts, and `length` set to the span's length.
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
