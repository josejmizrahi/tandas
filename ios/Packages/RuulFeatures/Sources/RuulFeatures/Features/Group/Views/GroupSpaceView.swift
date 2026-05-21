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
        }
    }

    private func composeChips() -> [GroupComposeBar.Chip] {
        [
            .init(id: "event",   label: "Evento",   systemImage: "calendar.badge.plus",
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
        let fundsCount = coordinator.groupFundsCount

        let finesAlert: String? = {
            guard let s, s.pendingFinesOutstandingCents > 0 else { return nil }
            let fmt = NumberFormatter()
            fmt.numberStyle = .currency
            fmt.currencyCode = currency
            fmt.maximumFractionDigits = 0
            let amount = Double(s.pendingFinesOutstandingCents) / 100.0
            return fmt.string(from: NSNumber(value: amount)).map { "\($0) por pagar" } ?? "Por pagar"
        }()

        return [
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
            ),
            .init(
                id: "funds",
                label: "Fondos",
                systemImage: "banknote",
                tint: Color.ruulPositive,
                primary: "\(fundsCount)",
                secondary: fundsCount == 1 ? "fondo activo" : "fondos activos",
                alert: nil,
                action: { onOpenFunds?() }
            )
        ]
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
