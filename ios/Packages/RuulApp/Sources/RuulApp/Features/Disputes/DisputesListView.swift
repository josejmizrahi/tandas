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
            DisputeDetailView(store: store, groupId: groupId, dispute: dispute)
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
