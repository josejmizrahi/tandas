import SwiftUI
import RuulCore

/// Compact "Disputas" card for `GroupHomeView`. Only renders when the
/// group has at least one open dispute — empty state is "invisible"
/// so the home stays focused. Tapping navigates to the full list.
public struct GroupDisputesCard: View {
    @Bindable var store: DisputesStore

    public init(store: DisputesStore) {
        self.store = store
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "scale.3d")
                .font(.body.weight(.medium))
                .foregroundStyle(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(store.activeCount) abiertas")
                    .font(.body.weight(.semibold))
                if store.sanctionDisputesCount > 0 {
                    Text("\(store.sanctionDisputesCount) sobre sanciones")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
