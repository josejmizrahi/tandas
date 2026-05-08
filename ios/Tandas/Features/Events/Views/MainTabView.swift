import SwiftUI

/// Top-level tab container shown after onboarding. Sprint 1b expandió de
/// 1 → 4 tabs (Inicio, Inbox, Reglas, Yo). Fase C (DS alignment) reemplaza
/// el chrome de `ResourceTabBar` (TabView default + ultraThinMaterial) por
/// el patrón overlay del DS doc §3.6: TabView nativo invisible
/// (`.toolbar(.hidden, for: .tabBar)`) + `RuulTabBar` capsule glass
/// flotando encima. Esto preserva el state per-tab (cada tab se queda
/// con su `NavigationStack` viva al cambiar) y entrega el look real de
/// Liquid Glass.
struct MainTabView: View {
    @Environment(AppState.self) private var app
    @State private var homeCoordinator: HomeCoordinator?
    @State private var detailRoute: Event?
    @State private var creationRoute: Bool = false
    @State private var pastRoute: Bool = false
    @State private var scannerRoute: CheckInScannerCoordinator?
    @State private var editRoute: Event?
    @State private var memberDirectory: [UUID: MemberWithProfile] = [:]
    @State private var calendarService = CalendarExportService()
    @State private var selectedTab: Tab = .home

    // Sprint 1c: inbox + my-fines coordinators owned at tab root so refresh
    // state survives tab switches. Built lazily once we have a session.
    @State private var inboxCoordinator: InboxCoordinator?
    @State private var myFinesCoordinator: MyFinesCoordinator?
    @State private var profileCoordinator: ProfileCoordinator?
    @State private var rulesCoordinator: RulesCoordinator?
    /// Fase 4b: history es ahora tab top-level. El coordinator se construye
    /// junto al resto en `rebuildCoordinators(for:)` para que el filtro y
    /// la paginación sobrevivan al cambio de tab (antes se construía lazy
    /// adentro de Profile.onOpenHistory).
    @State private var groupHistoryCoordinator: GroupHistoryCoordinator?
    @State private var fineDetailRoute: Fine?
    @State private var reviewProposedRoute: Event?
    @State private var voteOnAppealRoute: AppealRouteContext?
    @State private var feedRoute: Bool = false
    /// Phase G3: route state for `EditRuleSheet` opened pre-loaded from a
    /// `ruleChangeApplyPending` inbox tap or a `RuleChangeDeepLink` push /
    /// universal link. Setting this presents the sheet via `.sheet(item:)`.
    @State private var ruleEditRoute: RuleEditRouteContext?
    /// Push destination state para `RuleDetailView` desde el rule card tap
    /// adentro de `RulesView` (groupTab stack). DS v3 §6.4.
    @State private var ruleDetailRoute: GroupRule?
    /// Pre-selected rule para `CreateRuleChangeSheet` cuando el sheet se
    /// abre desde el botón "Proponer cambio" de `RuleDetailView`. nil
    /// cuando se abre desde el picker general (user pickea adentro).
    @State private var ruleChangeInitialRule: GroupRule?
    /// Phase G2 follow-up: route state for `OpenVotesListView` pushed from
    /// the "Votos abiertos" section of `RulesView`. Post-Fase 4b vive en el
    /// groupTab `NavigationStack` (Rules sub-tab adentro de GroupTabView).
    @State private var openVotesRoute: OpenVotesRouteContext?
    /// Phase G2 follow-up: route state for `VoteDetailView` pushed from a
    /// vote row tap inside `OpenVotesListView` (groupTab stack post-Fase 4b).
    @State private var voteDetailRoute: VoteDetailRouteContext?
    /// Phase G2 follow-up: route state for `VoteDetailView` pushed from un
    /// inbox tap on a `.votePending` action. Post-Fase 4b vive en el homeTab
    /// stack (inbox content embebido en HomeView como sección "Pendientes").
    @State private var voteDetailRouteFromInbox: VoteDetailRouteContext?

    // Fase B: multi-grupo. Three sheets — switcher (lists groups + entry
    // points), create (new group from scratch), join (with invite code).
    @State private var groupSwitcherPresented: Bool = false
    @State private var createGroupPresented: Bool = false
    @State private var joinGroupPresented: Bool = false
    @State private var inviteSharePresented: Bool = false

    // Sprint 3 polish — placeholder handlers wired to real flows.
    /// Picker sheet shown por tap del "+" en OpenVotesListView. Routes a
    /// CreateGeneralProposalSheet o CreateRuleChangeSheet.
    @State private var createVoteSheetPresented: Bool = false
    @State private var createGeneralProposalPresented: Bool = false
    @State private var createRuleChangePresented: Bool = false
    /// Settings → Salir del grupo: tracking del network call para deshabilitar
    /// el botón mientras corre (alert se cierra con tap en "Salir").
    @State private var leaveGroupInProgress: Bool = false

    enum Tab: String, RuulTabItem, CaseIterable {
        case home, group, history, settings

        var id: String { rawValue }
        var label: String {
            switch self {
            case .home:     return "Inicio"
            case .group:    return "Grupo"
            case .history:  return "Historial"
            case .settings: return "Ajustes"
            }
        }
        var symbol: String {
            switch self {
            case .home:     return "house.fill"
            case .group:    return "person.3.fill"
            case .history:  return "clock.arrow.circlepath"
            case .settings: return "gear"
            }
        }
        /// Default `nil` from the protocol extension; runtime badge counts
        /// are projected by `TabBadged` below so the static enum stays pure.
        var badgeCount: Int? { nil }
    }

    /// Runtime wrapper that keeps `Tab`'s identity (`id == rawValue`) but
    /// projects a live `badgeCount` (e.g. inbox `actions.count`). Used as
    /// the `RuulTabItem` passed to `RuulTabBar`; the binding is over
    /// `Tab.ID` (`String`) so the selection round-trips back to the enum.
    private struct TabBadged: RuulTabItem {
        let base: MainTabView.Tab
        let badgeCount: Int?

        var id: String { base.id }
        var label: String { base.label }
        var symbol: String { base.symbol }
    }

    private var tabItems: [TabBadged] {
        Tab.allCases.map { tab in
            TabBadged(
                base: tab,
                badgeCount: tab == .home ? (inboxCoordinator?.actions.count ?? 0) : nil
            )
        }
    }

    /// Native TabView badge for the Home tab (post-Fase 4b: pending inbox
    /// actions surface as a badge on Inicio since Inbox content lives there).
    /// Returns 0 when there's nothing pending — SwiftUI hides the badge when
    /// the count is 0.
    private var inboxBadgeCount: Int {
        inboxCoordinator?.actions.count ?? 0
    }

    /// Binding bridge: `RuulTabBar` works on `Tab.ID` (String); the rest of
    /// the view holds `selectedTab: Tab`. The setter only updates if the
    /// raw value is a known case, so unrelated string mutations are safely
    /// ignored.
    private var selectedTabIDBinding: Binding<String> {
        Binding(
            get: { selectedTab.id },
            set: { newID in
                if let new = Tab(rawValue: newID) { selectedTab = new }
            }
        )
    }

    var body: some View {
        // iOS 26's native TabView already renders a Liquid Glass tab bar.
        // DS doc §3.6 RuulTabBar was specced before iOS 26; under iOS 26 the
        // native bar is the canonical Liquid Glass surface, and overlaying
        // RuulTabBar created a visible duplicate (native bar at the bottom +
        // floating capsule above). Per DS §13 ("La regla produce resultado
        // peor que ignorarla en este caso específico"), we use the native
        // bar with `.tabBarMinimizeBehavior(.onScrollDown)` (iOS 26) and
        // glass material, plus per-tab badges via `.badge(_)`.
        TabView(selection: $selectedTab) {
            homeTab
                .tabItem { Label(Tab.home.label, systemImage: Tab.home.symbol) }
                .tag(Tab.home)
                .badge(inboxBadgeCount)
            groupTab
                .tabItem { Label(Tab.group.label, systemImage: Tab.group.symbol) }
                .tag(Tab.group)
            historyTab
                .tabItem { Label(Tab.history.label, systemImage: Tab.history.symbol) }
                .tag(Tab.history)
            settingsTab
                .tabItem { Label(Tab.settings.label, systemImage: Tab.settings.symbol) }
                .tag(Tab.settings)
        }
        // DS v3 §13.4: tab bar selected-state tint reflects el accent del
        // grupo activo (subtle on-brand cue). Falls back a textPrimary cuando
        // todavía no hay grupo cargado.
        .tint(app.activeGroup?.category.ramp.accent ?? Color.ruulTextPrimary)
        .animation(.ruulGroupSwitch, value: app.activeGroupId)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        // iOS 26 §6.2: tab bar se minimiza al scroll down y re-expande al
        // scroll up. Aprovecha la real estate y evita hide manual.
        .tabBarMinimizeBehavior(.onScrollDown)
        .task { await bootstrap() }
        .onChange(of: app.pendingEventDeepLink) { _, link in
            Task { await handleDeepLink(link) }
        }
        .onChange(of: app.pendingRuleChangeDeepLink) { _, link in
            Task { await handleRuleChangeDeepLink(link) }
        }
        .onChange(of: app.activeGroupId) { _, _ in
            // User switched groups via the group switcher. Rebuild all
            // coordinators so HomeView, Inbox, and Profile/Fines reflect
            // the new group's data.
            Task {
                guard let group = app.activeGroup else { return }
                await rebuildCoordinators(for: group)
            }
        }
        .sheet(isPresented: $groupSwitcherPresented) {
            GroupSwitcherSheet(
                onCreateGroup: { createGroupPresented = true },
                onJoinGroup: { joinGroupPresented = true }
            )
            .environment(app)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $createGroupPresented) {
            CreateGroupSheet { _ in
                // onCreated: AppState already switched activeGroupId; the
                // .onChange hook above rebuilds coordinators automatically.
            }
            .environment(app)
        }
        .sheet(isPresented: $joinGroupPresented) {
            JoinGroupSheet { _ in
                // same: activeGroupId is set inside the sheet, switch is reactive
            }
            .environment(app)
        }
        .sheet(isPresented: $inviteSharePresented) {
            if let group = app.activeGroup {
                GroupInfoSheet(group: group)
                    .environment(app)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(item: $ruleEditRoute, onDismiss: {
            // Phase G3: refresh the inbox so a resolved
            // `ruleChangeApplyPending` row disappears.
            Task { await inboxCoordinator?.refresh() }
        }) { ctx in
            ruleEditSheet(ctx)
        }
    }

    // MARK: - Tabs (v3): Grupo / Historial / Ajustes

    /// Tab "Grupo" — composite con sub-tabs Events/Rules/Fines via `GroupTabView`.
    /// Reemplaza `rulesTab` y absorbe la sub-tab Eventos del antiguo Inicio.
    @ViewBuilder
    private var groupTab: some View {
        NavigationStack {
            SwiftUI.Group {
                if let rulesCoord = rulesCoordinator,
                   let group = app.activeGroup {
                    GroupTabView(
                        rulesCoordinator: rulesCoord,
                        myFinesCoordinator: myFinesCoordinator,
                        activeGroup: group,
                        upcomingEvents: homeCoordinator?.upcomingEvents ?? [],
                        myRSVPs: homeCoordinator?.myRSVPs ?? [:],
                        onSwitchGroup: { groupSwitcherPresented = true },
                        onOpenEvent: { event in detailRoute = event },
                        onOpenFine: { fine in fineDetailRoute = fine },
                        voteRepo: app.voteRepo,
                        userActionRepo: app.userActionRepo,
                        onSeeOpenVotes: {
                            if let g = app.activeGroup {
                                openVotesRoute = OpenVotesRouteContext(id: g.id)
                            }
                        }
                    )
                    .navigationDestination(item: $openVotesRoute) { _ in
                        openVotesDestination
                    }
                    .navigationDestination(item: $voteDetailRoute) { ctx in
                        voteDetailDestination(for: ctx)
                    }
                    .navigationDestination(item: $fineDetailRoute) { fine in
                        fineDetailScreen(fine)
                    }
                } else {
                    ZStack {
                        Color.ruulBackground.ignoresSafeArea()
                        RuulLoadingState()
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// Tab "Historial" — timeline de SystemEvents del grupo activo via
    /// `HistoryTabView`. Antes vivía como push desde Profile.
    @ViewBuilder
    private var historyTab: some View {
        NavigationStack {
            SwiftUI.Group {
                if let coord = groupHistoryCoordinator,
                   let group = app.activeGroup {
                    HistoryTabView(
                        activeGroup: group,
                        onSwitchGroup: { groupSwitcherPresented = true },
                        coordinator: coord
                    )
                } else {
                    ZStack {
                        Color.ruulBackground.ignoresSafeArea()
                        RuulLoadingState()
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// Tab "Ajustes" — dual scope (cuenta global + este grupo) via
    /// `SettingsTabView`. `onOpenHistory` ahora salta a la tab Historial
    /// directamente en lugar de pushear adentro de la stack de Ajustes.
    @ViewBuilder
    private var settingsTab: some View {
        NavigationStack {
            SwiftUI.Group {
                if let pCoord = profileCoordinator,
                   let group = app.activeGroup {
                    SettingsTabView(
                        activeGroup: group,
                        onSwitchGroup: { groupSwitcherPresented = true },
                        profileCoordinator: pCoord,
                        onOpenMyFines: { myFinesRoute = true },
                        onOpenHistory: { selectedTab = .history },
                        onOpenSettings: { settingsRoute = true },
                        onEditProfile: { editProfilePresented = true },
                        onSignOut: {
                            Task { try? await app.auth.signOut() }
                        },
                        onOpenMembers: { membersSheetPresented = true },
                        onOpenGovernance: { /* Fase 6 placeholder */ },
                        onLeaveGroup: { leaveGroupConfirmation = true }
                    )
                    .navigationDestination(isPresented: $myFinesRoute) {
                        if let fCoord = myFinesCoordinator {
                            MyFinesView(coordinator: fCoord) { fine in
                                fineDetailRoute = fine
                            }
                        }
                    }
                    .navigationDestination(item: $fineDetailRoute) { fine in
                        fineDetailScreen(fine)
                    }
                    .sheet(isPresented: $settingsRoute) {
                        SettingsSheet()
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                    }
                    .sheet(isPresented: $editProfilePresented, onDismiss: {
                        Task { await profileCoordinator?.refresh() }
                    }) {
                        if let pCoord = profileCoordinator {
                            EditProfileSheet(coordinator: pCoord)
                                .presentationDetents([.medium, .large])
                                .presentationDragIndicator(.visible)
                        }
                    }
                    .sheet(isPresented: $membersSheetPresented) {
                        if let activeGroup = app.activeGroup {
                            EditMembersSheet(group: activeGroup)
                                .environment(app)
                                .presentationDetents([.large])
                                .presentationDragIndicator(.visible)
                        }
                    }
                    .alert("¿Salir del grupo?", isPresented: $leaveGroupConfirmation) {
                        Button("Cancelar", role: .cancel) {}
                        Button("Salir", role: .destructive) {
                            Task { await leaveActiveGroup() }
                        }
                        .disabled(leaveGroupInProgress)
                    } message: {
                        Text("Esta acción es permanente. Solo el founder puede agregarte de vuelta.")
                    }
                } else {
                    ProfileTabStub()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    @ViewBuilder
    private var openVotesDestination: some View {
        if let group = app.activeGroup {
            OpenVotesListView(
                coordinator: OpenVotesCoordinator(
                    group: group,
                    voteRepo: app.voteRepo
                ),
                onSelectVote: { vote in
                    voteDetailRoute = VoteDetailRouteContext(vote: vote)
                },
                onCreateVote: { createVoteSheetPresented = true }
            )
            .sheet(isPresented: $createVoteSheetPresented) {
                CreateVoteSheet(
                    onPickGeneralProposal: { createGeneralProposalPresented = true },
                    onPickRuleChange: { createRuleChangePresented = true }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $createGeneralProposalPresented, onDismiss: {
                Task { await rulesCoordinator?.refresh() }
            }) {
                if let member = currentGroupMember(in: group) {
                    CreateGeneralProposalSheet(
                        coordinator: CreateGeneralProposalCoordinator(
                            group: group,
                            member: member,
                            voteRepo: app.voteRepo,
                            governance: app.governance
                        ),
                        onCreated: { _ in
                            Task { await rulesCoordinator?.refresh() }
                        }
                    )
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                }
            }
            .sheet(isPresented: $createRuleChangePresented, onDismiss: {
                Task { await rulesCoordinator?.refresh() }
            }) {
                if let member = currentGroupMember(in: group) {
                    CreateRuleChangeSheet(
                        coordinator: CreateRuleChangeCoordinator(
                            group: group,
                            member: member,
                            availableRules: rulesCoordinator?.rules ?? [],
                            voteRepo: app.voteRepo,
                            governance: app.governance
                        ),
                        onCreated: { _ in
                            Task { await rulesCoordinator?.refresh() }
                        }
                    )
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                }
            }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func voteDetailDestination(for ctx: VoteDetailRouteContext) -> some View {
        if let group = app.activeGroup,
           let userMemberId = resolveUserMemberId(in: group) {
            VoteDetailView(
                coordinator: VoteDetailCoordinator(
                    vote: ctx.vote,
                    group: group,
                    userMemberId: userMemberId,
                    voteRepo: app.voteRepo,
                    castRepo: app.voteCastRepo,
                    analytics: app.analytics
                )
            )
        } else {
            EmptyView()
        }
    }

    /// Resolve the current user's `group_members.id` for the given group via
    /// the cached `memberDirectory` populated on tab bootstrap. Returns nil
    /// if the directory hasn't surfaced the row yet (rare edge — caller
    /// renders EmptyView in that case).
    /// Resuelve el `Member` row del usuario actual en el grupo dado, vía
    /// el directorio cacheado por `refreshMemberDirectory(for:)`. Devuelve
    /// nil si todavía no hidrato — caller renderiza no-op.
    private func currentGroupMember(in group: Group) -> Member? {
        guard let userId = app.session?.user.id else { return nil }
        return memberDirectory[userId]?.member
    }

    /// Soft-leave: marca al user como `active = false` en `group_members`
    /// vía `GroupsRepository.leave(_:)`. Después refresca AppState.groups
    /// para que el switcher reciba la lista actualizada — `activeGroup`
    /// auto-resuelve a `groups.first` si el active queda stale.
    private func leaveActiveGroup() async {
        guard !leaveGroupInProgress, let group = app.activeGroup else { return }
        leaveGroupInProgress = true
        defer { leaveGroupInProgress = false }
        do {
            try await app.groupsRepo.leave(group.id)
            await app.refreshProfileAndGroups()
            // Si el grupo activo persiste por estado stale, resetear al primero.
            if app.groups.first(where: { $0.id == group.id }) == nil {
                app.activeGroupId = app.groups.first?.id
            }
            selectedTab = .home
        } catch {
            // No tracked-error path por ahora; en V2 mostrar toast.
            // Coordinator-level errors (que sí muestran retry) pertenecen al
            // refresh subsequent — aquí dejamos fallar silenciosamente porque
            // la operación es intencional del user y el rebuild de
            // coordinators ya hace defensive reload via .onChange.
        }
    }

    private func resolveUserMemberId(in group: Group) -> UUID? {
        guard let userId = app.session?.user.id else { return nil }
        return memberDirectory[userId]?.member.id
    }

    @State private var myFinesRoute: Bool = false
    @State private var settingsRoute: Bool = false
    /// Sheet for `EditProfileSheet` (Settings → "Editar perfil"). Refresca el
    /// ProfileCoordinator on dismiss para que el displayName actualizado se
    /// propague al hero, greeting de Home, etc.
    @State private var editProfilePresented: Bool = false
    /// Fase 5: route state para `EditMembersSheet` (Settings → Este grupo →
    /// Miembros) y la alerta de "Salir del grupo" (placeholder, RPC futuro).
    @State private var membersSheetPresented: Bool = false
    @State private var leaveGroupConfirmation: Bool = false

    @ViewBuilder
    private var feedScreen: some View {
        MyFeedView(
            coordinator: MyFeedCoordinator(
                eventRepo: app.eventRepo,
                groupsRepo: app.groupsRepo
            )
        ) { event, group in
            // Switch active group then open the event detail. The
            // didSet on activeGroupId triggers coordinator rebuild.
            app.activeGroupId = group.id
            feedRoute = false
            detailRoute = event
        }
    }

    private func fineDetailScreen(_ fine: Fine) -> some View {
        let coord = FineDetailCoordinator(
            fine: fine,
            userId: app.session?.user.id ?? UUID(),
            fineRepo: app.fineRepo,
            appealRepo: app.appealRepo,
            analytics: app.analytics
        )
        let userId = app.session?.user.id ?? UUID()
        let governance = app.governance
        let fineRepo = app.fineRepo
        let groupsRepo = app.groupsRepo
        let groups = app.groups

        return FineDetailView(
            coordinator: coord,
            onAppeal: nil,
            onViewAppeal: { appeal in
                voteOnAppealRoute = AppealRouteContext(appeal: appeal, fine: fine)
            },
            computeCanVoidFine: {
                guard let group = groups.first(where: { $0.id == fine.groupId }) else { return false }
                do {
                    let rows = try await groupsRepo.membersWithProfiles(of: fine.groupId)
                    let me = rows.first(where: { $0.member.userId == userId })?.member
                        ?? Member(
                            id: UUID(),
                            groupId: fine.groupId,
                            userId: userId,
                            role: "member",
                            roles: [.member],
                            active: false,
                            joinedAt: .now
                        )
                    let decision = try await governance.canPerform(
                        .voidFine,
                        member: me,
                        in: group,
                        context: nil
                    )
                    if case .allowed = decision { return true }
                    return false
                } catch {
                    return false
                }
            },
            makeVoidFineCoordinator: {
                // Captures `coord` lexically — when void succeeds, onSubmitted
                // refreshes FineDetailCoordinator so the View re-renders the new
                // state (status pill, hidden buttons, ANULADA section) before
                // the sheet closes.
                VoidFineCoordinator(
                    fine: fine,
                    fineRepo: fineRepo,
                    groupsRepo: groupsRepo,
                    onSubmitted: { await coord.refresh() }
                )
            },
            currentUserId: userId
        )
    }

    private func reviewProposedScreen(_ event: Event) -> some View {
        let coord = ReviewProposedFinesCoordinator(event: event, fineRepo: app.fineRepo)
        return ReviewProposedFinesView(
            coordinator: coord,
            memberLookup: { userId in
                memberDirectory[userId]?.displayName ?? "Miembro"
            },
            onSelectFine: { fine in
                fineDetailRoute = fine
            }
        )
    }

    @ViewBuilder
    private func voteOnAppealSheet(_ ctx: AppealRouteContext) -> some View {
        // Resolve appellant name from the directory if we have it
        let appellantName: String = {
            // appeal.appellantMemberId is a group_members.id; look up via directory
            if let entry = memberDirectory.values.first(where: { $0.member.id == ctx.appeal.appellantMemberId }) {
                return entry.displayName
            }
            return "Un miembro"
        }()
        VoteOnAppealSheet(
            isPresented: voteOnAppealBinding,
            fine: ctx.fine,
            appeal: ctx.appeal,
            appellantName: appellantName,
            voteCounts: nil
        ) { choice in
            Task {
                try? await app.appealRepo.castVote(appealId: ctx.appeal.id, choice: choice)
                await inboxCoordinator?.refresh()
            }
        }
    }

    private var voteOnAppealBinding: Binding<Bool> {
        Binding(
            get: { voteOnAppealRoute != nil },
            set: { if !$0 { voteOnAppealRoute = nil } }
        )
    }

    /// Routing: ActionType → which screen / sheet to open.
    @MainActor
    private func handleInboxAction(_ action: UserAction) async {
        // 14.2 — Inbox is cross-group; if the action's group isn't the
        // currently active one, switch before opening the detail. This
        // triggers AppState.activeGroupId.didSet which rebuilds tab
        // coordinators, so by the time we set the route the home/fines
        // contexts already match.
        if app.activeGroup?.id != action.groupId {
            app.activeGroupId = action.groupId
        }

        switch action.actionType {
        case .finePending:
            if let fine = try? await app.fineRepo.fine(id: action.referenceId) {
                fineDetailRoute = fine
            }
        case .fineVoided:
            if let fine = try? await app.fineRepo.fine(id: action.referenceId) {
                fineDetailRoute = fine
            }
        case .fineProposalReview:
            if let event = try? await app.eventRepo.event(action.referenceId) {
                reviewProposedRoute = event
            }
        case .appealVotePending:
            if let appeal = try? await app.appealRepo.appeal(id: action.referenceId),
               let fine = try? await app.fineRepo.fine(id: appeal.fineId) {
                voteOnAppealRoute = AppealRouteContext(appeal: appeal, fine: fine)
            }
        case .rsvpPending:
            if let event = try? await app.eventRepo.event(action.referenceId) {
                detailRoute = event
                selectedTab = .home
            }
        case .ruleChangeApplyPending:
            // Phase G3: action.referenceId === vote_id (see migration 00032).
            // Load vote → extract rule_id (vote.referenceId) + proposed
            // amount (vote.payload.proposed_amount), then locate the rule
            // and present `EditRuleSheet` pre-loaded with both the
            // proposedAmount and the originating action id (so saving
            // resolves the inbox row).
            await openRuleEditFromInbox(action: action)
        case .votePending:
            // action.referenceId is the vote id (see system events emitter
            // for `votePending`). Push VoteDetailView on the inbox stack.
            if let vote = try? await app.voteRepo.vote(id: action.referenceId) {
                voteDetailRouteFromInbox = VoteDetailRouteContext(vote: vote)
            }
        case .slotPending, .contributionDue, .compensationDue:
            // Not used by V1 template — no-op for now.
            break
        }
    }

    @ViewBuilder
    private var homeTab: some View {
        NavigationStack {
            SwiftUI.Group {
                if let coord = homeCoordinator {
                    HomeView(
                        coordinator: coord,
                        inboxCoordinator: inboxCoordinator,
                        onInboxActionTap: { action in
                            await handleInboxAction(action)
                        },
                        userId: app.session?.user.id ?? UUID(),
                        onCreateEvent: { creationRoute = true },
                        onOpenEvent: { event in detailRoute = event },
                        onOpenPastEvents: { pastRoute = true },
                        onInvitePeople: { inviteSharePresented = true }
                    )
                    .navigationDestination(isPresented: $pastRoute) {
                        if let group = app.activeGroup {
                            PastEventsView(
                                group: group,
                                userId: app.session?.user.id ?? UUID(),
                                eventRepo: app.eventRepo
                            ) { event in detailRoute = event }
                        }
                    }
                    .navigationDestination(isPresented: $feedRoute) {
                        feedScreen
                    }
                    // Fase 4b: route destinations migradas desde inboxTab.
                    // Inbox content vive en HomeView ahora (sección "Pendientes")
                    // así que sus pushes resuelven en este NavigationStack.
                    .navigationDestination(item: $fineDetailRoute) { fine in
                        fineDetailScreen(fine)
                    }
                    .navigationDestination(item: $reviewProposedRoute) { event in
                        reviewProposedScreen(event)
                    }
                    .navigationDestination(item: $voteDetailRouteFromInbox) { ctx in
                        voteDetailDestination(for: ctx)
                    }
                    .ruulSheet(item: $voteOnAppealRoute) { ctx in
                        voteOnAppealSheet(ctx)
                    }
                    .fullScreenCover(item: $detailRoute) { event in
                        eventDetailScreen(event)
                    }
                    .fullScreenCover(isPresented: $creationRoute) {
                        eventCreationScreen
                    }
                    .onChange(of: creationRoute) { wasOpen, isOpen in
                        // Refresh on cover dismissal regardless of source.
                        // Refreshing inside the dismissed subview's onChange races
                        // with view teardown and sometimes drops the Task.
                        if wasOpen && !isOpen {
                            Task { await homeCoordinator?.refresh(force: true) }
                        }
                    }
                    .fullScreenCover(item: $scannerRoute) { scannerCoord in
                        CheckInScannerView(coordinator: scannerCoord)
                    }
                    .fullScreenCover(item: $editRoute) { event in
                        eventEditScreen(event)
                    }
                } else {
                    ZStack {
                        Color.ruulBackground.ignoresSafeArea()
                        RuulLoadingState()
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func eventDetailScreen(_ event: Event) -> some View {
        guard let group = app.groups.first(where: { $0.id == event.groupId }) else {
            return AnyView(EmptyView())
        }
        let userId = app.session?.user.id ?? UUID()
        let coord = EventDetailCoordinator(
            event: event,
            group: group,
            userId: userId,
            eventRepo: app.eventRepo,
            rsvpRepo: app.rsvpRepo,
            checkInRepo: app.checkInRepo,
            lifecycle: app.eventLifecycle,
            notifications: app.notifications,
            walletService: app.walletService,
            analytics: EventAnalytics(analytics: app.analytics),
            realtimeFactory: app.realtimeFactory,
            systemEvents: app.systemEventEmitter
        )
        let governance = app.governance
        let fineRepo = app.fineRepo
        let groupsRepo = app.groupsRepo
        let memberDirectorySnapshot = memberDirectory

        return AnyView(
            EventDetailView(
                coordinator: coord,
                memberLookup: lookupMember,
                onScannerOpen: { openScanner(for: coord) },
                calendarService: calendarService,
                onEdit: { editRoute = coord.event },
                computeCanIssueManualFine: {
                    let me = memberDirectorySnapshot[userId]?.member
                        ?? Self.fallbackMember(userId: userId, groupId: group.id)
                    do {
                        let decision = try await governance.canPerform(
                            .issueManualFine,
                            member: me,
                            in: group,
                            context: nil
                        )
                        if case .allowed = decision { return true }
                        return false
                    } catch {
                        return false
                    }
                },
                makeAddManualFineCoordinator: {
                    AddManualFineCoordinator(
                        groupId: group.id,
                        eventId: event.id,
                        fineRepo: fineRepo,
                        groupsRepo: groupsRepo
                    )
                },
                currentUserId: userId
            )
        )
    }

    @ViewBuilder
    private func eventEditScreen(_ event: Event) -> some View {
        if let group = app.groups.first(where: { $0.id == event.groupId }) {
            let editCoord = EventEditCoordinator(
                event: event,
                group: group,
                eventRepo: app.eventRepo,
                analytics: EventAnalytics(analytics: app.analytics)
            )
            EditEventView(coordinator: editCoord)
                .onChange(of: editCoord.updatedEvent) { _, newValue in
                    guard newValue != nil else { return }
                    Task {
                        await homeCoordinator?.refresh(force: true)
                        // Refresh the detail route so the open detail view
                        // picks up the new event payload on next render.
                        if let updated = newValue {
                            detailRoute = updated
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var eventCreationScreen: some View {
        if let group = app.activeGroup {
            let suggested = nextDefaultDate(for: group)
            let creation = EventCreationCoordinator(
                group: group,
                hasExistingEvents: !(homeCoordinator?.upcomingEvents.isEmpty ?? true),
                suggestedDate: suggested,
                eventRepo: app.eventRepo,
                lifecycle: app.eventLifecycle,
                analytics: EventAnalytics(analytics: app.analytics)
            )
            CreateEventView(coordinator: creation)
                .onChange(of: creation.createdEvent) { _, newValue in
                    guard newValue != nil else { return }
                    Task { await homeCoordinator?.refresh(force: true) }
                }
        }
    }

    private func openScanner(for detail: EventDetailCoordinator) {
        let confirmed = detail.rsvps.filter { $0.status == .going }
        let alreadyChecked = confirmed.filter { $0.isCheckedIn }.count
        let scanner = QRScannerService()
        let coord = CheckInScannerCoordinator(
            event: detail.event,
            totalConfirmed: confirmed.count,
            alreadyCheckedCount: alreadyChecked,
            scanner: scanner,
            checkInRepo: app.checkInRepo,
            analytics: EventAnalytics(analytics: app.analytics),
            memberLookup: { [memberDirectory] id in
                memberDirectory[id]?.displayName ?? "Miembro"
            }
        )
        scannerRoute = coord
    }

    /// Resolve a member's display info from the cached directory. Returns
    /// "Miembro" + nil avatar for unknowns (e.g., a member just added that
    /// the directory hasn't refreshed yet).
    private func lookupMember(_ userId: UUID) -> (name: String, avatarURL: URL?) {
        guard let mwp = memberDirectory[userId] else {
            return (name: "Miembro", avatarURL: nil)
        }
        return (name: mwp.displayName, avatarURL: mwp.avatarURL)
    }

    private func nextDefaultDate(for group: Group) -> Date {
        // Default: tomorrow at 20:30 if group has no frequency.
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
        var comps = calendar.dateComponents([.year, .month, .day], from: tomorrow)
        comps.hour = group.frequencyConfig?.hour ?? 20
        comps.minute = group.frequencyConfig?.minute ?? 30
        return calendar.date(from: comps) ?? tomorrow
    }

    @MainActor
    private func bootstrap() async {
        guard let group = app.activeGroup else { return }
        // Initial wire-up. Rebuild on active-group change is handled by the
        // .onChange(of: app.activeGroupId) hook in the body.
        if homeCoordinator?.group.id != group.id {
            await rebuildCoordinators(for: group)
        }
    }

    @MainActor
    private func rebuildCoordinators(for group: Group) async {
        let userId = app.session?.user.id ?? UUID()
        homeCoordinator = HomeCoordinator(
            group: group,
            allGroups: app.groups,
            userId: userId,
            eventRepo: app.eventRepo,
            rsvpRepo: app.rsvpRepo
        )
        inboxCoordinator = InboxCoordinator(
            userId: userId,
            groupId: nil,                   // 14.2 — cross-group inbox
            userActionRepo: app.userActionRepo,
            groupsRepo: app.groupsRepo
        )
        myFinesCoordinator = MyFinesCoordinator(
            userId: userId,
            fineRepo: app.fineRepo,
            groupsRepo: app.groupsRepo
        )
        profileCoordinator = ProfileCoordinator(
            userId: userId,
            profileRepo: app.profileRepo,
            fineRepo: app.fineRepo
        )
        // Load member directory before RulesCoordinator so we can hand it
        // the current actor's `Member` row for the governance check.
        await refreshMemberDirectory(for: group.id)
        let currentMember = memberDirectory[userId]?.member
            ?? Self.fallbackMember(userId: userId, groupId: group.id)
        rulesCoordinator = RulesCoordinator(
            group: group,
            currentMember: currentMember,
            governance: app.governance,
            ruleRepo: app.ruleRepo,
            voteRepo: app.voteRepo
        )
        // Fase 4b: history es tab top-level. Construimos su coordinator en el
        // mismo rebuild para que el cambio de grupo refresque el filtro.
        groupHistoryCoordinator = GroupHistoryCoordinator(
            groupId: group.id,
            repo: app.systemEventRepo
        )
    }

    /// Synthetic inactive member used when the directory hasn't surfaced
    /// the current user yet (anon sessions, just-joined races). Forces the
    /// fail-closed governance gate to deny — the pencil stays hidden until
    /// the next directory refresh promotes the row.
    private static func fallbackMember(userId: UUID, groupId: UUID) -> Member {
        Member(
            id: UUID(),
            groupId: groupId,
            userId: userId,
            role: "member",
            roles: [.member],
            active: false,
            joinedAt: .now
        )
    }

    /// Fetch member+profile pairs once and cache by userId. Refresh whenever
    /// the active group changes or a refresh is forced from elsewhere.
    @MainActor
    private func refreshMemberDirectory(for groupId: UUID) async {
        guard let rows = try? await app.groupsRepo.membersWithProfiles(of: groupId) else { return }
        var directory: [UUID: MemberWithProfile] = [:]
        for row in rows {
            directory[row.member.userId] = row
        }
        memberDirectory = directory
    }

    @MainActor
    private func handleDeepLink(_ link: EventDeepLink?) async {
        guard let link else { return }
        if let event = try? await app.eventRepo.event(link.eventId) {
            detailRoute = event
        }
        app.consumeEventDeepLink()
    }

    // MARK: - Rule change deep link / inbox routing (Phase G3)

    /// Builds the sheet for `ruleEditRoute`. Constructs a fresh
    /// `EditRulesCoordinator` scoped to the route's group so the rule list
    /// + governance gate match. The `prefilledAmount` skips the empty seed
    /// path; `pendingActionId` causes Save to resolve the inbox row.
    @ViewBuilder
    private func ruleEditSheet(_ ctx: RuleEditRouteContext) -> some View {
        let userId = app.session?.user.id ?? UUID()
        let currentMember = memberDirectory[userId]?.member
            ?? Self.fallbackMember(userId: userId, groupId: ctx.group.id)
        let editCoord = EditRulesCoordinator(
            group: ctx.group,
            currentMember: currentMember,
            governance: app.governance,
            ruleRepo: app.ruleRepo,
            voteRepo: app.voteRepo,
            userActionRepo: app.userActionRepo
        )
        NavigationStack {
            EditRuleSheet(
                rule: ctx.rule,
                pending: nil,
                prefilledAmount: ctx.proposedAmount,
                pendingActionId: ctx.pendingActionId,
                coordinator: editCoord,
                onDismiss: { ruleEditRoute = nil }
            )
        }
    }

    /// Inbox tap on `.ruleChangeApplyPending`. Loads the vote (referenced
    /// by `action.referenceId`), pulls the proposed amount from
    /// `vote.payload`, switches active group if needed, locates the rule
    /// by id, and presents `EditRuleSheet` pre-loaded.
    @MainActor
    private func openRuleEditFromInbox(action: UserAction) async {
        guard let vote = try? await app.voteRepo.vote(id: action.referenceId) else { return }
        guard case .object(let payload) = vote.payload,
              case .int(let proposedAmount) = payload["proposed_amount"] ?? .null
        else { return }

        let ruleId = vote.referenceId
        // Active group is already switched in `handleInboxAction` before
        // this method is called (`if app.activeGroup?.id != action.groupId`),
        // so we just need the Group instance for the sheet builder.
        guard let group = app.groups.first(where: { $0.id == action.groupId }) else { return }

        guard let rules = try? await app.ruleRepo.list(groupId: group.id),
              let rule = rules.first(where: { $0.id == ruleId })
        else { return }

        ruleEditRoute = RuleEditRouteContext(
            rule: rule,
            group: group,
            proposedAmount: proposedAmount,
            pendingActionId: action.id
        )
    }

    /// Push / Universal Link entry. Same end state as the inbox path but
    /// the action id is unknown — the inbox refresh on dismiss will reap
    /// any resolved-server-side row regardless. Iterates the user's groups
    /// and asks each `ruleRepo.list(...)` until one returns the rule id;
    /// silently no-ops if none match (rule archived, group left, etc.).
    @MainActor
    private func handleRuleChangeDeepLink(_ link: RuleChangeDeepLink?) async {
        guard let link else { return }
        defer { app.consumeRuleChangeDeepLink() }

        for group in app.groups {
            guard let rules = try? await app.ruleRepo.list(groupId: group.id),
                  let rule = rules.first(where: { $0.id == link.ruleId })
            else { continue }

            // Switch active group if this rule lives elsewhere.
            if app.activeGroup?.id != group.id {
                app.activeGroupId = group.id
            }
            ruleEditRoute = RuleEditRouteContext(
                rule: rule,
                group: group,
                proposedAmount: link.proposedAmount,
                pendingActionId: nil
            )
            return
        }
    }
}

// MARK: - Route context wrappers

/// Identifiable wrapper for `EditRuleSheet` route state. Combines the
/// resolved rule + group + (optional) deep-link-supplied proposed amount
/// so the sheet can pre-load draftAmount in one render. `pendingActionId`
/// is non-nil only on the inbox-tap path; nil on push / URL deep-links y
/// en el flow desde `RuleDetailView` (donde no hay action que resolver).
/// `proposedAmount` es nil cuando el push viene desde el detail view (el
/// sheet siembra con el flat actual de la rule).
struct RuleEditRouteContext: Identifiable, Hashable {
    let rule: GroupRule
    let group: Group
    let proposedAmount: Int?
    let pendingActionId: UUID?
    var id: UUID { rule.id }
}

/// Identifiable wrapper for the `OpenVotesListView` push destination on
/// the groupTab stack (post-Fase 4b). The id is the active group's id so
/// SwiftUI rebuilds the destination on group switch.
struct OpenVotesRouteContext: Identifiable, Hashable {
    let id: UUID
}

/// Identifiable wrapper for the `VoteDetailView` push destination. Post-Fase
/// 4b vive en groupTab stack (vote-row tap from `OpenVotesListView`) y en
/// homeTab stack (`.votePending` desde sección Pendientes). Identity es vote id.
struct VoteDetailRouteContext: Identifiable, Hashable {
    let vote: Vote
    var id: UUID { vote.id }

    func hash(into hasher: inout Hasher) {
        hasher.combine(vote.id)
    }
    static func == (lhs: VoteDetailRouteContext, rhs: VoteDetailRouteContext) -> Bool {
        lhs.vote.id == rhs.vote.id
    }
}

// CheckInScannerCoordinator must be Identifiable for fullScreenCover(item:).
extension CheckInScannerCoordinator: Identifiable {
    nonisolated var id: UUID { event.id }
}

// Wrapper used by ruulSheet(item:) when routing the appellant vote screen.
struct AppealRouteContext: Identifiable, Hashable {
    let appeal: Appeal
    let fine: Fine
    var id: UUID { appeal.id }
}
