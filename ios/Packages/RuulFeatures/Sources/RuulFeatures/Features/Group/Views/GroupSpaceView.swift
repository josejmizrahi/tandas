import SwiftUI
import RuulUI
import RuulCore

/// Group "space" — the persistent home for a community. Replaces
/// the V2 Slice 4F `GroupHomeView` (Settings-style tab pair: Personas
/// / Cómo decidimos) with a single layered scroll using the canonical
/// section card chrome (`Color.ruulSurface` + separator stroke).
///
///   1. Presence header (RuulGroupAvatar + name + member count + stack)
///   2. Compose bar (chips: Evento · Decidir · Invitar)
///   3. Pendings block (UserActions + CTA capsules)
///   4. Spaces grid (Eventos · Decisiones · Multas · Inbox)
///   5. Activity stream (current user's recent actions in this group)
///
/// Sub-screens previously gated behind the "Personas" / "Cómo
/// decidimos" tabs now live behind:
///   - Avatar stack → MembersList (`onOpenMembers`)
///   - "Decisiones" tile / chip → Acuerdos (`onOpenDecisions`)
///   - "⋯" menu → Edit / Advanced / Leave
@MainActor
public struct GroupSpaceView: View {
    @State var coordinator: GroupHomeCoordinator
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// Routes the two `SharedMoneyCard` CTAs to their group-scoped
    /// sheets (SharedMoney Phase 3 § 5). Quick-action shape → `.medium`
    /// default detent with `.large` available.
    private enum SharedMoneySheet: Identifiable {
        case contribute, recordExpense
        var id: Self { self }
    }
    @State private var sharedMoneySheet: SharedMoneySheet?

    // Compose chips routing
    public var onCreateEvent: () -> Void
    public var onStartVote: () -> Void
    public var onOpenDecisions: () -> Void
    public var onInviteMembers: () -> Void
    public var onShareInvite: () -> Void

    // Spaces grid
    public var onOpenEvents: (() -> Void)?
    public var onOpenFines: (() -> Void)?
    public var onOpenFunds: (() -> Void)?
    public var onOpenAssets: (() -> Void)?
    public var onOpenBalances: (() -> Void)?
    public var onOpenInbox: (() -> Void)?

    // Header + stream
    public var onOpenMembers: (() -> Void)?
    public var onOpenActivity: (() -> Void)?

    // Pendings
    public var onSelectPending: (UserAction) -> Void

    // Toolbar menu — single entry into the unified Ajustes del grupo
    public var onOpenAjustes: (() -> Void)?
    public var onConfirmLeave: (() -> Void)?
    public var onLeaveGroup: () -> Void

    public init(
        coordinator: GroupHomeCoordinator,
        onCreateEvent: @escaping () -> Void,
        onStartVote: @escaping () -> Void,
        onOpenDecisions: @escaping () -> Void,
        onInviteMembers: @escaping () -> Void,
        onShareInvite: @escaping () -> Void,
        onOpenEvents: (() -> Void)? = nil,
        onOpenFines: (() -> Void)? = nil,
        onOpenFunds: (() -> Void)? = nil,
        onOpenAssets: (() -> Void)? = nil,
        onOpenBalances: (() -> Void)? = nil,
        onOpenInbox: (() -> Void)? = nil,
        onOpenMembers: (() -> Void)? = nil,
        onOpenActivity: (() -> Void)? = nil,
        onSelectPending: @escaping (UserAction) -> Void,
        onOpenAjustes: (() -> Void)? = nil,
        onConfirmLeave: (() -> Void)? = nil,
        onLeaveGroup: @escaping () -> Void
    ) {
        self._coordinator = State(initialValue: coordinator)
        self.onCreateEvent = onCreateEvent
        self.onStartVote = onStartVote
        self.onOpenDecisions = onOpenDecisions
        self.onInviteMembers = onInviteMembers
        self.onShareInvite = onShareInvite
        self.onOpenEvents = onOpenEvents
        self.onOpenFines = onOpenFines
        self.onOpenFunds = onOpenFunds
        self.onOpenAssets = onOpenAssets
        self.onOpenBalances = onOpenBalances
        self.onOpenInbox = onOpenInbox
        self.onOpenMembers = onOpenMembers
        self.onOpenActivity = onOpenActivity
        self.onSelectPending = onSelectPending
        self.onOpenAjustes = onOpenAjustes
        self.onConfirmLeave = onConfirmLeave
        self.onLeaveGroup = onLeaveGroup
    }

    public var body: some View {
        ZStack {
            // Apple Settings / Luma pattern: subtle gray page bg so the
            // `Color.ruulSurface` cards read as bright white-ish tiles
            // against it. Using `ruulBackground` (systemBackground) made
            // the cards look darker than the page, inverting the intent.
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

                    // SharedMoney P8: shared pool + viewer's "Te deben/
                    // Debes" merged into one consolidated "Dinero" card.
                    // The obligation strip is hidden internally when
                    // the viewer is settled (netCents == 0).
                    if let summary = coordinator.sharedPoolSummary {
                        SharedMoneyCard(
                            summary: summary,
                            viewerObligation: coordinator.viewerBalance,
                            onContribute: { sharedMoneySheet = .contribute },
                            onRecordExpense: { sharedMoneySheet = .recordExpense },
                            onOpenDetail: { onOpenBalances?() }
                        )
                    }

                    if !coordinator.pendingActions.isEmpty {
                        GroupPendingsBlock(
                            items: coordinator.pendingActions,
                            onSelect: onSelectPending
                        )
                    }

                    GroupSpacesGrid(tiles: spaceTiles(currency: group.currency))

                    if !coordinator.recentActivity.isEmpty {
                        GroupStreamBlock(
                            items: coordinator.recentActivity,
                            actor: app.profile,
                            locale: app.profile?.locale ?? "es-MX",
                            onSeeAll: onOpenActivity
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
        }
    }

    private func composeChips() -> [GroupComposeBar.Chip] {
        [
            .init(id: "create",  label: "Crear",    systemImage: "plus.circle.fill",
                  tint: Color.ruulWarning,             action: onCreateEvent),
            .init(id: "vote",    label: "Votar",    systemImage: "checkmark.square",
                  tint: GroupColorRamp.blue.accent,    action: onStartVote),
            .init(id: "invite",  label: "Invitar",  systemImage: "person.badge.plus",
                  tint: GroupColorRamp.purple.accent,  action: onInviteMembers),
            .init(id: "share",   label: "Compartir", systemImage: "square.and.arrow.up",
                  tint: GroupColorRamp.teal.accent,    action: onShareInvite)
        ]
    }

    private func spaceTiles(currency: String) -> [GroupSpacesGrid.Tile] {
        let s = coordinator.summary
        let eventsCount = coordinator.upcomingEventsCount
        let finesCount = coordinator.groupFinesCount
        // SharedMoney Phase 3: the canonical shared pool lives in the
        // SharedMoneyCard above. This tile only counts OTHER (protected/
        // legacy) funds and hides entirely when there are none.
        let otherFundsCount = coordinator.otherFundsCount

        let finesAlert: String? = {
            guard let s, s.pendingFinesOutstandingCents > 0 else { return nil }
            let fmt = NumberFormatter()
            fmt.numberStyle = .currency
            fmt.currencyCode = currency
            fmt.maximumFractionDigits = 0
            let amount = Double(s.pendingFinesOutstandingCents) / 100.0
            return fmt.string(from: NSNumber(value: amount)).map { "\($0) por pagar" } ?? "Por pagar"
        }()

        var tiles: [GroupSpacesGrid.Tile] = [
            .init(
                id: "events",
                label: "Eventos",
                systemImage: "calendar",
                tint: Color.ruulWarning,
                primary: "\(eventsCount)",
                secondary: eventsCount == 1 ? "próximo" : "próximos",
                alert: nil,
                action: { onOpenEvents?() }
            ),
            .init(
                id: "decisions",
                label: "Decisiones",
                systemImage: "checkmark.square",
                tint: GroupColorRamp.blue.accent,
                primary: "\(s?.openVotesCount ?? 0)",
                secondary: (s?.openVotesCount ?? 0) == 1 ? "voto abierto" : "votos abiertos",
                alert: nil,
                action: onOpenDecisions
            ),
            .init(
                id: "fines",
                label: "Multas",
                systemImage: "exclamationmark.triangle.fill",
                tint: Color.ruulNegative,
                primary: "\(finesCount)",
                secondary: finesCount == 1 ? "multa" : "multas",
                alert: finesAlert,
                action: { onOpenFines?() }
            )
        ]

        // 2026-05-24: "Otros fondos" no longer appears as a peer tile
        // in the spaces grid. The shared-money doctrine treats the pool
        // as the primary money surface and legacy/protected funds as the
        // exception — they're now discovered inside the "Dinero del
        // grupo" detail (footer link) so the grid stays focused on the
        // canonical verbs (Eventos / Decisiones / Multas / Activos).
        _ = otherFundsCount

        // SharedMoney Phase 4 brick C.2: "Activos" tile — group's
        // physical/financial assets (nave industrial, vehículo,
        // inversión per AssetVariants). Hides at 0 to keep the grid
        // tight; appears as soon as the first asset is created.
        let assetsCount = coordinator.groupAssetsCount
        if assetsCount > 0 {
            tiles.append(
                .init(
                    id: "assets",
                    label: "Activos",
                    systemImage: "shippingbox",
                    tint: GroupColorRamp.purple.accent,
                    primary: "\(assetsCount)",
                    secondary: assetsCount == 1 ? "activo" : "activos",
                    alert: nil,
                    action: { onOpenAssets?() }
                )
            )
        }

        return tiles
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Compartir invitación", systemImage: "square.and.arrow.up", action: onShareInvite)
                if let onOpenAjustes {
                    Button("Ajustes del grupo", systemImage: "gearshape", action: onOpenAjustes)
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
