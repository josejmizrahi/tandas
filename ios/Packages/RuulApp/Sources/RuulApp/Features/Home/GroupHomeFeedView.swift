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

    var body: some View {
        List {
            foundationSection
            engineBannerSection
            attentionSection
            upcomingSection
            debtsSection
            recentlyHappenedSection
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

    // MARK: - En uso

    // Currently invisible — Foundation has no checkout/booking
    // infrastructure (assets in custody, spaces occupied). Once those
    // ship the cluster wires here against a polymorphic
    // `[InUseProjection]` source per doctrine §"Implementation status".

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
        if isReady, attentionEmpty, upcomingEmpty, debtsEmpty, recentEmpty {
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
        // V2-G8.1: cheap aggregate, drives the engine banner.
        await container.ruleEvaluationsStore.refreshSummary(groupId: group.id)
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
        }
    }

    private var headline: String {
        switch item {
        case .decisionNeedsVote(let d):
            return "Falta tu voto: \(d.title)"
        case .sanctionOnMe(let s):
            return "Sanción para ti: \(s.reason)"
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
