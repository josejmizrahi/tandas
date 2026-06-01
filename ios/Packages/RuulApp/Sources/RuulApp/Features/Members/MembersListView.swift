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
        .sheet(isPresented: proposeAcceptSheetBinding) {
            if let container {
                ProposeDecisionSheet(
                    store: container.decisionsStore,
                    groupId: groupId,
                    sanctionsStore: nil,
                    mandatesStore: nil,
                    membersStore: store,
                    rulesStore: nil,
                    decisionsRepository: container.decisionsRepository
                )
            }
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
            // D.24: keep boundary policy fresh so the inline Aprobar
            // button knows whether to direct-approve or open a vote.
            if let container {
                await container.boundaryPolicyStore.refreshIfNeeded(groupId: groupId)
            }
        }
    }

    /// D.24 — sheet binding piggybacking on `DecisionsStore.isProposePresented`
    /// so the same source-of-truth that drives the rest of the propose-decision
    /// surface dismisses cleanly when the user cancels/saves.
    private var proposeAcceptSheetBinding: Binding<Bool> {
        Binding(
            get: { container?.decisionsStore.isProposePresented ?? false },
            set: { container?.decisionsStore.isProposePresented = $0 }
        )
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
        if item.kind == .membership, item.status == .requested, let mid = item.membershipId {
            // D.24: Instagram-style — visible Aprobar + Rechazar pills
            // beneath the member row. Tap of the member row still pushes
            // detail when a selection handler is present.
            // D.24.3: if there's already an open `decision.membership_accept`
            // referencing this membership, swap the pills for an "En
            // votación" link — the request is no longer admin-actionable
            // and goes through the group vote instead.
            VStack(alignment: .leading, spacing: 10) {
                if onSelectMember != nil {
                    Button {
                        onSelectMember?(item)
                    } label: {
                        MemberRowView(item: item)
                    }
                    .buttonStyle(.plain)
                } else {
                    MemberRowView(item: item)
                }
                if let openVote = openVoteForRequest(mid) {
                    pendingVoteRow(openVote)
                } else {
                    requestActionButtons(for: mid)
                }
            }
            .padding(.vertical, 4)
        } else if item.kind == .membership, onSelectMember != nil, item.membershipId != nil {
            Button {
                onSelectMember?(item)
            } label: {
                MemberRowView(item: item)
            }
            .buttonStyle(.plain)
            .pendingInviteSwipeAction(for: item) { invite in
                pendingRevoke = invite
            }
        } else {
            MemberRowView(item: item)
                .pendingInviteSwipeAction(for: item) { invite in
                    pendingRevoke = invite
                }
        }
    }

    /// D.24 — Aprobar / Rechazar pills for a pending join request.
    /// Aprobar routes by `boundary_policy.requires_approval`:
    /// - false → direct `approve_membership_request` (admin auto-approves)
    /// - true  → opens `ProposeDecisionSheet` pre-filled with
    ///   `decision.membership_accept` so the group votes the new member in.
    /// Rechazar moves the membership to `left` with a canned reason.
    @ViewBuilder
    private func requestActionButtons(for membershipId: UUID) -> some View {
        HStack(spacing: 10) {
            Button {
                handleApprove(membershipId: membershipId)
            } label: {
                Label(L10n.Members.approveRequestAction, systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            // D.24.1: rely on `.borderedProminent`'s default app accent
            // tint instead of a hardcoded `.green`. Reject relies on
            // `role: .destructive` to derive its destructive semantic.
            .buttonStyle(.borderedProminent)

            Button(role: .destructive) {
                handleReject(membershipId: membershipId)
            } label: {
                Label(L10n.Members.rejectRequestAction, systemImage: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func handleApprove(membershipId: UUID) {
        guard let container else {
            Task { _ = await store.approveRequest(membershipId: membershipId, groupId: groupId) }
            return
        }
        let requiresApproval = container.boundaryPolicyStore.policy?.requiresApproval ?? false
        if requiresApproval {
            container.decisionsStore.beginProposingMembershipAccept(membershipId: membershipId)
        } else {
            Task { _ = await store.approveRequest(membershipId: membershipId, groupId: groupId) }
        }
    }

    private func handleReject(membershipId: UUID) {
        Task { _ = await store.rejectRequest(membershipId: membershipId, groupId: groupId) }
    }

    /// D.24.3 — looks up the currently-open `decision.membership_accept`
    /// (or any open `membership`-type decision referencing this
    /// membership) so the row can render an "En votación" state instead
    /// of admin-actionable pills. Nil = no open vote yet; show pills.
    private func openVoteForRequest(_ membershipId: UUID) -> GroupDecisionSummary? {
        guard let container else { return nil }
        return container.decisionsStore.open.first { decision in
            decision.referenceKind == "membership" && decision.referenceId == membershipId
        }
    }

    /// D.24.3 — replacement for the Aprobar/Rechazar pills when the
    /// request is already going through a group vote. Renders a single
    /// "Ver votación" link that pushes the decision detail via the
    /// shared `DeepLinkRouter` (mirrors the path other surfaces use).
    @ViewBuilder
    private func pendingVoteRow(_ summary: GroupDecisionSummary) -> some View {
        Button {
            container?.deepLinkRouter.apply(
                .decision(groupId: groupId, decisionId: summary.id)
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("En votación del grupo")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(summary.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    // D.24 (Instagram-style): swipe-approve removed in favor of visible
    // inline pills rendered by `requestActionButtons(for:)` in the
    // MembersListView body. Reject also routes through that view's
    // `handleReject(membershipId:)` → `store.rejectRequest(...)`.
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
