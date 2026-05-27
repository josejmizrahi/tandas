import SwiftUI
import RuulCore

/// Full-list surface for active disputes. Foundation V1 is read-only;
/// the only write affordance from iOS is "Disputar esta sanción" via
/// a swipe action on the sanctions list — not on this screen.
public struct DisputesListView: View {
    @Bindable var store: DisputesStore
    let groupId: UUID

    public init(store: DisputesStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        List {
            content
        }
        .navigationTitle(L10n.Disputes.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(groupId: groupId)
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ForEach(0..<3, id: \.self) { _ in
                DisputeRowView(dispute: GroupDispute(
                    id: UUID(), groupId: groupId,
                    subjectKind: .sanction,
                    title: "Placeholder title for skeleton"
                ))
                .redacted(reason: .placeholder)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Reintentar") {
                    Task { await store.refresh(groupId: groupId) }
                }
            }
            .padding(.vertical, 6)
        case .loaded:
            if !store.hasDisputes {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.Disputes.emptyTitle).font(.headline)
                    Text(L10n.Disputes.emptyDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                ForEach(store.disputes) { dispute in
                    DisputeRowView(dispute: dispute)
                }
            }
        }
    }
}
