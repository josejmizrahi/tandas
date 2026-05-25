import SwiftUI
import RuulUI
import RuulCore

/// Group "space" — the persistent home for a community.
///
/// PR-1 (2026-05-25) pivots to the situational-stream doctrine
/// (`doctrine_group_space_situational`): the home renders
/// `GroupPresenceHeader` → `GroupComposeBar` → `GroupClusterStream`
/// (o `EmptyGroupHero` cuando todos los clusters están vacíos). Se
/// borraron el antiguo `GroupSpacesGrid`, el `SharedMoneyCard` como
/// superficie top, y los destinos peer por tipo (Eventos / Multas /
/// Fondos / Activos / Balances) — la navegación ahora ocurre directo
/// desde las filas de los clusters.
///
/// Sub-screens reachable from here:
///   - Avatar stack → MembersList (`onOpenMembers`)
///   - UpcomingCluster row → Event detail (`onOpenEvent`)
///   - AttentionCluster row → `onSelectPending` → router dispatch
///   - Compose chips (Crear / Votar / Invitar / Compartir) → router
///   - JustHappenedCluster "Ver todo" → Activity
///   - "⋯" menu → Compartir invitación / Ajustes / Salir
@MainActor
public struct GroupSpaceView: View {
    @State var coordinator: GroupHomeCoordinator
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// El `+` de "Dinero reciente" salta directo al sheet
    /// correspondiente — sin pasar por un picker intermedio
    /// (founder decision 2026-05-25).
    private enum SharedMoneySheet: Identifiable {
        case contribute, recordExpense, settle
        var id: Self { self }
    }
    @State private var sharedMoneySheet: SharedMoneySheet?

    // Compose chips
    public var onCreateEvent: () -> Void
    public var onStartVote: () -> Void
    public var onInviteMembers: () -> Void
    public var onShareInvite: () -> Void

    // Cluster row routing
    public var onOpenEvent: (Event) -> Void
    public var onSelectPending: (UserAction) -> Void
    public var onOpenInUseResource: (UUID) -> Void

    // Header + stream
    public var onOpenMembers: (() -> Void)?
    public var onOpenActivity: (() -> Void)?
    public var onOpenTransactions: (() -> Void)?
    public var onOpenEventsHistory: (() -> Void)?

    // Toolbar
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
            AsyncContentView(
                phase: coordinator.phase,
                onRetry: { await coordinator.refresh() },
                loaded: { _ in loadedScroll }
            )
        }
        .task { await coordinator.refresh() }
        .toolbar { toolbarContent }
    }

    @ViewBuilder
    private var loadedScroll: some View {
        if let group = coordinator.group {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RuulSpacing.xl) {
                    GroupPresenceHeader(
                        group: group,
                        memberCount: coordinator.memberCount,
                        members: coordinator.members,
                        onTapMembers: onOpenMembers
                    )

                    GroupComposeBar(chips: composeChips())

                    if isEmpty {
                        EmptyGroupHero(
                            onInvite: onInviteMembers,
                            onCreate: onCreateEvent
                        )
                    } else {
                        GroupClusterStream(
                            attention: coordinator.pendingActions,
                            upcoming: coordinator.upcomingEvents,
                            recentMoney: coordinator.recentMoneyEntries,
                            inUse: coordinator.inUseItems,
                            recentActivity: coordinator.recentActivity,
                            actor: app.profile,
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

    /// Todos los clusters vacíos → render `EmptyGroupHero` debajo del
    /// PresenceHeader + ComposeBar. Regla de la doctrina: si no hay
    /// vida, no inventes estructura.
    private var isEmpty: Bool {
        coordinator.pendingActions.isEmpty
            && coordinator.upcomingEvents.isEmpty
            && coordinator.recentMoneyEntries.isEmpty
            && coordinator.inUseItems.isEmpty
            && coordinator.recentActivity.isEmpty
    }

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

    private func composeChips() -> [GroupComposeBar.Chip] {
        [
            .init(
                id: "create",
                label: "Crear",
                systemImage: "plus.circle.fill",
                tint: Color.ruulWarning,
                action: onCreateEvent
            ),
            .init(
                id: "vote",
                label: "Votar",
                systemImage: "checkmark.square",
                tint: GroupColorRamp.blue.accent,
                action: onStartVote
            ),
            .init(
                id: "invite",
                label: "Invitar",
                systemImage: "person.badge.plus",
                tint: GroupColorRamp.purple.accent,
                action: onInviteMembers
            ),
            .init(
                id: "share",
                label: "Compartir",
                systemImage: "square.and.arrow.up",
                tint: GroupColorRamp.teal.accent,
                action: onShareInvite
            )
        ]
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
