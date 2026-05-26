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
        case contribute, recordExpense, settle
        var id: Self { self }
    }
    @State private var sharedMoneySheet: SharedMoneySheet?

    // Compose chips (toolbar "+")
    public var onCreateEvent: () -> Void
    public var onStartVote: () -> Void
    public var onInviteMembers: () -> Void
    public var onShareInvite: () -> Void

    // Cluster row routing
    public var onOpenEvent: (Event) -> Void
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
                        onTapMembers: onOpenMembers
                    )

                    if let pool = coordinator.sharedPoolSummary, shouldShowPool(pool) {
                        GroupPoolStatusBlock(
                            pool: pool,
                            viewerBalance: coordinator.viewerBalance,
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
                            upcoming: coordinator.upcomingEvents,
                            recentMoney: coordinator.recentMoneyEntries,
                            inUse: coordinator.inUseItems,
                            recentActivity: coordinator.groupActivityEvents,
                            locale: app.profile?.locale ?? "es-MX",
                            members: coordinator.allMembers,
                            currency: group.currency,
                            onSelectPending: onSelectPending,
                            onOpenEvent: onOpenEvent,
                            onOpenInUseResource: onOpenInUseResource,
                            onSeeAllActivity: onOpenActivity,
                            onSeeAllMoney: onOpenTransactions,
                            onSeeAllUpcoming: onOpenEventsHistory,
                            onRegisterExpense: { sharedMoneySheet = .recordExpense },
                            onContribute: { sharedMoneySheet = .contribute },
                            onSettle: { sharedMoneySheet = .settle }
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
            || !coordinator.upcomingEvents.isEmpty
            || !coordinator.recentMoneyEntries.isEmpty
            || !coordinator.inUseItems.isEmpty
            || !coordinator.groupActivityEvents.isEmpty
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
                    Text("Dinero compartido")
                        .font(.footnote)
                        .foregroundStyle(Color.ruulTextSecondary)
                    Text(formattedBalance)
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(balanceTint)
                        .contentTransition(.numericText())
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
        if let balance = viewerBalance, balance.netCents != 0 {
            let isViewerCredited = balance.netCents > 0
            let amountFormatted = formatAmount(abs(balance.netCents), currency: balance.currency)
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: isViewerCredited ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill")
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

            Button(action: onSettle) {
                Label("Liquidar", systemImage: "arrow.left.arrow.right.circle")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
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
