import Foundation
import UniformTypeIdentifiers

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// An image the user pasted into the editor, encoded as PNG or JPEG. Handed to
/// the closure given to ``MarkdownEditor/onPasteImage(_:)``.
public struct PastedImage: Sendable, Equatable {
  /// The encoded image bytes.
  public var data: Data
  /// The MIME type of `data`, `image/png` or `image/jpeg`.
  public var mimeType: String
  /// The file extension matching `mimeType`, without the dot.
  public var fileExtension: String

  public init(data: Data, mimeType: String, fileExtension: String) {
    self.data = data
    self.mimeType = mimeType
    self.fileExtension = fileExtension
  }

  static func png(_ data: Data) -> PastedImage {
    PastedImage(data: data, mimeType: "image/png", fileExtension: "png")
  }

  static func jpeg(_ data: Data) -> PastedImage {
    PastedImage(data: data, mimeType: "image/jpeg", fileExtension: "jpg")
  }
}

#if canImport(AppKit)
  extension NSPasteboard {
    /// The image on the pasteboard, or nil when it holds text, which always
    /// pastes as text. A copied image file is read from disk; other images are
    /// taken as PNG or JPEG, with TIFF (what most apps copy) converted to PNG.
    var pastedImage: PastedImage? {
      if let urls = readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
        let url = urls.first, urls.count == 1,
        let type = UTType(filenameExtension: url.pathExtension),
        type.conforms(to: .image), let data = try? Data(contentsOf: url)
      {
        if type.conforms(to: .jpeg) { return .jpeg(data) }
        if type.conforms(to: .png) { return .png(data) }
        return Self.png(from: data)
      }
      guard string(forType: .string) == nil else { return nil }
      if let data = data(forType: .png) { return .png(data) }
      if let data = data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) {
        return .jpeg(data)
      }
      if let data = data(forType: .tiff) { return Self.png(from: data) }
      return nil
    }

    private static func png(from data: Data) -> PastedImage? {
      guard let rep = NSBitmapImageRep(data: data),
        let png = rep.representation(using: .png, properties: [:])
      else { return nil }
      return .png(png)
    }
  }
#elseif canImport(UIKit)
  extension UIPasteboard {
    /// The image on the pasteboard, or nil when it holds text, which always
    /// pastes as text.
    var pastedImage: PastedImage? {
      guard !hasStrings, hasImages else { return nil }
      if let data = data(forPasteboardType: UTType.png.identifier) { return .png(data) }
      if let data = data(forPasteboardType: UTType.jpeg.identifier) { return .jpeg(data) }
      if let data = image?.pngData() { return .png(data) }
      return nil
    }
  }
#endif
