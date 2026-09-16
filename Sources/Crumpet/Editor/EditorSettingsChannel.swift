import SwiftUI

/// Applies an ``EditorSettings`` to every live editor immediately, without
/// waiting for a SwiftUI update pass.
///
/// ``EditorSettingsForm`` writes a new value on every step of a slider drag,
/// but SwiftUI does not re-evaluate a view in another window while the drag's
/// event-tracking run loop runs, so an editor bound to the stored settings
/// restyles only once the drag ends and the whole scrub lands at mouse-up.
/// Sending each value here restyles the document on the spot instead.
///
/// This is a live path, not a storage one. Keep persisting settings however you
/// already do (`@AppStorage` and the rest). That store is what a cold launch
/// and every change outside a drag read. The channel only makes a scrub visible
/// while it happens.
///
/// One channel serves the whole app, and a `Settings` scene shares no state
/// with a `WindowGroup`, so hold it somewhere both reach (a `@MainActor static
/// let`, or one instance put into both scenes' environments):
///
/// ```swift
/// enum AppSettings {
///   @MainActor static let editorChannel = EditorSettingsChannel()
/// }
///
/// struct EditorScreen: View {
///   @AppStorage("editorSettings") private var settings = EditorSettings()
///   @State private var text = ""
///   var body: some View {
///     MarkdownEditor(text: $text)
///       .editorSettings(settings)
///       .editorSettingsChannel(AppSettings.editorChannel)
///   }
/// }
///
/// struct SettingsScreen: View {
///   @AppStorage("editorSettings") private var settings = EditorSettings()
///   var body: some View {
///     Form { EditorSettingsForm(settings: $settings) }
///       .onChange(of: settings) { _, new in AppSettings.editorChannel.send(new) }
///   }
/// }
/// ```
///
/// Every attached editor receives the value, so the channel keeps one
/// subscriber per editor rather than the single handler ``EditorCommands``
/// uses: commands go to the focused editor, a settings change goes to all of
/// them.
@MainActor
public final class EditorSettingsChannel {
  /// One entry per attached editor, each closure holding its coordinator
  /// weakly. Registered when the editor's platform view is made and dropped
  /// when it's dismantled.
  private var subscribers: [(id: UUID, apply: (EditorSettings) -> Void)] = []

  public init() {}

  /// Applies `settings` to every attached editor, synchronously, restyling
  /// each document before this call returns. Safe to call on every slider
  /// step: the editor compares each value against what it already applied and
  /// does nothing when they match.
  public func send(_ settings: EditorSettings) {
    for subscriber in subscribers { subscriber.apply(settings) }
  }

  /// Registers an editor. The returned id identifies it to ``unsubscribe(_:)``.
  func subscribe(_ apply: @escaping (EditorSettings) -> Void) -> UUID {
    let id = UUID()
    subscribers.append((id, apply))
    return id
  }

  func unsubscribe(_ id: UUID) {
    subscribers.removeAll { $0.id == id }
  }
}
