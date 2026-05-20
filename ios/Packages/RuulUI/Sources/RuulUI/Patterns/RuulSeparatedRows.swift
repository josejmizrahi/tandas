import SwiftUI

/// Apple Settings / Mail list pattern: a vertical stack of rows
/// separated by hairline `Divider()`s, no card chrome on the rows
/// themselves. Replaces the legacy `VStack(spacing: xs) + cards` look
/// across the app — flat, calm, Luma-faithful.
///
/// Inset of the divider is fixed at `lg + xxl` (52pt) from the leading
/// edge so it lines up just past a 40pt icon badge + the row's
/// internal padding, matching Apple Settings.
///
/// Use as the body of a section. Pair with a `sectionLabel` above and
/// a Spacer / next section below — the parent provides the grouping.
@MainActor
public struct RuulSeparatedRows<Item: Identifiable, RowContent: View>: View {
    public let items: [Item]
    public let rowContent: (Item) -> RowContent
    public let dividerLeadingInset: CGFloat

    public init(
        items: [Item],
        dividerLeadingInset: CGFloat = RuulSpacing.lg + RuulSpacing.xxl,
        @ViewBuilder rowContent: @escaping (Item) -> RowContent
    ) {
        self.items = items
        self.rowContent = rowContent
        self.dividerLeadingInset = dividerLeadingInset
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                rowContent(item)
                if idx < items.count - 1 {
                    hairline
                }
            }
        }
    }

    /// Very subtle hairline — Luma uses ~8% primary-text opacity, much
    /// quieter than SwiftUI's default Divider() (~16%) or the
    /// `ruulSeparator` token (~24% in light mode). Inset to match
    /// Apple Settings / Mail (past the leading thumbnail).
    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, dividerLeadingInset)
    }
}

#if DEBUG
private struct PreviewRow: Identifiable, Hashable {
    let id: Int
    let title: String
    let subtitle: String
}

#Preview("RuulSeparatedRows") {
    let items: [PreviewRow] = (1...5).map { i in
        PreviewRow(
            id: i,
            title: "Item \(i)",
            subtitle: "Subtitle for item \(i)"
        )
    }
    return ScrollView {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Text("LISTA")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            RuulSeparatedRows(items: items) { item in
                HStack(spacing: RuulSpacing.md) {
                    Circle()
                        .fill(Color.ruulFillGlass)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.headline)
                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, RuulSpacing.md)
            }
        }
        .padding(RuulSpacing.lg)
    }
    .background(Color.ruulBackground)
}
#endif
