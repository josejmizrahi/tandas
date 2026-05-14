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
    public let onOpenGroupRules: () -> Void
    /// Push GroupHistoryView (timeline completa del grupo). Cuando nil
    /// la entry "Historial del grupo" en Más se oculta.
    public let onOpenActivity: (() -> Void)?

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
        onOpenSanciones: @escaping () -> Void,
        onOpenGroupRules: @escaping () -> Void,
        onOpenActivity: (() -> Void)? = nil
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
        self.onOpenGroupRules = onOpenGroupRules
        self.onOpenActivity = onOpenActivity
        self._selectedSubTab = State(initialValue: .overview)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            RuulSubTabBar(
                selected: $selectedSubTab,
                tabs: Self.subTabs(for: activeGroup, resolver: app.capabilityResolver)
            )
            .padding(.bottom, RuulSpacing.md)

            content
                .frame(maxHeight: .infinity)
        }
        .task { await refreshCounts() }
        .onChange(of: activeGroup.id) { _, _ in
            // If the user switches to a group whose visible sub-tabs no
            // longer include the currently selected one (e.g. moving from
            // a group with `basic_fines` to a blank one without money),
            // snap selection back to overview to avoid showing an empty
            // content area.
            let visible = Self.subTabs(for: activeGroup, resolver: app.capabilityResolver)
            if !visible.contains(selectedSubTab) {
                selectedSubTab = .overview
            }
        }
    }

    private var header: some View {
        HStack {
            // Beta 1 W3 A-3.5: convenience init keeps the API uniform with
            // the other two header callsites (MainTabView decisionsTab,
            // HomeView). HomeView wraps the switcher in a richer header
            // with greeting + icon buttons — documented exception, not an
            // API inconsistency.
            RuulGroupSwitcher(activeGroup: activeGroup, onTap: onSwitchGroup)
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
                inboxCoordinator: inboxCoordinator,
                userId: userId,
                onOpenInboxAction: onOpenInboxAction,
                onGoToMoney: { selectedSubTab = .money },
                onJumpToResources: { selectedSubTab = .resources },
                onJumpToMembers: { selectedSubTab = .members }
            )
        case .resources:
            GroupResourcesSubTab(group: activeGroup, onOpenEvent: onOpenEvent)
        case .money:
            GroupMoneySubTabContainer(
                group: activeGroup,
                currentUserId: userId,
                onCreateMoneyEntry: onCreateResource
            )
        case .members:
            MembersSubTabContainer(group: activeGroup)
        case .more:
            GroupMoreSubTab(
                openVotesCount: openVotesCount,
                outstandingFinesCount: outstandingFinesCount,
                onOpenRules: onOpenAcuerdos,
                onOpenVotes: onOpenDecisiones,
                onOpenFines: onOpenSanciones,
                onOpenGroupRules: onOpenGroupRules,
                onOpenActivity: onOpenActivity
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

    /// Sub-tabs visible for `group`. Delegates to the resolver so module
    /// activation drives the bar — V1 hides "Dinero" for groups whose
    /// active modules don't provide a `ledger` capability, Phase 2 will
    /// add module-specific sub-tabs without further edits here.
    public static func subTabs(
        for group: RuulCore.Group,
        resolver: CapabilityResolver
    ) -> [GroupSubTab] {
        resolver.availableGroupSubTabs(for: group)
            .compactMap { GroupSubTab(rawValue: $0) }
    }
}

/// Sub-tab inventory for the Grupo tab post-G1/G2. Conforms to RuulSubTabItem.
public enum GroupSubTab: String, RuulSubTabItem, CaseIterable {
    case overview
    case resources
    case money
    case members
    case more

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .overview:  return "Resumen"
        case .resources: return "Recursos"
        case .money:     return "Dinero"
        case .members:   return "Miembros"
        case .more:      return "Más"
        }
    }
}

/// Sub-tab content: polymorphic list of every resource in the group.
/// Events are first-class resources here too (the polymorphic model
/// treats them like any other type); the "two UIs for same thing" gap
/// the audit flagged is resolved by routing the tap, not by hiding
/// events from the list — taps on events go to the rich
/// `EventDetailView` via `onOpenEvent`, taps on non-events open the
/// universal `ResourceDetailSheet`. Empty state shown only when the
/// group truly has no resources of any kind yet.
private struct GroupResourcesSubTab: View {
    @Environment(AppState.self) private var app
    public let group: RuulCore.Group
    public let onOpenEvent: (Event) -> Void
    @State private var resources: [ResourceRow] = []
    @State private var opened: ResourceRow?
    @State private var isLoading: Bool = true

    /// Polymorphic time-bound metadata keys. Any resource that exposes
    /// one of these in the future moves to the top of the catalog.
    /// Mirror the same key priority used elsewhere (memoria
    /// `feedback_no_hardcoded_verticals`).
    private static let timeBoundKeys = [
        "starts_at", "startsAt", "due_at", "dueAt",
        "deadline_at", "deadlineAt", "next_at", "nextAt"
    ]

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.unitsStyle = .full
        return f
    }()

    /// Extracts the next-occurrence date from a resource's metadata.
    /// Polymorphic: any resource type works as long as it puts a date
    /// string under one of `timeBoundKeys`.
    private func nextAt(for row: ResourceRow) -> Date? {
        for key in Self.timeBoundKeys {
            if case let .string(s)? = row.metadata[key],
               let date = Self.isoFormatter.date(from: s) {
                return date
            }
        }
        return nil
    }

    /// Single sorted list. Future-dated first (ascending by date), then
    /// always-on (no nextAt), then past-dated last (descending by date).
    /// Status-closed resources sink within their tier so the active stuff
    /// floats to the top.
    private var sortedResources: [ResourceRow] {
        let now = Date.now
        return resources.sorted { lhs, rhs in
            let lhsAt = nextAt(for: lhs)
            let rhsAt = nextAt(for: rhs)
            let lhsFuture = (lhsAt ?? .distantPast) > now
            let rhsFuture = (rhsAt ?? .distantPast) > now
            let lhsPast   = (lhsAt != nil) && !lhsFuture
            let rhsPast   = (rhsAt != nil) && !rhsFuture

            // Tier 1: future-dated, ASC
            if lhsFuture && rhsFuture { return (lhsAt ?? now) < (rhsAt ?? now) }
            if lhsFuture { return true }
            if rhsFuture { return false }
            // Tier 2: always-on (no nextAt at all)
            if !lhsPast && !rhsPast { return lhs.createdAt > rhs.createdAt }
            if !lhsPast { return true }
            if !rhsPast { return false }
            // Tier 3: past, DESC
            return (lhsAt ?? .distantPast) > (rhsAt ?? .distantPast)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                if isLoading {
                    RuulLoadingState()
                        .padding(.top, RuulSpacing.xxl)
                } else if resources.isEmpty {
                    EmptyStateView(
                        systemImage: "square.stack",
                        title: "Sin recursos aún",
                        message: "Toca el botón + para crear un activo, slot, fondo u otro recurso."
                    )
                    .padding(.top, RuulSpacing.xl)
                } else {
                    headerSummary
                    ForEach(sortedResources) { row in
                        Button {
                            tap(row)
                        } label: {
                            resourceCard(row, at: nextAt(for: row))
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

    /// Header strip: total count + "próximos arriba" hint. Lets the user
    /// know the ordering rule at a glance without a separate "Próximamente"
    /// section (memoria — Home is the forward feed, not Grupo).
    private var headerSummary: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(resources.count) recursos")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            Spacer()
            if sortedResources.contains(where: { (nextAt(for: $0) ?? .distantPast) > .now }) {
                Text("PRÓXIMOS ARRIBA")
                    .font(.ruulMicro.weight(.semibold))
                    .foregroundStyle(Color.ruulTextTertiary)
                    .tracking(0.5)
            }
        }
        .padding(.horizontal, RuulSpacing.xxs)
    }

    private func resourceCard(_ row: ResourceRow, at: Date?) -> some View {
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
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(row.resourceType.humanLabel)
                    if let at = at {
                        Text("·")
                        Text(relativeFormatter.localizedString(for: at, relativeTo: .now))
                            .foregroundStyle(at > .now ? Color.ruulTextSecondary : Color.ruulTextTertiary)
                    }
                }
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
        return row.resourceType.humanLabel
    }

    private func iconFor(_ type: ResourceType) -> String {
        switch type {
        case .event:        return "calendar"
        case .fund:         return "banknote"
        case .asset:        return "key.fill"
        case .space:        return "mappin.and.ellipse"
        case .slot:         return "ticket"
        case .right:        return "person.badge.key.fill"
        default:            return "square.dashed"
        }
    }

    /// Tap routing: an event resource opens the rich event-specific
    /// surface (cover/parallax/RSVP) via the parent's onOpenEvent
    /// callback. Everything else opens the universal capability-driven
    /// `ResourceDetailSheet`.
    private func tap(_ row: ResourceRow) {
        if row.resourceType == .event {
            Task { await openEvent(rowId: row.id) }
        } else {
            opened = row
        }
    }

    @MainActor
    private func openEvent(rowId: UUID) async {
        if let event = try? await app.eventRepo.event(rowId) {
            onOpenEvent(event)
        }
    }

    @MainActor
    private func load() async {
        defer { isLoading = false }
        let types: [ResourceType] = [.event, .asset, .slot, .fund, .space, .right]
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

/// Same @State-holding container pattern for MembersSubTabCoordinator.
@MainActor
private struct MembersSubTabContainer: View {
    @Environment(AppState.self) private var app
    let group: RuulCore.Group
    @State private var coord: MembersSubTabCoordinator?

    var body: some View {
        Group {
            if let coord {
                MembersSubTab(coordinator: coord)
            } else {
                RuulLoadingState().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task {
            if coord == nil {
                coord = MembersSubTabCoordinator(
                    group: group,
                    ledgerRepo: app.ledgerRepo,
                    groupsRepo: app.groupsRepo
                )
                await coord?.refresh()
            }
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
