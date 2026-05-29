import SwiftUI
import RuulCore

/// Full-list surface for active disputes. Toolbar add opens the
/// canonical `open_dispute(...)` flow; rows push into
/// `DisputeDetailView` (timeline + actions). The sanction-specific
/// "Disputar esta sanción" shortcut still lives in SanctionsListView's
/// swipe action.
public struct DisputesListView: View {
    @Bindable var store: DisputesStore
    let groupId: UUID
    /// V3 Batch B-4 — opcional para habilitar cross-link a
    /// SanctionDetailView desde el subject del dispute. Default nil =
    /// subject label queda estático.
    let container: DependencyContainer?
    let myMembershipId: UUID?

    @State private var pendingSanctionNav: GroupSanction?

    public init(
        store: DisputesStore,
        groupId: UUID,
        container: DependencyContainer? = nil,
        myMembershipId: UUID? = nil
    ) {
        self.store = store
        self.groupId = groupId
        self.container = container
        self.myMembershipId = myMembershipId
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.beginOpeningDispute()
                } label: {
                    Label(L10n.Disputes.openGenericConfirm, systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $store.isOpenPresented) {
            OpenDisputeSheet(store: store, groupId: groupId)
        }
        .navigationDestination(for: GroupDispute.self) { dispute in
            DisputeDetailView(
                store: store,
                groupId: groupId,
                dispute: dispute,
                onSelectSanction: container != nil ? { sanctionId in
                    if let sanction = container?.sanctionsStore.sanctions
                        .first(where: { $0.id == sanctionId }) {
                        pendingSanctionNav = sanction
                    }
                } : nil
            )
        }
        .navigationDestination(item: $pendingSanctionNav) { sanction in
            if let container, let mid = myMembershipId {
                SanctionDetailView(
                    container: container,
                    groupId: groupId,
                    myMembershipId: mid,
                    sanction: sanction
                )
            }
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
            // V3 Batch B-4 — necesario para resolver subjectId del
            // dispute a un GroupSanction concreto al hacer tap.
            if container != nil {
                await container?.sanctionsStore.refreshIfNeeded(groupId: groupId)
            }
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
            ContentUnavailableView {
                Label(L10n.Disputes.detailErrorTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Reintentar") {
                    Task { await store.refresh(groupId: groupId) }
                }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            if !store.hasDisputes {
                ContentUnavailableView {
                    Label(L10n.Disputes.emptyTitle, systemImage: "hand.raised")
                } description: {
                    Text(L10n.Disputes.emptyDescription)
                } actions: {
                    Button {
                        store.beginOpeningDispute()
                    } label: {
                        Text(L10n.Disputes.openGenericConfirm)
                    }
                    .buttonStyle(.glassProminent)
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.disputes) { dispute in
                    NavigationLink(value: dispute) {
                        DisputeRowView(dispute: dispute)
                    }
                }
            }
        }
    }
}
