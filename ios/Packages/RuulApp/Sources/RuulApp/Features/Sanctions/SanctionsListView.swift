import SwiftUI
import RuulCore

/// Full-list surface for active sanctions. Embeds inside a parent
/// `NavigationStack`. The "Emitir" toolbar action opens the issue
/// sheet via the shared store flag.
public struct SanctionsListView: View {
    let container: DependencyContainer
    @Bindable var store: SanctionsStore
    @Bindable var membersStore: MembersStore
    let groupId: UUID
    let myMembershipId: UUID
    /// Optional handler invoked when the user swipes "Disputar" on a
    /// row. Lets the parent open a `DisputeSanctionSheet` without
    /// coupling this view to the disputes store.
    let onDispute: ((UUID) -> Void)?

    public init(container: DependencyContainer,
                store: SanctionsStore,
                membersStore: MembersStore,
                groupId: UUID,
                myMembershipId: UUID,
                onDispute: ((UUID) -> Void)? = nil) {
        self.container = container
        self.store = store
        self.membersStore = membersStore
        self.groupId = groupId
        self.myMembershipId = myMembershipId
        self.onDispute = onDispute
    }

    public var body: some View {
        List {
            content
        }
        .navigationTitle(L10n.Sanctions.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(groupId: groupId)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.beginIssuing()
                } label: {
                    Label(String(localized: L10n.Sanctions.addButton), systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $store.isIssuePresented) {
            IssueSanctionSheet(
                store: store,
                membersStore: membersStore,
                groupId: groupId
            )
        }
        .navigationDestination(for: GroupSanction.self) { sanction in
            SanctionDetailView(
                container: container,
                groupId: groupId,
                myMembershipId: myMembershipId,
                sanction: sanction
            )
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
            await membersStore.refreshIfNeeded(groupId: groupId)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ForEach(0..<3, id: \.self) { _ in
                SanctionRowView(sanction: GroupSanction(
                    id: UUID(), groupId: groupId,
                    targetMembershipId: UUID(),
                    targetDisplayName: "Cargando…",
                    kind: .warning,
                    reason: "Placeholder reason"
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
            if !store.hasSanctions {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.Sanctions.emptyTitle).font(.headline)
                    Text(L10n.Sanctions.emptyDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                ForEach(store.sanctions) { sanction in
                    NavigationLink(value: sanction) {
                        SanctionRowView(sanction: sanction)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if let onDispute,
                           sanction.status != .disputed,
                           sanction.status.isOpen {
                            Button {
                                onDispute(sanction.id)
                            } label: {
                                Label(
                                    String(localized: L10n.Disputes.openButton),
                                    systemImage: "scale.3d"
                                )
                            }
                            .tint(.orange)
                        }
                    }
                }
            }
        }
    }
}
