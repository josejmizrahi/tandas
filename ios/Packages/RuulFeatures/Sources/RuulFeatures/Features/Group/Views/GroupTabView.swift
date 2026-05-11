import SwiftUI
import RuulUI
import RuulCore

/// Tab "Grupo" per DS v3 §5.3 — composite con header (RuulGroupSwitcher) +
/// sub-tabs adaptativas según template del grupo activo. En V1 templates
/// dinner_recurring tienen Events / Rules / Fines.
///
/// **No conectado a MainTabView todavía** — Fase 4b hará el swap. Este
/// composite vive en paralelo a las tabs Reglas / Inbox actuales hasta entonces.
@MainActor
public struct GroupTabView: View {
    // Coordinators inyectados por el padre (MainTabView en Fase 4b).
    public let rulesCoordinator: RulesCoordinator
    /// Puede ser nil; en ese caso la sub-tab Multas se omite.
    public let myFinesCoordinator: MyFinesCoordinator?
    public let activeGroup: RuulCore.Group
    /// Próximos eventos del grupo activo (HomeCoordinator post-Fase 3 expone esto).
    public let upcomingEvents: [Event]
    public let myRSVPs: [UUID: RSVP]
    public let onSwitchGroup: () -> Void
    public let onOpenEvent: (Event) -> Void
    public let onOpenFine: (Fine) -> Void
    public let onOpenRule: (GroupRule) -> Void
    public let voteRepo: any VoteRepository
    public let voteCastRepo: (any VoteCastRepository)?
    public let userMemberId: UUID?
    public let userActionRepo: (any UserActionRepository)?
    public let onSeeOpenVotes: () -> Void
    public let onSelectVote: (Vote) -> Void
    public let onCreateVote: () -> Void

    @State private var selectedSubTab: GroupSubTab

    public init(
        rulesCoordinator: RulesCoordinator,
        myFinesCoordinator: MyFinesCoordinator?,
        activeGroup: RuulCore.Group,
        upcomingEvents: [Event],
        myRSVPs: [UUID: RSVP],
        onSwitchGroup: @escaping () -> Void,
        onOpenEvent: @escaping (Event) -> Void,
        onOpenFine: @escaping (Fine) -> Void,
        onOpenRule: @escaping (GroupRule) -> Void = { _ in },
        voteRepo: any VoteRepository,
        voteCastRepo: (any VoteCastRepository)? = nil,
        userMemberId: UUID? = nil,
        userActionRepo: (any UserActionRepository)?,
        onSeeOpenVotes: @escaping () -> Void,
        onSelectVote: @escaping (Vote) -> Void = { _ in },
        onCreateVote: @escaping () -> Void = { }
    ) {
        self.rulesCoordinator = rulesCoordinator
        self.myFinesCoordinator = myFinesCoordinator
        self.activeGroup = activeGroup
        self.upcomingEvents = upcomingEvents
        self.myRSVPs = myRSVPs
        self.onSwitchGroup = onSwitchGroup
        self.onOpenEvent = onOpenEvent
        self.onOpenFine = onOpenFine
        self.onOpenRule = onOpenRule
        self.voteRepo = voteRepo
        self.voteCastRepo = voteCastRepo
        self.userMemberId = userMemberId
        self.userActionRepo = userActionRepo
        self.onSeeOpenVotes = onSeeOpenVotes
        self.onSelectVote = onSelectVote
        self.onCreateVote = onCreateVote
        let resolved = GroupTabView.subTabs(for: activeGroup, hasFines: myFinesCoordinator != nil)
        self._selectedSubTab = State(initialValue: resolved.first ?? .rules)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            RuulSubTabBar(
                selected: $selectedSubTab,
                tabs: Self.subTabs(for: activeGroup, hasFines: myFinesCoordinator != nil)
            )
            .padding(.bottom, RuulSpacing.md)

            content
                .frame(maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack {
            RuulGroupSwitcher(
                activeGroupName: activeGroup.name,
                activeCategory: activeGroup.category,
                activeInitials: activeGroup.initials,
                onTap: onSwitchGroup
            )
            Spacer()
        }
        .padding(.horizontal, RuulSpacing.screenPadding)
        .padding(.vertical, RuulSpacing.md)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedSubTab {
        case .events:
            EventsSubTabContent(
                upcomingEvents: upcomingEvents,
                myRSVPs: myRSVPs,
                onOpenEvent: onOpenEvent
            )
        case .rules:
            RulesView(
                coordinator: rulesCoordinator,
                voteRepo: voteRepo,
                userActionRepo: userActionRepo,
                onSeeOpenVotes: onSeeOpenVotes,
                onSelectRule: onOpenRule
            )
        case .votes:
            // Wrap in @State container so coord survives parent re-renders
            // (same pattern used for ReviewProposed + VoteDetail).
            VotesSubTabContainer(
                group: activeGroup,
                voteRepo: voteRepo,
                castRepo: voteCastRepo,
                userMemberId: userMemberId,
                onSelectVote: onSelectVote,
                onCreateVote: onCreateVote
            )
        case .fines:
            if let coord = myFinesCoordinator {
                MyFinesView(coordinator: coord, onOpenFine: onOpenFine)
            } else {
                EmptyView()
            }
        case .resources:
            GroupResourcesSubTab(group: activeGroup)
        }
    }

    /// Sub-tabs available based on the group's template. V1 dinner-recurring
    /// has Events + Rules + Recursos + Votes + Fines. Future templates expand.
    /// `hasFines` excluye la sub-tab de Multas cuando no hay coordinator.
    public static func subTabs(for group: RuulCore.Group, hasFines: Bool = true) -> [GroupSubTab] {
        var tabs: [GroupSubTab] = [.events, .resources, .rules, .votes]
        if hasFines && CapabilityResolver().finesEnabled(in: group) {
            tabs.append(.fines)
        }
        return tabs
    }
}

/// Sub-tab inventory for the Grupo tab. Conforms to RuulSubTabItem.
public enum GroupSubTab: String, RuulSubTabItem, CaseIterable {
    case events
    case resources
    case rules
    case votes
    case fines

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .events:    return "Eventos"
        case .resources: return "Recursos"
        case .rules:     return "Reglas"
        case .votes:     return "Votos"
        case .fines:     return "Multas"
        }
    }
}

/// Sub-tab content: polymorphic list of every non-event resource in the
/// group. Tap → ResourceDetailSheet (polymorphic). Empty state shown
/// when the group has no assets/slots/funds/etc. yet.
private struct GroupResourcesSubTab: View {
    @Environment(AppState.self) private var app
    public let group: RuulCore.Group
    @State private var resources: [ResourceRow] = []
    @State private var opened: ResourceRow?
    @State private var isLoading: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, RuulSpacing.xxl)
                } else if resources.isEmpty {
                    EmptyStateView(
                        systemImage: "square.stack",
                        title: "Sin recursos aún",
                        message: "Toca el botón + para crear un activo, slot, fondo u otro recurso."
                    )
                    .padding(.top, RuulSpacing.xl)
                } else {
                    ForEach(resources) { row in
                        Button {
                            opened = row
                        } label: {
                            resourceCard(row)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, RuulSpacing.screenPadding)
            .padding(.vertical, RuulSpacing.md)
        }
        .task { await load() }
        .sheet(item: $opened) { row in
            ResourceDetailSheet(resource: row)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func resourceCard(_ row: ResourceRow) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            ZStack {
                Circle().fill(Color.ruulSurface).frame(width: 40, height: 40)
                Image(systemName: iconFor(row.resourceType))
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(displayNameFor(row))
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(typeLabelFor(row.resourceType))
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ruulTextTertiary)
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    private func displayNameFor(_ row: ResourceRow) -> String {
        if case let .string(s) = row.metadata["name"]  { return s }
        if case let .string(s) = row.metadata["title"] { return s }
        return typeLabelFor(row.resourceType)
    }

    private func iconFor(_ type: ResourceType) -> String {
        switch type {
        case .event:        return "calendar"
        case .asset:        return "key.fill"
        case .slot:         return "ticket"
        case .fund:         return "banknote"
        case .booking:      return "calendar.badge.checkmark"
        case .contribution: return "arrow.up.bin"
        default:            return "square.dashed"
        }
    }

    private func typeLabelFor(_ type: ResourceType) -> String {
        switch type {
        case .event:        return "Evento"
        case .asset:        return "Activo"
        case .slot:         return "Slot"
        case .fund:         return "Fondo"
        case .booking:      return "Reserva"
        case .contribution: return "Aportación"
        case .position:     return "Posición"
        case .assignment:   return "Tarea"
        case .rotation:     return "Rotación"
        case .guestPass:    return "Invitado"
        case .proposal:     return "Propuesta"
        case .unknown(let raw): return raw
        }
    }

    @MainActor
    private func load() async {
        defer { isLoading = false }
        let types: [ResourceType] = [.event, .asset, .slot, .fund, .booking, .contribution]
        do {
            resources = try await app.resourceRepo.list(
                in: group.id,
                types: types,
                statuses: nil,
                limit: 200
            )
        } catch {
            resources = []
        }
    }
}

/// Compacto: lista cronológica de upcoming events del grupo activo.
/// Reusa `EventRow` (Fase 3 lo migró a aceptar `originGroup`).
private struct EventsSubTabContent: View {
    public let upcomingEvents: [Event]
    public let myRSVPs: [UUID: RSVP]
    public let onOpenEvent: (Event) -> Void

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                if upcomingEvents.isEmpty {
                    EmptyStateView(
                        systemImage: "calendar",
                        title: "Sin próximos eventos",
                        message: "Crea el primer evento del grupo."
                    )
                    .padding(.top, RuulSpacing.xl)
                } else {
                    ForEach(upcomingEvents) { event in
                        EventRow(
                            event: event,
                            // Dentro de Grupo tab el scope es uno solo —
                            // origin tag redundante.
                            originGroup: nil,
                            myStatus: myRSVPs[event.id]?.status,
                            onTap: { onOpenEvent(event) }
                        )
                    }
                }
            }
            .padding(.horizontal, RuulSpacing.screenPadding)
            .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
        }
        .scrollIndicators(.hidden)
    }
}

/// @State-holding container so the OpenVotesCoordinator survives parent
/// re-renders (otherwise `.task { coord.refresh() }` gets cancelled with
/// CancellationError before the fetch completes).
@MainActor
private struct VotesSubTabContainer: View {
    let group: RuulCore.Group
    let voteRepo: any VoteRepository
    let castRepo: (any VoteCastRepository)?
    let userMemberId: UUID?
    let onSelectVote: (Vote) -> Void
    let onCreateVote: () -> Void

    @State private var coord: OpenVotesCoordinator

    init(
        group: RuulCore.Group,
        voteRepo: any VoteRepository,
        castRepo: (any VoteCastRepository)?,
        userMemberId: UUID?,
        onSelectVote: @escaping (Vote) -> Void,
        onCreateVote: @escaping () -> Void
    ) {
        self.group = group
        self.voteRepo = voteRepo
        self.castRepo = castRepo
        self.userMemberId = userMemberId
        self.onSelectVote = onSelectVote
        self.onCreateVote = onCreateVote
        self._coord = State(wrappedValue: OpenVotesCoordinator(
            group: group,
            voteRepo: voteRepo,
            castRepo: castRepo,
            userMemberId: userMemberId
        ))
    }

    var body: some View {
        OpenVotesListView(
            coordinator: coord,
            onSelectVote: onSelectVote,
            onCreateVote: onCreateVote
        )
    }
}

#if DEBUG
#Preview("GroupTabView") {
    Text("GroupTabView preview requires RuulCore.Group + RulesCoordinator + MyFinesCoordinator fixtures — see Showcase.")
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
}
#endif
