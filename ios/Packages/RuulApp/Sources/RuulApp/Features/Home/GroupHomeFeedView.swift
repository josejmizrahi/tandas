import SwiftUI
import RuulCore

/// Situational stream for the Inicio tab — replaces the legacy
/// `GroupHomeView` body composed of typed cards (purpose / rules /
/// resources / sanctions / money) with a data-driven feed of life-state
/// clusters per `doctrine_group_space_situational`.
///
/// Cluster order is canonical and fixed; each cluster is invisible
/// when empty. Full grammar per doctrine (A.1):
///
///     1. Necesita atención  (decisions sin tu voto, sanciones que te
///        afectan, pending join requests)
///     2. Próximo            (decisions que cierran pronto)
///     3. Deudas             (obligations vivas del caller — pago directo)
///     4. Dinero reciente    (últimos N money_movements del grupo)
///     5. En uso             (recursos con actividad reciente)
///     6. Acabó de pasar     (system_events recientes del grupo)
///
/// Foundation status stays at the very top while the group isn't ready
/// — admins/founders need a single tap into the missing primitive.
/// Engine banner (V2-G8.1) flota entre foundation y atención cuando
/// hubo evaluaciones en las últimas 24h.
struct GroupHomeFeedView: View {
    let container: DependencyContainer
    let group: GroupListItem

    // MARK: - Sheet + push state

    @State private var isShowingSettlementSheet = false
    @State private var isShowingInviteSheet = false
    @State private var pendingMemberSelection: MembershipBoundaryItem?
    /// Drives the push from any cluster row that targets a decision
    /// (attention.decisionNeedsVote + upcoming.decisionClosing).
    @State private var pendingDecisionDetail: GroupDecisionSummary?
    /// Drives the push from attention.sanctionOnMe.
    @State private var pendingSanctionDetail: GroupSanction?
    /// V2-G8.1 — drives the push from the engine banner into the
    /// Disparos feed.
    @State private var pushEngineEvaluations = false
    /// V2-G8.2 — drives the "¿Por qué pasó esto?" sheet from history rows.
    @State private var pendingWhyEvent: GroupEvent?
    /// A.1 — Dinero reciente cluster tap → MoneyMovementDetailView.
    @State private var pendingMovementDetail: MoneyMovement?
    /// A.1 — En uso cluster tap → ResourceDetailView (resuelto desde
    /// `resourcesStore.resources` por id).
    @State private var pendingResourceDetail: GroupResource?

    var body: some View {
        List {
            foundationSection
            engineBannerSection
            attentionSection
            upcomingSection
            debtsSection
            moneyRecentSection
            inUseSection
            recentlyHappenedSection
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { emptyOverlay }
        // A.2 — smooth cluster appearance/disappearance instead of
        // hard jumps when refresh hydrates a previously-empty cluster.
        .animation(.smooth, value: attentionItems.count)
        .animation(.smooth, value: upcomingItems.count)
        .animation(.smooth, value: debtItems.count)
        .animation(.smooth, value: recentMovements.count)
        .animation(.smooth, value: inUseRows.count)
        .animation(.smooth, value: recentEvents.count)
        .navigationDestination(item: $pendingMemberSelection) { item in
            MemberDetailView(
                sanctionsStore: container.sanctionsStore,
                reputationStore: container.reputationStore,
                moneyStore: container.moneyStore,
                rolesStore: container.rolesStore,
                membersStore: container.membersStore,
                groupId: group.id,
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
        .navigationDestination(item: $pendingDecisionDetail) { summary in
            DecisionDetailView(
                store: container.decisionsStore,
                groupId: group.id,
                decisionId: summary.id,
                initial: summary,
                onSelectReference: { link in
                    container.deepLinkRouter.apply(link)
                }
            )
        }
        .navigationDestination(item: $pendingSanctionDetail) { sanction in
            SanctionDetailView(
                container: container,
                groupId: group.id,
                myMembershipId: group.membershipId,
                sanction: sanction
            )
        }
        .navigationDestination(for: GroupHistoryDestination.self) { _ in
            GroupHistoryView(
                store: container.eventsStore,
                groupId: group.id,
                onSelectEvent: { event in
                    if let link = HistoryEventRouting.deepLink(for: event, groupId: group.id) {
                        container.deepLinkRouter.apply(link)
                    }
                },
                onAskWhyDidThisHappen: { event in
                    pendingWhyEvent = event
                }
            )
        }
        .sheet(item: $pendingWhyEvent) { event in
            WhyDidThisHappenSheet(container: container, event: event)
        }
        .navigationDestination(item: $pendingMovementDetail) { movement in
            MoneyMovementDetailView(
                movement: movement,
                myMembershipId: group.membershipId,
                mandatesStore: container.mandatesStore,
                onSelectMember: { membershipId in
                    if let item = container.membersStore.items.first(where: {
                        $0.membershipId == membershipId
                    }) {
                        pendingMemberSelection = item
                    }
                }
            )
        }
        .navigationDestination(item: $pendingResourceDetail) { resource in
            ResourceDetailView(
                store: container.resourcesStore,
                membersStore: container.membersStore,
                groupId: group.id,
                resource: resource,
                permissionsFetcher: { gid in
                    try await container.groupRepository.listMemberPermissions(
                        groupId: gid,
                        userId: nil
                    )
                }
            )
        }
        .navigationDestination(isPresented: $pushEngineEvaluations) {
            RuleEvaluationsView(
                store: container.ruleEvaluationsStore,
                groupId: group.id
            )
        }
        .refreshable { await refresh() }
        .task { await refresh() }
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
        // Foundation tap sheets — flipped on by `handleFoundationTap`
        // via the corresponding store's `beginEditing` / `beginCreating`
        // flag. Each sheet is the same one mounted by "El grupo" so
        // the user can resolve a foundation gap without switching tabs.
        .sheet(isPresented: purposeSheetBinding) {
            EditPurposeView(store: container.purposeStore, groupId: group.id)
        }
        .sheet(isPresented: rulesCreateSheetBinding) {
            EditRuleView(store: container.rulesStore, groupId: group.id)
        }
        .sheet(isPresented: resourcesCreateSheetBinding) {
            CreateResourceView(store: container.resourcesStore, groupId: group.id)
        }
    }

    // MARK: - Foundation-tap sheet bindings

    private var purposeSheetBinding: Binding<Bool> {
        Binding(
            get: { container.purposeStore.isEditPresented },
            set: { container.purposeStore.isEditPresented = $0 }
        )
    }

    private var rulesCreateSheetBinding: Binding<Bool> {
        Binding(
            get: { container.rulesStore.isCreatePresented },
            set: { container.rulesStore.isCreatePresented = $0 }
        )
    }

    private var resourcesCreateSheetBinding: Binding<Bool> {
        Binding(
            get: { container.resourcesStore.isCreatePresented },
            set: { container.resourcesStore.isCreatePresented = $0 }
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

    // MARK: - Engine banner (V2-G8.1)

    /// Doctrina situational: invisible si `summary.evaluationsCount == 0`.
    /// Tap → push a `RuleEvaluationsView` (Disparos feed) para
    /// transparencia "qué hizo el sistema en las últimas 24h".
    @ViewBuilder
    private var engineBannerSection: some View {
        if let summary = container.ruleEvaluationsStore.summary,
           summary.evaluationsCount > 0 {
            Section {
                Button {
                    pushEngineEvaluations = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: summary.hasFailures ? "exclamationmark.octagon" : "bolt.horizontal.circle.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(summary.hasFailures ? .red : .accentColor)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engineBannerHeadline(summary))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            if let detail = engineBannerDetail(summary) {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
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
        }
    }

    private func engineBannerHeadline(_ summary: GroupRuleEvaluationSummary) -> String {
        let count = summary.evaluationsCount
        let noun = count == 1 ? "regla" : "reglas"
        let hoursLabel: String
        if summary.windowHours == 24 {
            hoursLabel = "24h"
        } else if summary.windowHours % 24 == 0 {
            hoursLabel = "\(summary.windowHours / 24)d"
        } else {
            hoursLabel = "\(summary.windowHours)h"
        }
        return "Sistema evaluó \(count) \(noun) en las últimas \(hoursLabel)"
    }

    private func engineBannerDetail(_ summary: GroupRuleEvaluationSummary) -> String? {
        if summary.hasFailures {
            return "Una acción del engine falló. Tocá para ver el detalle."
        }
        return "Tocá para ver disparos"
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

        // D.24.3: pending join requests + their voting state.
        // - No open vote linked → `.pendingRequest` (admin-actionable).
        // - Linked `decision.membership_accept` open → fall through to
        //   the standard `.decisionNeedsVote` path so the user sees
        //   "Falta tu voto: Aceptar nuevo miembro" instead of the
        //   admin-only request prompt. Avoids double-rendering the same
        //   request twice as both a pending action and an open vote.
        var requestsInVote: Set<UUID> = []
        for decision in container.decisionsStore.open
        where decision.referenceKind == "membership" {
            if let referenceId = decision.referenceId {
                requestsInVote.insert(referenceId)
            }
        }

        for member in container.membersStore.items
        where member.kind == .membership && member.status == .requested {
            // If this request already has an open vote, skip — it'll
            // surface via `.decisionNeedsVote` below with the proper
            // "Falta tu voto" treatment.
            if let mid = member.membershipId, requestsInVote.contains(mid) {
                continue
            }
            result.append(.pendingRequest(member))
        }

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
                    UpcomingRow(item: item, onSelect: handleUpcomingTap)
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

    // MARK: - Deudas

    /// Per doctrine_group_space_situational: viewer-involved dyadic
    /// settlement pairs. At Foundation level we use the caller's open
    /// obligations directly (each row is a real amount they owe to
    /// either the pool or a specific member). Tap → opens the
    /// settlement sheet so they can resolve it on the spot.
    @ViewBuilder
    private var debtsSection: some View {
        let items = debtItems
        if !items.isEmpty {
            Section("Deudas") {
                ForEach(items) { obligation in
                    DebtRow(obligation: obligation) {
                        isShowingSettlementSheet = true
                    }
                }
            }
        }
    }

    private var debtItems: [ObligationSummary] {
        container.moneyStore.obligations
            .filter { $0.amountOutstanding > 0 }
            .sorted { $0.amountOutstanding > $1.amountOutstanding }
    }

    // MARK: - Dinero reciente

    /// A.1 — últimos N movimientos del grupo (cualquier participante),
    /// para que cada miembro vea el pulso económico al abrir Home.
    /// Tap → MoneyMovementDetailView via navigation destination.
    @ViewBuilder
    private var moneyRecentSection: some View {
        let items = recentMovements
        if !items.isEmpty {
            Section("Dinero reciente") {
                ForEach(items) { movement in
                    MoneyRecentRow(movement: movement) {
                        pendingMovementDetail = movement
                    }
                }
            }
        }
    }

    private var recentMovements: [MoneyMovement] {
        Array(container.movementsStore.movements.prefix(3))
    }

    // MARK: - En uso

    /// A.1 — recursos con actividad reciente (últimas ~2 semanas)
    /// extraído de `group_events` filtrado a `entity_kind='resource'`.
    /// Dedup por resource id (último evento gana). Tap → ResourceDetailView
    /// resolviendo el recurso desde resourcesStore. Cluster invisible
    /// si no hay actividad.
    @ViewBuilder
    private var inUseSection: some View {
        let items = inUseRows
        if !items.isEmpty {
            Section("En uso") {
                ForEach(items) { row in
                    InUseRow(row: row) {
                        if let resource = container.resourcesStore.resources.first(
                            where: { $0.id == row.resourceId }
                        ) {
                            pendingResourceDetail = resource
                        }
                    }
                }
            }
        }
    }

    private var inUseRows: [InUseRowData] {
        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        var seen: Set<UUID> = []
        var rows: [InUseRowData] = []
        for event in container.eventsStore.events {
            guard event.entityKind == "resource",
                  let resourceId = event.entityId,
                  let occurredAt = event.occurredAt,
                  occurredAt > cutoff else { continue }
            if seen.contains(resourceId) { continue }
            seen.insert(resourceId)
            let resourceName = container.resourcesStore.resources
                .first(where: { $0.id == resourceId })?.name
                ?? event.summary
                ?? "Recurso"
            rows.append(InUseRowData(
                id: event.id,
                resourceId: resourceId,
                resourceName: resourceName,
                eventType: event.eventType,
                occurredAt: occurredAt
            ))
            if rows.count >= 5 { break }
        }
        return rows
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

    // MARK: - Empty overlay (presence + invite CTA when literally nothing has happened yet)

    @ViewBuilder
    private var emptyOverlay: some View {
        // Show ONLY when:
        // (1) Foundation has loaded and is ready (so we're past first-setup), AND
        // (2) every cluster collapses to zero items.
        let isReady = container.foundationStatusStore.status?.isReady ?? false
        let attentionEmpty = attentionItems.isEmpty
        let upcomingEmpty = upcomingItems.isEmpty
        let debtsEmpty = debtItems.isEmpty
        let recentEmpty = recentEvents.isEmpty
        let moneyRecentEmpty = recentMovements.isEmpty
        let inUseEmpty = inUseRows.isEmpty
        if isReady, attentionEmpty, upcomingEmpty, debtsEmpty,
           moneyRecentEmpty, inUseEmpty, recentEmpty {
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
        case .decisionNeedsVote(let summary):
            pendingDecisionDetail = summary
        case .sanctionOnMe(let sanction):
            pendingSanctionDetail = sanction
        case .pendingRequest(let member):
            pendingMemberSelection = member
        }
    }

    private func handleUpcomingTap(_ item: UpcomingItem) {
        switch item {
        case .decisionClosing(let summary):
            pendingDecisionDetail = summary
        }
    }

    // MARK: - Refresh

    private func refresh() async {
        // Hydrate every store the feed reads from. The foundation
        // store is critical (drives the empty-overlay decision).
        await container.foundationStatusStore.refresh(groupId: group.id)
        await container.currentGroupStore.refresh()
        await container.moneyStore.refresh(groupId: group.id, membershipId: group.membershipId)
        await container.decisionsStore.refresh(groupId: group.id)
        await container.sanctionsStore.refresh(groupId: group.id)
        await container.eventsStore.refresh(groupId: group.id)
        // D.24.1: keep `requested` memberships hydrated so the
        // attention cluster can surface pending join requests.
        await container.membersStore.refresh(groupId: group.id)
        // V2-G8.1: cheap aggregate, drives the engine banner.
        await container.ruleEvaluationsStore.refreshSummary(groupId: group.id)
        // A.1: Dinero reciente + En uso fuentes.
        await container.movementsStore.refresh(groupId: group.id)
        await container.resourcesStore.refresh(groupId: group.id)
    }

    // MARK: - Cluster item enums

    enum AttentionItem: Identifiable, Hashable {
        case decisionNeedsVote(GroupDecisionSummary)
        case sanctionOnMe(GroupSanction)
        /// D.24.1 — pending join request awaiting admin/group action.
        /// Tap pushes the requester's MemberDetailView; the inline
        /// Aprobar/Rechazar pills in MembersListView remain the
        /// primary action surface.
        case pendingRequest(MembershipBoundaryItem)

        var id: String {
            switch self {
            case .decisionNeedsVote(let d): return "decision:\(d.id.uuidString)"
            case .sanctionOnMe(let s):      return "sanction:\(s.id.uuidString)"
            case .pendingRequest(let m):    return "request:\(m.id.uuidString)"
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

    /// A.1 — denormalized "En uso" row: one per resource with recent
    /// activity, pre-resolved name + last event_type + timestamp for
    /// compact display.
    struct InUseRowData: Identifiable, Hashable {
        let id: UUID            // last event id
        let resourceId: UUID
        let resourceName: String
        let eventType: String
        let occurredAt: Date
    }

    // MARK: - Navigation tokens

    private struct GroupHistoryDestination: Hashable {}
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
        case .pendingRequest:     return "person.crop.circle.badge.questionmark"
        }
    }

    private var headline: String {
        switch item {
        case .decisionNeedsVote(let d):
            return "Falta tu voto: \(d.title)"
        case .sanctionOnMe(let s):
            return "Sanción para ti: \(s.reason)"
        case .pendingRequest(let m):
            return "\(m.displayName) quiere entrar"
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
        case .pendingRequest:
            return "Tap para revisar la solicitud"
        }
    }
}

private struct UpcomingRow: View {
    let item: GroupHomeFeedView.UpcomingItem
    let onSelect: (GroupHomeFeedView.UpcomingItem) -> Void

    var body: some View {
        Button {
            onSelect(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

private struct DebtRow: View {
    let obligation: ObligationSummary
    let onSettle: () -> Void

    var body: some View {
        Button(action: onSettle) {
            HStack(spacing: 12) {
                Image(systemName: "creditcard")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(obligation.amountOutstanding.formatted()) MXN")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Names the counterparty per `doctrine_money_two_worlds`: every
    /// money string must say WHO. "Págale a Linda" beats "Le debes".
    private var headline: String {
        switch obligation.owedToKind {
        case "pool":
            return "Págale al grupo"
        default:
            return "Págale a \(obligation.owedToLabel)"
        }
    }
}

// MARK: - A.1 cluster rows (Dinero reciente + En uso)

private struct MoneyRecentRow: View {
    let movement: MoneyMovement
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(amountString)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let when = movement.when {
                    Text(when.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var amountString: String {
        "\(movement.amount.formatted()) \(movement.unit)"
    }

    private var icon: String {
        switch movement.type {
        case .expense:           return "arrow.up.right.circle"
        case .settlementPayment: return "checkmark.circle"
        case .finePayment:       return "checkmark.shield"
        case .contribution:      return "arrow.down.to.line.circle"
        case .poolCharge:        return "creditcard"
        case .bookingCharge:     return "calendar.badge.clock"
        case .payout:            return "arrow.up.forward.circle"
        case .reversal:          return "arrow.uturn.backward.circle"
        case .income, .transfer, .refund, .adjustment, .allocation, .other:
            return "circle"
        }
    }

    private var tint: Color {
        switch movement.type {
        case .expense:           return .accentColor
        case .settlementPayment: return .green
        case .finePayment:       return .green
        case .contribution:      return .green
        case .poolCharge:        return .orange
        case .bookingCharge:     return .orange
        case .payout:            return .blue
        case .reversal:          return .red
        case .income, .transfer, .refund, .adjustment, .allocation, .other:
            return .secondary
        }
    }

    /// Per doctrine_money_two_worlds: "money strings say WHO".
    private var headline: String {
        let who = movement.paidByDisplayName
            ?? movement.fromDisplayName
            ?? movement.recordedByDisplayName
            ?? "Alguien"
        switch movement.type {
        case .expense:           return "\(who) registró un gasto"
        case .settlementPayment: return "\(who) pagó"
        case .finePayment:       return "\(who) pagó una multa"
        case .contribution:      return "\(who) aportó"
        case .poolCharge:        return "Cuota a \(movement.toDisplayName ?? "miembro")"
        case .bookingCharge:     return "Cargo por reserva"
        case .payout:            return "Payout a \(movement.toDisplayName ?? "miembro")"
        case .reversal:          return "Reversión"
        case .income, .transfer, .refund, .adjustment, .allocation, .other:
            return movement.description ?? "Movimiento"
        }
    }
}

private struct InUseRow: View {
    let row: GroupHomeFeedView.InUseRowData
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.resourceName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(row.occurredAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var icon: String {
        // Heuristic by event verb. Falls back to generic resource icon.
        if row.eventType.contains("book")        { return "calendar.badge.clock" }
        if row.eventType.contains("slot")        { return "person.crop.square.badge.video" }
        if row.eventType.contains("lock")        { return "lock" }
        if row.eventType.contains("custodian")   { return "person.crop.circle.badge.checkmark" }
        if row.eventType.contains("right")       { return "key" }
        if row.eventType.contains("condition")   { return "exclamationmark.triangle" }
        if row.eventType.contains("valuation")   { return "scalemass" }
        return "square.stack.3d.up"
    }

    private var detail: String {
        // Humanize the event_type for the secondary line.
        switch row.eventType {
        case let t where t.contains("booked"):     return "Reservado"
        case let t where t.contains("assigned"):   return "Asignado"
        case let t where t.contains("locked"):     return "Bloqueado"
        case let t where t.contains("released"):   return "Liberado"
        case let t where t.contains("granted"):    return "Derecho otorgado"
        case let t where t.contains("transferred"): return "Transferido"
        case let t where t.contains("valuation"):  return "Valuación actualizada"
        case let t where t.contains("condition"):  return "Condición actualizada"
        case let t where t.contains("created"):    return "Creado"
        case let t where t.contains("updated"):    return "Editado"
        default: return row.eventType.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
