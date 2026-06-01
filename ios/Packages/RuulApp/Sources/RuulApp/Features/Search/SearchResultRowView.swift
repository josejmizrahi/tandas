import SwiftUI
import RuulCore

/// D.22 — Compact row for a single search result. Renders icon +
/// title + subtitle in a uniform shape across entity types. V1
/// intentionally does NOT delegate to entity-specific rows
/// (MemberRowView / ResourceRowView / etc.) so the search surface
/// stays self-contained and we don't need to thread the per-entity
/// domain models through the sheet.
public struct SearchResultRowView: View {
    public let result: SearchResult

    public init(result: SearchResult) {
        self.result = result
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.entityType.iconKey)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.body)
                    .lineLimit(1)
                if let subtitle = result.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
