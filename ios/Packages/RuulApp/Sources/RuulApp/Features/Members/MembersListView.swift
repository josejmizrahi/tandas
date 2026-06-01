import SwiftUI
import RuulCore

/// Members surface for a single group. Renders boundary items
/// (memberships + pending invites) returned by
/// `group_membership_boundary`. Designed to be embedded inside a
/// parent `NavigationStack` (mounted from `GroupHomeView`).
public struct MembersListView: View {
    @Bindable var store: MembersStore
    let groupId: UUID
    /// Optional handler invoked when the user taps an active membership
    /// row. Allows the parent (GroupHomeView) to push a member-history
    /// destination without coupling this view to the route registry.
    /// Pending invites stay non-tappable.
    let onSelectMember: ((MembershipBoundaryItem) -> Void)?
    /// V3-INV: when set, the "Invitar" button presents the canonical
    /// `InviteMemberSheet` (Contacts picker + ShareLink + code reveal).
    /// When nil — used by SwiftUI previews / tests — falls back to the
    /// store-bound `MembersInviteSheet` so callers without a container
    /// keep working.
    let container: DependencyContainer?

    public init(store: MembersStore,
                groupId: UUID,
                container: DependencyContainer? = nil,
                onSelectMember: ((MembershipBoundaryItem) -> Void)? = nil) {
        self.store = store
        self.groupId = groupId
        self.container = container
        self.onSelectMember = onSelectMember
    }

    public var body: some View {
        List {
            content
        }
        .navigationTitle(L10n.Members.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $store.searchText, prompt: Text(L10n.Members.searchPrompt))
        .refreshable {
            await store.refresh(groupId: groupId)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.isInviteSheetPresented = true
                } label: {
                    Label(L10n.Members.inviteButton, systemImage: "person.badge.plus")
                }
            }
        }
        .sheet(isPresented: $store.isInviteSheetPresented) {
            if let container {
                InviteMemberSheet(
                    container: container,
                    groupId: groupId
                ) {
                    store.isInviteSheetPresented = false
                    Task { await store.refresh(groupId: groupId) }
                }
            }
            // SwiftUI previews that omit `container` see a no-op
            // toolbar button — the production app always passes a
            // container so the canonical sheet always presents.
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            if store.items.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    MemberRowView(item: .placeholder)
                        .redacted(reason: .placeholder)
                }
            } else {
                loadedSections
            }
        case .failed(let message):
            MembersErrorStateView(message: message) {
                Task { await store.refresh(groupId: groupId) }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            if store.filteredItems.isEmpty {
                if store.searchText.isEmpty {
                    MembersEmptyStateView()
                        .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView.search(text: store.searchText)
                        .listRowBackground(Color.clear)
                }
            } else {
                loadedSections
            }
        }
    }

    @State private var pendingRevoke: PendingRevoke?

    @ViewBuilder
    private var loadedSections: some View {
        ForEach(store.sections) { section in
            Section {
                ForEach(section.members) { item in
                    rowFor(item)
                }
            } header: {
                Text(section.kind.title)
            }
        }
        .confirmationDialog(
            "¿Revocar invitación?",
            isPresented: Binding(
                get: { pendingRevoke != nil },
                set: { if !$0 { pendingRevoke = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRevoke
        ) { revoke in
            Button("Revocar", role: .destructive) {
                Task {
                    _ = await store.revokeInvite(
                        inviteId: revoke.inviteId,
                        groupId: groupId
                    )
                    pendingRevoke = nil
                }
            }
            Button("Cancelar", role: .cancel) {
                pendingRevoke = nil
            }
        } message: { revoke in
            Text("Se cancelará la invitación a \(revoke.displayName). Si tiene gastos pendientes en el grupo, no se podrá revocar hasta saldarlos.")
        }
    }

    @ViewBuilder
    private func rowFor(_ item: MembershipBoundaryItem) -> some View {
        if item.kind == .membership, onSelectMember != nil, item.membershipId != nil {
            Button {
                onSelectMember?(item)
            } label: {
                MemberRowView(item: item)
            }
            .buttonStyle(.plain)
            .pendingInviteSwipeAction(for: item) { invite in
                pendingRevoke = invite
            }
            .approveRequestSwipeAction(for: item, store: store, groupId: groupId)
        } else {
            MemberRowView(item: item)
                .pendingInviteSwipeAction(for: item) { invite in
                    pendingRevoke = invite
                }
                .approveRequestSwipeAction(for: item, store: store, groupId: groupId)
        }
    }

    /// V3-INV: a queued revoke confirmation. `inviteId` lives on the
    /// raw `MembershipBoundaryItem` when the row represents a pending
    /// invite or a placeholder membership; we capture it before
    /// presenting the dialog so the user sees who is being removed.
    fileprivate struct PendingRevoke: Identifiable, Equatable {
        let inviteId: UUID
        let displayName: String
        var id: UUID { inviteId }
    }
}

private extension View {
    /// V3-INV: surfaces a destructive "Revocar invitación" swipe action
    /// for rows that represent pending invites. After the V3-INV boundary
    /// mig the same `invite_id` is carried on both legacy invite rows
    /// (`kind == .invite`) and on placeholder memberships (`kind ==
    /// .membership && status == .invited`), so we trigger off the
    /// invite_id presence + invited status.
    @ViewBuilder
    func pendingInviteSwipeAction(
        for item: MembershipBoundaryItem,
        onRevoke: @escaping (MembersListView.PendingRevoke) -> Void
    ) -> some View {
        if let inviteId = item.inviteId, item.status == .invited {
            self.swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    onRevoke(MembersListView.PendingRevoke(
                        inviteId: inviteId,
                        displayName: item.displayName
                    ))
                } label: {
                    Label("Revocar", systemImage: "trash")
                }
            }
        } else {
            self
        }
    }

    /// D.24: surfaces a leading "Aprobar" swipe action for rows that
    /// represent pending join requests (`status == .requested`). Fires
    /// `MembersStore.approveRequest(...)` which RPCs
    /// `approve_membership_request` — backend re-asserts the
    /// `members.invite` permission, so non-admins see a 42501 from the
    /// store error path. UI gating by caller perms is deferred until
    /// MembersListView loads permissions itself.
    @ViewBuilder
    func approveRequestSwipeAction(
        for item: MembershipBoundaryItem,
        store: MembersStore,
        groupId: UUID
    ) -> some View {
        if item.kind == .membership, item.status == .requested, let mid = item.membershipId {
            self.swipeActions(edge: .leading) {
                Button {
                    Task { _ = await store.approveRequest(membershipId: mid, groupId: groupId) }
                } label: {
                    Label(L10n.Members.approveRequestAction, systemImage: "checkmark.circle")
                }
                .tint(.green)
            }
        } else {
            self
        }
    }
}

// MARK: - Preview placeholder

extension MembershipBoundaryItem {
    /// Stable redacted-placeholder shape for skeleton rows during the
    /// first load. SwiftUI swaps the literal glyphs for grey blocks.
    static var placeholder: MembershipBoundaryItem {
        MembershipBoundaryItem(
            id: UUID(),
            kind: .membership,
            displayName: "Placeholder Name",
            roleNames: ["Placeholder role"]
        )
    }
}

#Preview("Populated") {
    @Previewable @State var store = MembersStore(initialItems: MembersPreviewData.boundaryAll)
    return NavigationStack {
        MembersListView(store: store, groupId: UUID())
    }
}

#Preview("Empty") {
    @Previewable @State var store: MembersStore = {
        let s = MembersStore()
        s.phase = .loaded
        return s
    }()
    return NavigationStack {
        MembersListView(store: store, groupId: UUID())
    }
}

#Preview("Loading") {
    @Previewable @State var store = MembersStore()
    return NavigationStack {
        MembersListView(store: store, groupId: UUID())
    }
}

#Preview("Failed") {
    @Previewable @State var store: MembersStore = {
        let s = MembersStore()
        s.phase = .failed(message: "Sin conexión. Vuelve a intentar.")
        return s
    }()
    return NavigationStack {
        MembersListView(store: store, groupId: UUID())
    }
}
