import SwiftUI
import RuulUI
import RuulCore

/// Tab "Grupo" post-G1 — composite con header (RuulGroupSwitcher) +
/// sub-tabs reorganizados para reflejar "vida operativa del grupo"
/// (Overview / Resources / Money / Más) en vez del corte técnico
/// previo (Events / Rules / Votes / Fines).
///
/// Governance (reglas + votos + multas) vive ahora un nivel más abajo
/// adentro de "Más" — Acuerdos / Decisiones / Sanciones.
@MainActor
public struct GroupTabView: View {
    @Environment(AppState.self) private var app
    public let activeGroup: RuulCore.Group
    public let userId: UUID

    // Coordinators inyectados por el padre.
    public let rulesCoordinator: RulesCoordinator
    /// nil ⇒ el rol del usuario no tiene visibilidad de multas; "Sanciones"
    /// se esconde en Más automáticamente.
    public let myFinesCoordinator: MyFinesCoordinator?
    public let inboxCoordinator: InboxCoordinator?

    /// Próximos eventos del grupo activo (HomeCoordinator los expone).
    public let upcomingEvents: [Event]
    public let myRSVPs: [UUID: RSVP]

    // Callbacks.
    public let onSwitchGroup: () -> Void
    public let onOpenEvent: (Event) -> Void
    public let onOpenFine: (Fine) -> Void
    public let onOpenInboxAction: (UserAction) async -> Void
    public let onCreateResource: () -> Void
    public let onOpenAcuerdos: () -> Void
    public let onOpenDecisiones: () -> Void
    public let onOpenSanciones: () -> Void

    @State private var selectedSubTab: GroupSubTab
    @State private var openVotesCount: Int = 0

    public init(
        activeGroup: RuulCore.Group,
        userId: UUID,
        rulesCoordinator: RulesCoordinator,
        myFinesCoordinator: MyFinesCoordinator?,
        inboxCoordinator: InboxCoordinator?,
        upcomingEvents: [Event],
        myRSVPs: [UUID: RSVP],
        onSwitchGroup: @escaping () -> Void,
        onOpenEvent: @escaping (Event) -> Void,
        onOpenFine: @escaping (Fine) -> Void,
        onOpenInboxAction: @escaping (UserAction) async -> Void,
        onCreateResource: @escaping () -> Void,
        onOpenAcuerdos: @escaping () -> Void,
        onOpenDecisiones: @escaping () -> Void,
        onOpenSanciones: @escaping () -> Void
    ) {
        self.activeGroup = activeGroup
        self.userId = userId
        self.rulesCoordinator = rulesCoordinator
        self.myFinesCoordinator = myFinesCoordinator
        self.inboxCoordinator = inboxCoordinator
        self.upcomingEvents = upcomingEvents
        self.myRSVPs = myRSVPs
        self.onSwitchGroup = onSwitchGroup
        self.onOpenEvent = onOpenEvent
        self.onOpenFine = onOpenFine
        self.onOpenInboxAction = onOpenInboxAction
        self.onCreateResource = onCreateResource
        self.onOpenAcuerdos = onOpenAcuerdos
        self.onOpenDecisiones = onOpenDecisiones
        self.onOpenSanciones = onOpenSanciones
        self._selectedSubTab = State(initialValue: .overview)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            RuulSubTabBar(
                selected: $selectedSubTab,
                tabs: Self.subTabs(for: activeGroup)
            )
            .padding(.bottom, RuulSpacing.md)

            content
                .frame(maxHeight: .infinity)
        }
        .task { await refreshCounts() }
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
        case .overview:
            GroupOverviewSubTab(
                group: activeGroup,
                upcomingEvents: upcomingEvents,
                myRSVPs: myRSVPs,
                inboxCoordinator: inboxCoordinator,
                userId: userId,
                onOpenEvent: onOpenEvent,
                onOpenFine: onOpenFine,
                onOpenInboxAction: onOpenInboxAction,
                onGoToMoney: { selectedSubTab = .money }
            )
        case .resources:
            GroupResourcesSubTab(group: activeGroup)
        case .money:
            GroupMoneySubTabContainer(
                group: activeGroup,
                currentUserId: userId,
                onCreateMoneyEntry: onCreateResource
            )
        case .more:
            GroupMoreSubTab(
                openVotesCount: openVotesCount,
                outstandingFinesCount: outstandingFinesCount,
                onOpenRules: onOpenAcuerdos,
                onOpenVotes: onOpenDecisiones,
                onOpenFines: onOpenSanciones
            )
        }
    }

    private var outstandingFinesCount: Int {
        guard let coord = myFinesCoordinator else { return 0 }
        return coord.fines.filter { $0.status == .officialized && !$0.paid && !$0.waived }.count
    }

    @MainActor
    private func refreshCounts() async {
        // Open votes count for the More badge. Best-effort: fall back to 0
        // if the query fails (RLS, network blip). Coordinator-grade refresh
        // happens when the user navigates into Decisiones.
        do {
            let votes = try await app.voteRepo.openVotes(for: activeGroup.id)
            openVotesCount = votes.count
        } catch {
            openVotesCount = 0
        }
    }

    /// Sub-tabs available based on the group's template. V1 returns the
    /// canonical four (Overview / Recursos / Dinero / Más). Future
    /// templates can hide tabs (e.g. a group with no money capability
    /// could drop Dinero).
    public static func subTabs(for group: RuulCore.Group) -> [GroupSubTab] {
        [.overview, .resources, .money, .more]
    }
}

/// Sub-tab inventory for the Grupo tab post-G1. Conforms to RuulSubTabItem.
public enum GroupSubTab: String, RuulSubTabItem, CaseIterable {
    case overview
    case resources
    case money
    case more

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .overview:  return "Resumen"
        case .resources: return "Recursos"
        case .money:     return "Dinero"
        case .more:      return "Más"
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

/// @State-holding container so GroupMoneyCoordinator survives parent
/// re-renders (otherwise `.task { coord.refresh() }` gets cancelled with
/// CancellationError before the fetch completes).
@MainActor
private struct GroupMoneySubTabContainer: View {
    @Environment(AppState.self) private var app
    let group: RuulCore.Group
    let currentUserId: UUID
    let onCreateMoneyEntry: () -> Void

    @State private var coord: GroupMoneyCoordinator?

    var body: some View {
        Group {
            if let coord {
                GroupMoneyView(coordinator: coord, onCreateMoneyEntry: onCreateMoneyEntry)
            } else {
                RuulLoadingState().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task {
            if coord == nil {
                coord = GroupMoneyCoordinator(
                    group: group,
                    currentUserId: currentUserId,
                    ledgerRepo: app.ledgerRepo,
                    groupsRepo: app.groupsRepo,
                    resourceRepo: app.resourceRepo
                )
                await coord?.refresh()
            }
        }
    }
}

#if DEBUG
#Preview("GroupTabView") {
    Text("GroupTabView preview requires RuulCore.Group + RulesCoordinator + MyFinesCoordinator fixtures — see Showcase.")
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
}
#endif
