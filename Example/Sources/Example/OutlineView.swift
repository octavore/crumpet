import Crumpet
import SwiftUI

/// Popover listing the document's headings. Selecting a row jumps to it.
struct OutlineView: View {
  let items: [OutlineItem]
  let onSelect: (OutlineItem) -> Void

  /// Indent per heading level below the shallowest one present.
  private let indent: CGFloat = 28

  private var baseLevel: Int { items.map(\.level).min() ?? 1 }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Outline")
        .font(.headline)
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)

      if items.isEmpty {
        Text("No headings")
          .foregroundStyle(.tertiary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
              OutlineRow(item: item, indent: indent * CGFloat(item.level - baseLevel)) {
                onSelect(item)
              }
            }
          }
        }
      }
    }
    .padding(20)
    .frame(minWidth: 240, maxWidth: 360, maxHeight: 420, alignment: .topLeading)
  }
}

private struct OutlineRow: View {
  let item: OutlineItem
  let indent: CGFloat
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: "circle")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
        Text(item.title.isEmpty ? "Untitled" : item.title)
          .font(.title3)
          .lineLimit(1)
          .truncationMode(.tail)
          .foregroundStyle(item.title.isEmpty ? .secondary : .primary)
        Spacer(minLength: 0)
      }
      .padding(.leading, indent)
      .padding(.vertical, 5)
      .padding(.horizontal, 6)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(hovering ? 0.08 : 0)))
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}
