import SwiftUI
import RuulUI
import RuulCore

/// Group "space" — the persistent home for a community.
///
/// V2 (2026-05-25): rebuild from scratch. The page is a vertical
/// situational stream made of self-contained sections, each one
/// responsible for ONE element of the group's life:
///
///   1. `GroupPresenceHeader`   — identity + members avatar band
///   2. `GroupPoolStatusBlock`  — shared money pool state + viewer
///                                 obligation chip (when relevant)
///   3. `GroupClusterStream`    — 5 situational clusters in fixed order
///                                 (Necesita atención / Próximo / Dinero
///                                 reciente / En uso / Acabó de pasar)
///   4. `EmptyGroupHero`        — only when truly empty across all signals
///
/// Each section auto-hides when its data source is empty (doctrine
/// `group_space_situational`: data-driven, empty cluster invisible).
/// The view itself is a thin shell over `GroupHomeCoordinator` — no
/// data shaping happens here; the coordinator already exposes the
/// `Observable` projections each section needs.
///
/// Composable concerns kept OUT of this file:
///   - Per-cluster row rendering         → `Group/Components/*Cluster.swift`
///   - Presence avatar stack             → `GroupPresenceHeader.swift`
///   - Money sheet flows (record / aportar / settle) → presented from
///     the same `sharedMoneySheet` enum; the sheet content itself lives
///     in `Group/Sheets/*` and `Resources/Detail/Sections/SettlementSheet`
///   - Toolbar menu items                → built inline at the bottom
@MainActor
public struct GroupSpaceView: View {
    @State var coordinator: GroupHomeCoordinator
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// El `+` de "Dinero reciente" + el PoolStatusBlock saltan directo
    /// al sheet correspondiente — sin pasar por un picker intermedio
    /// (founder decision 2026-05-25).
    private enum SharedMoneySheet: Identifiable {
        case contribute, recordExpense, settle, payout, poolCharge, vendorPayment
        var id: Self { self }
    }
    @State private var sharedMoneySheet: SharedMoneySheet?
    /// FASE 4 Wave 3 (2026-05-25): pre-filled settlement sheet driven
    /// by the pending-settlement strip inside the money cluster. Keeps
    /// the bare `sharedMoneySheet = .settle` path intact for the
    /// PoolStatusBlock + cluster menu CTAs.
    @State private var prefilledSettlement: PrefilledSettlement?
    private struct PrefilledSettlement: Identifiable {
        let id = UUID()
        let toMemberId: UUID
        let amountCents: Int64
    }
    /// 2026-05-25 proposal B: tap an avatar → MemberQuickSheet.
    /// Contextual participation FIRST, full identity SECOND.
    @State private var quickSheetMember: MemberWithProfile?
    /// Sibling of `quickSheetMember`: "Ver perfil completo" from
    /// MemberQuickSheet dismisses the quick sheet and pushes this
    /// state — fullScreenCover then mounts MemberDetailView for the
    /// specific member. Sequential dismissal pattern avoids
    /// sheet-on-sheet violations per `ruul_sheet_on_sheet_doctrine`
    /// (substantial sub-screen = cover, not nested sheet).
    @State private var memberDetailMember: MemberWithProfile?

    // Compose chips (toolbar "+")
    public var onCreateEvent: () -> Void
    public var onStartVote: () -> Void
    public var onInviteMembers: () -> Void
    public var onShareInvite: () -> Void

    // Cluster row routing
    public var onOpenEvent: (Event) -> Void
    public var onOpenVote: (Vote) -> Void
    public var onOpenSlot: (Slot) -> Void
    public var onSelectPending: (UserAction) -> Void
    public var onOpenInUseResource: (UUID) -> Void

    // Header + stream secondary destinations
    public var onOpenMembers: (() -> Void)?
    public var onOpenActivity: (() -> Void)?
    public var onOpenTransactions: (() -> Void)?
    public var onOpenEventsHistory: (() -> Void)?

    // Toolbar ⋯ menu
    public var onOpenAjustes: (() -> Void)?
    public var onConfirmLeave: (() -> Void)?
    public var onLeaveGroup: () -> Void

    public init(
        coordinator: GroupHomeCoordinator,
        onCreateEvent: @escaping () -> Void,
        onStartVote: @escaping () -> Void,
        onInviteMembers: @escaping () -> Void,
        onShareInvite: @escaping () -> Void,
        onOpenEvent: @escaping (Event) -> Void,
        onOpenVote: @escaping (Vote) -> Void = { _ in },
        onOpenSlot: @escaping (Slot) -> Void = { _ in },
        onSelectPending: @escaping (UserAction) -> Void,
        onOpenInUseResource: @escaping (UUID) -> Void = { _ in },
        onOpenMembers: (() -> Void)? = nil,
        onOpenActivity: (() -> Void)? = nil,
        onOpenTransactions: (() -> Void)? = nil,
        onOpenEventsHistory: (() -> Void)? = nil,
        onOpenAjustes: (() -> Void)? = nil,
        onConfirmLeave: (() -> Void)? = nil,
        onLeaveGroup: @escaping () -> Void
    ) {
        self._coordinator = State(initialValue: coordinator)
        self.onCreateEvent = onCreateEvent
        self.onStartVote = onStartVote
        self.onInviteMembers = onInviteMembers
        self.onShareInvite = onShareInvite
        self.onOpenEvent = onOpenEvent
        self.onOpenVote = onOpenVote
        self.onOpenSlot = onOpenSlot
        self.onSelectPending = onSelectPending
        self.onOpenInUseResource = onOpenInUseResource
        self.onOpenMembers = onOpenMembers
        self.onOpenActivity = onOpenActivity
        self.onOpenTransactions = onOpenTransactions
        self.onOpenEventsHistory = onOpenEventsHistory
        self.onOpenAjustes = onOpenAjustes
        self.onConfirmLeave = onConfirmLeave
        self.onLeaveGroup = onLeaveGroup
    }

    public var body: some View {
        ZStack {
            Color.ruulBackgroundRecessed.ignoresSafeArea()
            if coordinator.phase.isInitialLoading {
                GroupSpaceSkeleton()
                    .transition(.opacity)
            } else {
                AsyncContentView(
                    phase: coordinator.phase,
                    onRetry: { await coordinator.refresh() },
                    loaded: { _ in loadedContent }
                )
                .transition(.opacity)
            }
        }
        .animation(.smooth, value: coordinator.phase.isInitialLoading)
        .task { await coordinator.refresh() }
        .toolbar { toolbarContent }
    }

    // MARK: - Loaded content

    @ViewBuilder
    private var loadedContent: some View {
        if let group = coordinator.group {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RuulSpacing.xl) {
                    GroupPresenceHeader(
                        group: group,
                        memberCount: coordinator.memberCount,
                        members: coordinator.members,
                        onTapMembers: onOpenMembers,
                        onTapMember: { quickSheetMember = $0 }
                    )

                    GroupPulseLine(
                        pendingCount: coordinator.pendingActions.count,
                        nextEvent: coordinator.upcomingEvents.first,
                        hasPoolContent: hasPoolContent,
                        hasStreamContent: hasStreamContent
                    )

                    if let pool = coordinator.sharedPoolSummary, shouldShowPool(pool) {
                        GroupPoolStatusBlock(
                            pool: pool,
                            viewerBalance: coordinator.viewerBalance,
                            viewerObligation: coordinator.viewerObligation,
                            members: coordinator.allMembers,
                            onTapPool: onOpenTransactions,
                            onContribute: { sharedMoneySheet = .contribute },
                            onRegisterExpense: { sharedMoneySheet = .recordExpense },
                            onSettle: { sharedMoneySheet = .settle }
                        )
                    }

                    if hasStreamContent {
                        GroupClusterStream(
                            attention: coordinator.pendingActions,
                            upcoming: coordinator.upcomingItems,
                            // FASE 4 Wave 4 Phase 3 (mig 20260525230000):
                            // re-activado con `member_obligations_view`
                            // que separa stake de deuda peer-to-peer
                            // real. El greedy ahora corre sobre
                            // `netPeerPositionCents` (excluye aportes)
                            // → settlements correctos.
                            pendingDebts: viewerPendingDebts(group: group),
                            inUse: coordinator.inUseItems,
                            recentActivity: coordinator.groupActivityEvents,
                            locale: app.profile?.locale ?? "es-MX",
                            members: coordinator.allMembers,
                            currency: group.currency,
                            onSelectPending: onSelectPending,
                            onOpenEvent: onOpenEvent,
                            onOpenVote: onOpenVote,
                            onOpenSlot: onOpenSlot,
                            onOpenInUseResource: onOpenInUseResource,
                            onSeeAllActivity: onOpenActivity,
                            onSeeAllMoney: onOpenTransactions,
                            onSeeAllUpcoming: onOpenEventsHistory,
                            onRegisterExpense: { sharedMoneySheet = .recordExpense },
                            onContribute: { sharedMoneySheet = .contribute },
                            onSettle: { sharedMoneySheet = .settle },
                            onPayout: { sharedMoneySheet = .payout },
                            onPoolCharge: { sharedMoneySheet = .poolCharge },
                            onVendorPayment: { sharedMoneySheet = .vendorPayment },
                            onTapDebt: { hint in
                                prefilledSettlement = PrefilledSettlement(
                                    toMemberId: hint.toMemberId,
                                    amountCents: hint.amountCents
                                )
                            }
                        )
                    } else if !hasPoolContent {
                        EmptyGroupHero(
                            onInvite: onInviteMembers,
                            onCreate: onCreateEvent
                        )
                    }
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.bottom, RuulSpacing.xl)
            }
            .scrollIndicators(.hidden)
            .refreshable { await coordinator.refresh() }
            .sheet(item: $sharedMoneySheet) { which in
                sharedMoneySheetContent(which, group: group)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $prefilledSettlement) { ctx in
                SettlementSheet(
                    groupId: group.id,
                    resourceId: nil,
                    currency: group.currency,
                    members: coordinator.allMembers,
                    suggestedToMemberId: ctx.toMemberId,
                    suggestedAmountCents: ctx.amountCents,
                    onDidSettle: { Task { await coordinator.refresh() } }
                )
                .environment(app)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(item: $quickSheetMember) { member in
                MemberQuickSheet(
                    member: member,
                    groupId: group.id,
                    groupCurrency: group.currency,
                    memberBalance: coordinator.groupBalances.first(where: {
                        $0.memberId == member.member.id && $0.currency == group.currency
                    }),
                    onLiquidar: nil,
                    onOpenProfile: {
                        // Sequential dismissal: capture the member,
                        // close the quick sheet, then present the full
                        // MemberDetailView via fullScreenCover. The
                        // 0.35s delay lets the sheet animation finish
                        // before the cover lands — SwiftUI rejects
                        // simultaneous sheet+cover presentations.
                        let captured = member
                        quickSheetMember = nil
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            memberDetailMember = captured
                        }
                    }
                )
                .environment(app)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
            }
            .fullScreenCover(item: $memberDetailMember) { member in
                NavigationStack {
                    MemberDetailView(
                        memberWithProfile: member,
                        group: group,
                        isCurrentUser: member.member.userId == app.session?.user.id,
                        canManageRoles: coordinator.isCurrentUserAdmin,
                        founderCount: coordinator.allMembers.filter {
                            $0.member.roles.contains(.founder)
                        }.count,
                        adminCount: coordinator.allMembers.filter {
                            $0.member.roles.contains(.admin)
                        }.count,
                        onMemberChanged: { await coordinator.refresh() }
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Listo") { memberDetailMember = nil }
                        }
                    }
                }
                .environment(app)
            }
        }
    }

    // MARK: - Visibility predicates

    /// Pool block appears when there's something worth saying about the
    /// group's money — balance non-zero, viewer carrying an obligation,
    /// or at least one ledger entry recorded. A fresh empty pool stays
    /// hidden so the empty group doesn't feel "bancario" out of the gate.
    private func shouldShowPool(_ pool: SharedPoolSummary) -> Bool {
        pool.hasActivity || pool.balanceCents != 0 || (coordinator.viewerBalance?.netCents ?? 0) != 0
    }

    private var hasStreamContent: Bool {
        !coordinator.pendingActions.isEmpty
            || !coordinator.upcomingItems.isEmpty
            || !coordinator.inUseItems.isEmpty
            || !coordinator.groupActivityEvents.isEmpty
            || (coordinator.group.map { !viewerPendingDebts(group: $0).isEmpty } ?? false)
    }

    /// FASE 4 Wave 4 Phase 3 (mig 20260525230000): peer-settlement
    /// greedy ahora corre sobre `member_obligations_view.netPeerPositionCents`
    /// que EXCLUYE aportes/stake. Resultado: settlements sugeridos
    /// reflejan deuda real entre miembros (fronteos sin cobrar, multas
    /// pendientes, peer settlements), NO el stake invertido.
    ///
    /// Doctrine recordatoria: el viewer solo ve pairs en los que está
    /// involucrado (founder doctrine 2026-05-25). Third-party pairs
    /// viven en `GroupSettlementPlanView` con su toggle.
    private func viewerPendingDebts(group: RuulCore.Group) -> [PendingSettlementHint] {
        guard let userId = app.session?.user.id else { return [] }
        guard let myMemberId = coordinator.allMembers
            .first(where: { $0.member.userId == userId })?.member.id else { return [] }
        let obligations = coordinator.groupObligations
            .filter { $0.currency == group.currency }
        guard obligations.contains(where: {
            $0.memberId == myMemberId && $0.netPeerPositionCents != 0
        }) else {
            return []
        }
        var creditors = obligations.filter { $0.netPeerPositionCents > 0 }
            .sorted { $0.netPeerPositionCents > $1.netPeerPositionCents }
            .map { (memberId: $0.memberId, net: $0.netPeerPositionCents) }
        var debtors = obligations.filter { $0.netPeerPositionCents < 0 }
            .sorted { $0.netPeerPositionCents < $1.netPeerPositionCents }
            .map { (memberId: $0.memberId, net: $0.netPeerPositionCents) }
        var out: [PendingSettlementHint] = []
        while !creditors.isEmpty, !debtors.isEmpty {
            var c = creditors.removeFirst()
            var d = debtors.removeFirst()
            let amount = min(c.net, -d.net)
            guard amount > 0 else { break }
            let viewerIsPayer = (d.memberId == myMemberId)
            let viewerIsCreditor = (c.memberId == myMemberId)
            if viewerIsPayer || viewerIsCreditor {
                let counterpartId = viewerIsPayer ? c.memberId : d.memberId
                let name = coordinator.allMembers
                    .first(where: { $0.member.id == counterpartId })?
                    .displayName ?? "Miembro"
                out.append(PendingSettlementHint(
                    toMemberId: counterpartId,
                    counterpartName: name,
                    amountCents: amount,
                    currency: group.currency,
                    viewerIsPayer: viewerIsPayer
                ))
            }
            c.net -= amount
            d.net += amount
            if c.net > 0 { creditors.insert(c, at: 0) }
            if d.net < 0 { debtors.insert(d, at: 0) }
        }
        return out
    }

    private var hasPoolContent: Bool {
        guard let pool = coordinator.sharedPoolSummary else { return false }
        return shouldShowPool(pool)
    }

    // MARK: - Sheet routing

    @ViewBuilder
    private func sharedMoneySheetContent(
        _ which: SharedMoneySheet,
        group: RuulCore.Group
    ) -> some View {
        switch which {
        case .contribute:
            ContributeToSharedMoneySheet(
                groupId: group.id,
                currency: group.currency,
                onDidContribute: { Task { await coordinator.refresh() } }
            )
        case .recordExpense:
            RecordSharedExpenseSheet(
                groupId: group.id,
                currency: group.currency,
                members: coordinator.allMembers,
                onDidRecord: { Task { await coordinator.refresh() } }
            )
        case .settle:
            SettlementSheet(
                groupId: group.id,
                resourceId: nil,
                currency: group.currency,
                members: coordinator.allMembers,
                suggestedToMemberId: nil,
                onDidSettle: { Task { await coordinator.refresh() } }
            )
        case .payout:
            RecordPayoutSheet(
                groupId: group.id,
                currency: group.currency,
                members: coordinator.allMembers,
                suggestedMemberId: nil,
                onDidPayout: { Task { await coordinator.refresh() } }
            )
            .environment(app)
        case .poolCharge:
            IssuePoolChargeSheet(
                groupId: group.id,
                currency: group.currency,
                members: coordinator.allMembers,
                onDidIssue: { Task { await coordinator.refresh() } }
            )
            .environment(app)
        case .vendorPayment:
            RecordVendorPaymentSheet(
                groupId: group.id,
                currency: group.currency,
                onDidRecord: { Task { await coordinator.refresh() } }
            )
            .environment(app)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(
                    "Crear algo",
                    systemImage: "plus.circle",
                    action: onCreateEvent
                )
                Button(
                    "Iniciar votación",
                    systemImage: "checkmark.square",
                    action: onStartVote
                )
                Button(
                    "Invitar gente",
                    systemImage: "person.badge.plus",
                    action: onInviteMembers
                )
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Agregar al grupo")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(
                    "Compartir invitación",
                    systemImage: "square.and.arrow.up",
                    action: onShareInvite
                )
                if let onOpenActivity {
                    Button(
                        "Actividad del grupo",
                        systemImage: "clock.arrow.circlepath",
                        action: onOpenActivity
                    )
                }
                if let onOpenAjustes {
                    Button(
                        "Cómo nos organizamos",
                        systemImage: "gearshape",
                        action: onOpenAjustes
                    )
                }
                Divider()
                Button(
                    "Salir del grupo",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    role: .destructive,
                    action: { onConfirmLeave?() ?? onLeaveGroup() }
                )
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }
}

// MARK: - GroupPoolStatusBlock

/// Shared money pool surface for the home (FASE 4 M.2 fix).
///
/// Doctrine: the home doesn't show a Splitwise card. It shows ONE line
/// of "qué hay en el dinero compartido y qué tengo que ver yo con eso".
/// Tap → opens GroupBalancesView. Inline mini-actions (Aportar /
/// Gasto / Liquidar) keep the create flows reachable without
/// re-introducing the verb-grid that PR-1 deprecated.
///
/// Visibility: caller (`GroupSpaceView.shouldShowPool`) guards rendering
/// so a fresh empty pool stays hidden — the home doesn't feel bancario
/// when there's literally nothing to say.
@MainActor
private struct GroupPoolStatusBlock: View {
    let pool: SharedPoolSummary
    let viewerBalance: MemberGroupBalance?
    /// FASE 4 Wave 4 Phase 3 Tier 1: preferred over `viewerBalance` for
    /// obligation chip labels — `netPeerPositionCents` excludes stake.
    let viewerObligation: MemberObligationSummary?
    let members: [MemberWithProfile]
    var onTapPool: (() -> Void)?
    var onContribute: () -> Void
    var onRegisterExpense: () -> Void
    var onSettle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            poolRow
            viewerObligationChip
            quickActions
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ruulCardSurface(.solid)
    }

    // MARK: Pool row — balance + relative time

    private var poolRow: some View {
        Button(action: { onTapPool?() }) {
            HStack(alignment: .firstTextBaseline, spacing: RuulSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EFECTIVO DEL GRUPO")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.ruulTextSecondary)
                        .tracking(0.6)
                    Text(formattedBalance)
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(balanceTint)
                        .contentTransition(.numericText())
                    // FASE 4 Wave 4 (mig 20260525221500): in-kind
                    // contributions live separately from the cash
                    // balance. Surface them inline when present.
                    if pool.inKindCents > 0 {
                        Label(
                            "+ \(formatAmount(pool.inKindCents, currency: pool.currency)) en activos",
                            systemImage: "shippingbox"
                        )
                        .font(.caption2)
                        .foregroundStyle(Color.ruulTextSecondary)
                    }
                }
                Spacer()
                if let lastActivity = pool.lastActivityAt {
                    Text(lastActivity.ruulRelativeDescription)
                        .font(.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTapPool == nil)
    }

    private var formattedBalance: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = pool.currency
        f.locale = Locale(identifier: "es_MX")
        let decimal = Decimal(pool.balanceCents) / 100
        return f.string(from: decimal as NSDecimalNumber) ?? "\(pool.currency) \(pool.balanceCents / 100)"
    }

    private var balanceTint: Color {
        if pool.isOverSpent { return .ruulSemanticWarning }
        return .ruulTextPrimary
    }

    // MARK: Viewer obligation chip (FASE 4 D.1 — name + amount)

    @ViewBuilder
    private var viewerObligationChip: some View {
        // FASE 4 Wave 4 Phase 3 Tier 1 (mig 20260525230000): prefer
        // `viewerObligation.netPeerPositionCents` — separates stake
        // from peer-relevant debt so the chip can show BOTH directions
        // truthfully ("Te deben" cuando + / "Debes" cuando −). Falls
        // back to `viewerBalance.netCents > 0` only when obligations
        // haven't loaded (first paint) — keeps the post-aporte
        // "Le debes" bug from re-surfacing during the load gap.
        let netCents: Int64? = {
            if let o = viewerObligation { return o.netPeerPositionCents }
            if let b = viewerBalance, b.netCents > 0 { return b.netCents }
            return nil
        }()
        if let net = netCents, net != 0 {
            let isViewerCredited = net > 0
            let amountFormatted = formatAmount(
                abs(net),
                currency: viewerObligation?.currency
                    ?? viewerBalance?.currency
                    ?? pool.currency
            )
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: isViewerCredited
                      ? "arrow.down.left.circle.fill"
                      : "arrow.up.right.circle.fill")
                    .font(.body)
                    .foregroundStyle(isViewerCredited ? Color.ruulPositive : Color.ruulNegative)
                    .accessibilityHidden(true)
                Text(isViewerCredited
                     ? "El grupo te debe \(amountFormatted)"
                     : "Le debes \(amountFormatted) al grupo")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer()
                if !isViewerCredited {
                    Button("Liquidar", action: onSettle)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: Quick actions row

    private var quickActions: some View {
        HStack(spacing: RuulSpacing.xs) {
            Button(action: onContribute) {
                Label("Aportar", systemImage: "arrow.down.circle")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.regular)

            Button(action: onRegisterExpense) {
                Label("Gasto", systemImage: "arrow.up.circle")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.regular)

            // 2026-05-25: Liquidar removido del toolbar — vivía
            // duplicado con el `viewerObligationChip` contextual ("Le
            // debes $X · Liquidar") + las rows del `DebtsCluster` +
            // el bloque "Tu posición" del Money Detail. El toolbar
            // queda para acciones de creación (Aportar / Gasto);
            // settle es contextual y se ofrece donde hay deuda.
        }
    }

    private func formatAmount(_ cents: Int64, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.locale = Locale(identifier: "es_MX")
        let decimal = Decimal(cents) / 100
        return f.string(from: decimal as NSDecimalNumber) ?? "\(currency) \(cents / 100)"
    }
}

// MARK: - GroupPulseLine

/// Single-line situational summary between PresenceHeader and the
/// rest of the stream. Picks the highest-priority "what's true now"
/// signal to communicate the group's emotional state in one sentence.
///
/// Priority (first match wins):
///   1. Pending attention items → "Te toca atender N \(cosa | cosas)"
///   2. Imminent upcoming event (today/tomorrow) → "[título] es \(hoy|mañana)"
///   3. Group has any stream activity / pool — but nothing urgent → "Todo en orden"
///   4. Empty group → hidden (EmptyGroupHero handles invitation framing)
///
/// Design intent (`doctrine_group_space_situational`): data-driven,
/// auto-hides when there's nothing to say. The line is a *summary*,
/// not a redundant restatement of the clusters below — it's the
/// single thing a returning user wants to see before scrolling.
@MainActor
private struct GroupPulseLine: View {
    let pendingCount: Int
    let nextEvent: Event?
    let hasPoolContent: Bool
    let hasStreamContent: Bool

    var body: some View {
        if let line = composeLine() {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: line.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(line.tint)
                    .accessibilityHidden(true)
                Text(line.text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ruulCardSurface(.solid)
        }
    }

    private struct Line {
        let icon: String
        let tint: Color
        let text: String
    }

    private func composeLine() -> Line? {
        // 1. Pending attention is always #1 priority — the user came back
        //    to the app to handle something.
        if pendingCount > 0 {
            let things = pendingCount == 1 ? "cosa pendiente" : "cosas pendientes"
            return Line(
                icon: "exclamationmark.circle.fill",
                tint: .ruulSemanticWarning,
                text: "Te toca atender \(pendingCount) \(things)"
            )
        }
        // 2. Imminent event: today or tomorrow surfaces as next signal.
        if let event = nextEvent, let when = imminenceLabel(for: event) {
            return Line(
                icon: "calendar.badge.clock",
                tint: .ruulAccent,
                text: "\(event.title) es \(when)"
            )
        }
        // 3. Group has activity but nothing burning — reassuring tone.
        if hasStreamContent || hasPoolContent {
            return Line(
                icon: "checkmark.circle.fill",
                tint: .ruulSemanticSuccess,
                text: "Todo en orden"
            )
        }
        // 4. Empty group: defer to EmptyGroupHero.
        return nil
    }

    private func imminenceLabel(for event: Event) -> String? {
        let cal = Calendar.current
        if cal.isDateInToday(event.startsAt) { return "hoy" }
        if cal.isDateInTomorrow(event.startsAt) { return "mañana" }
        return nil
    }
}

