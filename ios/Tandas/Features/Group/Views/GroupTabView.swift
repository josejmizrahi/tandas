import SwiftUI

/// Tab "Grupo" per DS v3 §5.3 — composite con header (RuulGroupSwitcher) +
/// sub-tabs adaptativas según template del grupo activo. En V1 templates
/// dinner_recurring tienen Events / Rules / Fines.
///
/// **No conectado a MainTabView todavía** — Fase 4b hará el swap. Este
/// composite vive en paralelo a las tabs Reglas / Inbox actuales hasta entonces.
@MainActor
struct GroupTabView: View {
    // Coordinators inyectados por el padre (MainTabView en Fase 4b).
    let rulesCoordinator: RulesCoordinator
    /// Puede ser nil; en ese caso la sub-tab Multas se omite.
    let myFinesCoordinator: MyFinesCoordinator?
    let activeGroup: Group
    /// Próximos eventos del grupo activo (HomeCoordinator post-Fase 3 expone esto).
    let upcomingEvents: [Event]
    let myRSVPs: [UUID: RSVP]
    let onSwitchGroup: () -> Void
    let onOpenEvent: (Event) -> Void
    let onOpenFine: (Fine) -> Void
    let voteRepo: any VoteRepository
    let userActionRepo: (any UserActionRepository)?
    let onSeeOpenVotes: () -> Void

    @State private var selectedSubTab: GroupSubTab

    init(
        rulesCoordinator: RulesCoordinator,
        myFinesCoordinator: MyFinesCoordinator?,
        activeGroup: Group,
        upcomingEvents: [Event],
        myRSVPs: [UUID: RSVP],
        onSwitchGroup: @escaping () -> Void,
        onOpenEvent: @escaping (Event) -> Void,
        onOpenFine: @escaping (Fine) -> Void,
        voteRepo: any VoteRepository,
        userActionRepo: (any UserActionRepository)?,
        onSeeOpenVotes: @escaping () -> Void
    ) {
        self.rulesCoordinator = rulesCoordinator
        self.myFinesCoordinator = myFinesCoordinator
        self.activeGroup = activeGroup
        self.upcomingEvents = upcomingEvents
        self.myRSVPs = myRSVPs
        self.onSwitchGroup = onSwitchGroup
        self.onOpenEvent = onOpenEvent
        self.onOpenFine = onOpenFine
        self.voteRepo = voteRepo
        self.userActionRepo = userActionRepo
        self.onSeeOpenVotes = onSeeOpenVotes
        let resolved = GroupTabView.subTabs(for: activeGroup, hasFines: myFinesCoordinator != nil)
        self._selectedSubTab = State(initialValue: resolved.first ?? .rules)
    }

    var body: some View {
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
                onSeeOpenVotes: onSeeOpenVotes
            )
        case .fines:
            if let coord = myFinesCoordinator {
                MyFinesView(coordinator: coord, onOpenFine: onOpenFine)
            } else {
                EmptyView()
            }
        }
    }

    /// Sub-tabs available based on the group's template. V1 dinner-recurring
    /// has Events + Rules + Fines. Future templates expand this list.
    /// `hasFines` excluye la sub-tab de Multas cuando no hay coordinator.
    static func subTabs(for group: Group, hasFines: Bool = true) -> [GroupSubTab] {
        // V1: assume all templates have events + rules.
        // Future: branch on group.effectiveActiveModules / group.effectiveBaseTemplate.
        var tabs: [GroupSubTab] = [.events, .rules]
        if hasFines && group.finesEnabled {
            tabs.append(.fines)
        }
        return tabs
    }
}

/// Sub-tab inventory for the Grupo tab. Conforms to RuulSubTabItem.
public enum GroupSubTab: String, RuulSubTabItem, CaseIterable {
    case events
    case rules
    case fines

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .events: return "Eventos"
        case .rules:  return "Reglas"
        case .fines:  return "Multas"
        }
    }
}

/// Compacto: lista cronológica de upcoming events del grupo activo.
/// Reusa `EventRow` (Fase 3 lo migró a aceptar `originGroup`).
private struct EventsSubTabContent: View {
    let upcomingEvents: [Event]
    let myRSVPs: [UUID: RSVP]
    let onOpenEvent: (Event) -> Void

    var body: some View {
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

#if DEBUG
#Preview("GroupTabView") {
    Text("GroupTabView preview requires Group + RulesCoordinator + MyFinesCoordinator fixtures — see Showcase.")
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
}
#endif
