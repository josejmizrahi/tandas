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
    @State private var pendingMemberNav: MembershipBoundaryItem?

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
                onSelectSubject: container != nil ? { kind, subjectId in
                    handleSubjectTap(kind: kind, subjectId: subjectId)
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
        .navigationDestination(item: $pendingMemberNav) { item in
            if let container {
                MemberDetailView(
                    sanctionsStore: container.sanctionsStore,
                    reputationStore: container.reputationStore,
                    moneyStore: container.moneyStore,
                    rolesStore: container.rolesStore,
                    membersStore: container.membersStore,
                    groupId: groupId,
                    memberItem: item,
                    activityFetcher: { gid, mid, limit in
                        try await container.rpcClient.groupEventsForMember(
                            groupId: gid,
                            membershipId: mid,
                            limit: limit
                        )
                    },
                    permissionsFetcher: { gid in
                        try await container.groupRepository.listMemberPermissions(
                            groupId: gid,
                            userId: nil
                        )
                    },
                    quickActionStores: MemberDetailView.QuickActionStores(
                        mandates: container.mandatesStore,
                        reputationFeed: container.reputationFeedStore
                    )
                )
            }
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
            // V3 Batch B-4 — pre-cargamos sanctions + members para
            // resolver el subjectId a la entidad concreta al tap.
            if container != nil {
                await container?.sanctionsStore.refreshIfNeeded(groupId: groupId)
                await container?.membersStore.refreshIfNeeded(groupId: groupId)
            }
        }
    }

    /// V3 Batch B-4 — unified dispatcher para cross-link desde el
    /// subject del DisputeDetail. Por kind resolvemos client-side y
    /// empujamos al detail apropiado dentro de este NavigationStack
    /// (no usamos deepLinkRouter para preservar el back stack en lugar
    /// de saltar de tab).
    private func handleSubjectTap(kind: DisputeSubjectKind, subjectId: UUID) {
        switch kind {
        case .sanction:
            if let sanction = container?.sanctionsStore.sanctions
                .first(where: { $0.id == subjectId }) {
                pendingSanctionNav = sanction
            }
        case .member:
            if let item = container?.membersStore.items
                .first(where: { $0.membershipId == subjectId }) {
                pendingMemberNav = item
            }
        case .rule, .resource, .other:
            // Slice futuro: rule push EngineRuleDetailView, resource
            // push ResourceDetailView. Hoy no-op (subjectRow ya marca
            // estos kinds como no-navegables).
            break
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
