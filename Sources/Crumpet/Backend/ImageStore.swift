import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Loads and caches the pictures that block images display. Owned by
/// `EditorLayoutManager`, which draws them, and shared with the coordinator,
/// which sizes their lines.
///
/// Used only on the main thread: layout, drawing, and the load callbacks all
/// run there. Loading itself runs off the main thread.
final class ImageStore: @unchecked Sendable {
  typealias Provider = @Sendable (String) async -> Data?

  /// Space above and below a displayed image, inside its line.
  static let verticalPadding: CGFloat = 8
  /// The corner radius a displayed image is clipped to.
  static let cornerRadius: CGFloat = 6

  /// Loads an image's bytes from its destination as written in the Markdown.
  /// When nil, `defaultLoad` is used.
  var provider: Provider?
  /// Called with the source of each image that finishes loading.
  var onLoad: (@MainActor (String) -> Void)?

  private var images: [String: PlatformImage] = [:]
  private var requested: Set<String> = []

  /// The picture for `source`, or nil while it loads or when it failed to
  /// load. The first call for a source starts its load.
  func image(for source: String) -> PlatformImage? {
    if let image = images[source] { return image }
    if requested.insert(source).inserted { load(source) }
    return nil
  }

  /// The size an image lays out at: its natural size in points, scaled down
  /// to fit `maxWidth`.
  static func displaySize(of image: PlatformImage, maxWidth: CGFloat) -> CGSize {
    let size = image.size
    guard size.width > 0, size.height > 0, maxWidth > 0 else { return .zero }
    let width = min(size.width, maxWidth)
    return CGSize(width: width, height: (size.height * width / size.width).rounded())
  }

  /// Loads `http`, `https`, and `file` URLs. Any other destination, including
  /// a relative path, loads nothing.
  static func defaultLoad(_ source: String) async -> Data? {
    guard let url = URL(string: source), let scheme = url.scheme?.lowercased() else { return nil }
    switch scheme {
    case "http", "https":
      return try? await URLSession.shared.data(from: url).0
    case "file":
      return try? Data(contentsOf: url)
    default:
      return nil
    }
  }

  private func load(_ source: String) {
    let provider = self.provider ?? Self.defaultLoad
    Task {
      let data = await provider(source)
      await MainActor.run { self.finish(source, data: data) }
    }
  }

  @MainActor
  private func finish(_ source: String, data: Data?) {
    guard let data, let image = PlatformImage(data: data) else { return }
    images[source] = image
    onLoad?(source)
  }
}
