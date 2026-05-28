import SwiftUI
import RuulCore

/// Situational stream for the Inicio tab — replaces the legacy
/// `GroupHomeView` body composed of typed cards (purpose / rules /
/// resources / sanctions / money) with a data-driven feed of life-state
/// clusters per `doctrine_group_space_situational`.
///
/// Cluster order is canonical and fixed; each cluster is invisible
/// when empty:
///
///     1. Necesita atención  (decisions sin tu voto, sanciones que te
///        afectan, foundation incompleta)
///     2. Próximo            (decisions que cierran pronto)
///     3. Acabó de pasar     (system_events recientes del grupo)
///
/// The `Deudas` and `En uso` clusters from the canonical doctrine are
/// scaffolded but not yet wired here — they appear empty/invisible
/// until follow-ups load their data sources. See doctrine §
/// "Implementation status".
///
/// Foundation status stays at the very top while the group isn't ready
/// — admins/founders need a single tap into the missing primitive.
struct GroupHomeFeedView: View {
    let container: DependencyContainer
    let group: GroupListItem

    @Environment(\.dismiss) private var dismiss

    // MARK: - Sheet state (mirrors what GroupHomeView used to own)

    @State private var isShowingExpenseSheet = false
    @State private var isShowingSettlementSheet = false
    @State private var isShowingInviteSheet = false
    @State private var isConfirmingLeave = false
    @State private var leaveError: UserFacingError?
    @State private var pendingMemberSelection: MembershipBoundaryItem?

    var body: some View {
        List {
            foundationSection
            attentionSection
            upcomingSection
            recentlyHappenedSection
            quickActionsSection
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { emptyOverlay }
        .navigationDestination(item: $pendingMemberSelection) { item in
            MemberDetailView(
                sanctionsStore: container.sanctionsStore,
                reputationStore: container.reputationStore,
                moneyStore: container.moneyStore,
                rolesStore: container.rolesStore,
                membersStore: container.membersStore,
                groupId: group.id,
                memberItem: item
            )
        }
        .navigationDestination(for: DecisionsDestination.self) { _ in
            DecisionsListView(store: container.decisionsStore, groupId: group.id)
        }
        .navigationDestination(for: GroupHistoryDestination.self) { _ in
            GroupHistoryView(store: container.eventsStore, groupId: group.id)
        }
        .navigationDestination(for: SanctionsDestination.self) { _ in
            SanctionsListView(
                container: container,
                store: container.sanctionsStore,
                membersStore: container.membersStore,
                groupId: group.id,
                myMembershipId: group.membershipId,
                onDispute: { sanctionId in
                    container.disputesStore.beginDisputingSanction(sanctionId)
                }
            )
        }
        .navigationDestination(for: MoneyDashboardDestination.self) { _ in
            MoneyDashboardView(
                container: container,
                groupId: group.id,
                myMembershipId: group.membershipId
            )
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                moreMenu
            }
        }
        .refreshable { await refresh() }
        .task { await refresh() }
        .sheet(isPresented: $isShowingExpenseSheet) {
            RecordExpenseSheet(
                container: container,
                groupId: group.id,
                myMembershipId: group.membershipId
            ) {
                isShowingExpenseSheet = false
                Task { await refresh() }
            }
        }
        .sheet(isPresented: $isShowingSettlementSheet) {
            RecordSettlementSheet(
                container: container,
                groupId: group.id,
                myMembershipId: group.membershipId
            ) {
                isShowingSettlementSheet = false
                Task { await refresh() }
            }
        }
        .sheet(isPresented: $isShowingInviteSheet) {
            InviteMemberSheet(
                container: container,
                groupId: group.id
            ) {
                isShowingInviteSheet = false
            }
        }
        .alert("Salir del grupo", isPresented: $isConfirmingLeave) {
            Button("Cancelar", role: .cancel) {}
            Button("Salir", role: .destructive) {
                Task { await leave() }
            }
        } message: {
            Text("Dejarás de ver lo que pase aquí. Puedes volver con otra invitación.")
        }
        .alert(
            leaveError?.title ?? "",
            isPresented: Binding(
                get: { leaveError != nil },
                set: { if !$0 { leaveError = nil } }
            ),
            actions: { Button("OK") { leaveError = nil } },
            message: { Text(leaveError?.message ?? "") }
        )
    }

    // MARK: - Foundation status

    @ViewBuilder
    private var foundationSection: some View {
        // Only render while the group isn't yet ready — once all five
        // primitives are checked, the card collapses entirely.
        if let status = container.foundationStatusStore.status, status.isReady {
            EmptyView()
        } else {
            Section(L10n.Foundation.title) {
                FoundationStatusCard(
                    store: container.foundationStatusStore,
                    onSelect: handleFoundationTap
                )
            }
        }
    }

    // MARK: - Necesita atención

    @ViewBuilder
    private var attentionSection: some View {
        let items = attentionItems
        if !items.isEmpty {
            Section("Necesita atención") {
                ForEach(items) { item in
                    AttentionRow(item: item, onSelect: handleAttentionTap)
                }
            }
        }
    }

    private var attentionItems: [AttentionItem] {
        var result: [AttentionItem] = []

        // Open decisions where the caller hasn't cast a vote yet.
        for decision in container.decisionsStore.open where decision.myVoteValue == nil {
            result.append(.decisionNeedsVote(decision))
        }

        // Active sanctions targeting the caller.
        let myMid = group.membershipId
        for sanction in container.sanctionsStore.sanctions
        where sanction.targetMembershipId == myMid && sanction.status == .active {
            result.append(.sanctionOnMe(sanction))
        }

        return result
    }

    // MARK: - Próximo

    @ViewBuilder
    private var upcomingSection: some View {
        let items = upcomingItems
        if !items.isEmpty {
            Section("Próximo") {
                ForEach(items) { item in
                    UpcomingRow(item: item)
                }
            }
        }
    }

    private var upcomingItems: [UpcomingItem] {
        let now = Date()
        // Decisions closing in the next ~14 days, sorted by closesAt asc.
        let window: TimeInterval = 60 * 60 * 24 * 14
        return container.decisionsStore.open
            .filter { summary in
                guard let closes = summary.closesAt else { return false }
                return closes > now && closes.timeIntervalSince(now) <= window
            }
            .sorted { ($0.closesAt ?? .distantFuture) < ($1.closesAt ?? .distantFuture) }
            .map { UpcomingItem.decisionClosing($0) }
    }

    // MARK: - Acabó de pasar

    @ViewBuilder
    private var recentlyHappenedSection: some View {
        let items = recentEvents
        if !items.isEmpty {
            Section("Acabó de pasar") {
                ForEach(items) { event in
                    RecentEventRow(event: event)
                }
                NavigationLink(value: GroupHistoryDestination()) {
                    Text("Ver toda la historia")
                        .font(.subheadline)
                }
            }
        }
    }

    private var recentEvents: [GroupEvent] {
        Array(container.eventsStore.events.prefix(5))
    }

    // MARK: - Quick actions (transitional — actions need somewhere to live)

    @ViewBuilder
    private var quickActionsSection: some View {
        Section {
            Button {
                isShowingExpenseSheet = true
            } label: {
                Label("Registrar gasto", systemImage: "plus.circle")
            }
            Button {
                isShowingSettlementSheet = true
            } label: {
                Label("Liquidar al grupo", systemImage: "checkmark.circle")
            }
            Button {
                isShowingInviteSheet = true
            } label: {
                Label("Invitar a alguien", systemImage: "person.crop.circle.badge.plus")
            }
        }
    }

    // MARK: - Empty overlay (presence + invite CTA when literally nothing has happened yet)

    @ViewBuilder
    private var emptyOverlay: some View {
        // Show ONLY when:
        // (1) Foundation has loaded and is ready (so we're past first-setup), AND
        // (2) every cluster collapses to zero items.
        let isReady = container.foundationStatusStore.status?.isReady ?? false
        let attentionEmpty = attentionItems.isEmpty
        let upcomingEmpty = upcomingItems.isEmpty
        let recentEmpty = recentEvents.isEmpty
        if isReady, attentionEmpty, upcomingEmpty, recentEmpty {
            VStack(spacing: 16) {
                Image(systemName: "person.3.sequence")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Todavía nada por aquí")
                    .font(.title3.weight(.semibold))
                Text("Cuando alguien proponga una decisión, registre un gasto o hagan algo juntos, va a aparecer en este espacio.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button {
                    isShowingInviteSheet = true
                } label: {
                    Label("Invitar a alguien", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(true)
        }
    }

    // MARK: - Toolbar "Más" menu

    @ViewBuilder
    private var moreMenu: some View {
        Menu {
            NavigationLink(value: GroupHistoryDestination()) {
                Label(L10n.History.menuLink, systemImage: "clock.arrow.circlepath")
            }
            NavigationLink(value: DecisionsDestination()) {
                Label(L10n.Decisions.menuLink, systemImage: "checkmark.seal")
            }
            Divider()
            Button(role: .destructive) {
                isConfirmingLeave = true
            } label: {
                Label("Salir del grupo", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Label("Más", systemImage: "ellipsis.circle")
        }
    }

    // MARK: - Handlers

    private func handleFoundationTap(_ kind: FoundationPrimitiveKind) {
        switch kind {
        case .members, .boundary:
            isShowingInviteSheet = true
        case .purpose:
            container.purposeStore.beginEditing(kind: .declared)
        case .rules:
            container.rulesStore.beginCreating()
        case .resources:
            container.resourcesStore.beginCreating()
        }
    }

    private func handleAttentionTap(_ item: AttentionItem) {
        switch item {
        case .decisionNeedsVote:
            // Push the decisions list — the caller picks the right
            // decision there. Deeper "tap into specific decision detail"
            // is wired through the deep-link router for v1.
            // (Foundation slice — no programmatic NavigationPath yet.)
            break
        case .sanctionOnMe:
            // Same — push to sanctions list via the Más menu / deep
            // link for now. The cluster surfaces awareness, not a
            // dedicated push target yet.
            break
        }
    }

    // MARK: - Refresh + actions

    private func refresh() async {
        // Hydrate every store the feed reads from. The foundation
        // store is critical (drives the empty-overlay decision).
        await container.foundationStatusStore.refresh(groupId: group.id)
        await container.currentGroupStore.refresh()
        await container.moneyStore.refresh(groupId: group.id, membershipId: group.membershipId)
        await container.decisionsStore.refresh(groupId: group.id)
        await container.sanctionsStore.refresh(groupId: group.id)
        await container.eventsStore.refresh(groupId: group.id)
    }

    private func leave() async {
        do {
            try await container.groupRepository.leaveGroup(groupId: group.id, reason: nil)
            container.moneyStore.clear()
            await container.currentGroupStore.setGroup(nil)
            await container.groupsStore.refresh()
            dismiss()
        } catch {
            leaveError = UserFacingError.from(error)
        }
    }

    // MARK: - Cluster item enums

    enum AttentionItem: Identifiable, Hashable {
        case decisionNeedsVote(GroupDecisionSummary)
        case sanctionOnMe(GroupSanction)

        var id: String {
            switch self {
            case .decisionNeedsVote(let d): return "decision:\(d.id.uuidString)"
            case .sanctionOnMe(let s):      return "sanction:\(s.id.uuidString)"
            }
        }
    }

    enum UpcomingItem: Identifiable, Hashable {
        case decisionClosing(GroupDecisionSummary)

        var id: String {
            switch self {
            case .decisionClosing(let d): return "decision:\(d.id.uuidString)"
            }
        }
    }

    // MARK: - Navigation tokens

    private struct DecisionsDestination: Hashable {}
    private struct GroupHistoryDestination: Hashable {}
    private struct SanctionsDestination: Hashable {}
    private struct MoneyDashboardDestination: Hashable {}
}

// MARK: - Cluster row views

private struct AttentionRow: View {
    let item: GroupHomeFeedView.AttentionItem
    let onSelect: (GroupHomeFeedView.AttentionItem) -> Void

    var body: some View {
        Button {
            onSelect(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var icon: String {
        switch item {
        case .decisionNeedsVote:  return "checkmark.seal"
        case .sanctionOnMe:       return "exclamationmark.shield"
        }
    }

    private var headline: String {
        switch item {
        case .decisionNeedsVote(let d):
            return "Falta tu voto: \(d.title)"
        case .sanctionOnMe(let s):
            return "Sanción contigo: \(s.reason)"
        }
    }

    private var detail: String? {
        switch item {
        case .decisionNeedsVote(let d):
            if let closes = d.closesAt {
                return "Cierra \(closes.formatted(.relative(presentation: .named)))"
            }
            return nil
        case .sanctionOnMe(let s):
            if let amount = s.amount {
                return "Multa de \(amount.formatted()) MXN"
            }
            return nil
        }
    }
}

private struct UpcomingRow: View {
    let item: GroupHomeFeedView.UpcomingItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.body.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var headline: String {
        switch item {
        case .decisionClosing(let d):
            return d.title
        }
    }

    private var detail: String? {
        switch item {
        case .decisionClosing(let d):
            guard let closes = d.closesAt else { return nil }
            return "Cierra \(closes.formatted(.relative(presentation: .named)))"
        }
    }
}

private struct RecentEventRow: View {
    let event: GroupEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(.tertiary)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary ?? event.eventType)
                    .font(.body)
                    .lineLimit(3)
                if let when = event.occurredAt {
                    Text(when.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
