import SwiftUI
import RuulCore

/// Compact "Sanciones" card for `GroupHomeView`. Renders a tiny summary:
/// "N activas · M en disputa" + a tap-to-issue affordance when empty.
/// Tapping any state opens the full list (via parent NavigationLink).
public struct GroupSanctionsCard: View {
    @Bindable var store: SanctionsStore
    let onAdd: () -> Void

    public init(store: SanctionsStore, onAdd: @escaping () -> Void) {
        self.store = store
        self.onAdd = onAdd
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield")
                .font(.body.weight(.medium))
                .foregroundStyle(store.disputedCount > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                if store.hasSanctions {
                    Text("\(store.activeCount) activas")
                        .font(.body.weight(.semibold))
                    if store.disputedCount > 0 {
                        Text("\(store.disputedCount) en disputa")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text(L10n.Sanctions.emptyTitle)
                        .font(.body.weight(.semibold))
                    Text(L10n.Sanctions.emptyDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Button {
                onAdd()
            } label: {
                Text(L10n.Sanctions.addButton)
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}
