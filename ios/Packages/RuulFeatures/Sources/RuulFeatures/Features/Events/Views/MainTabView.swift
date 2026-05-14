import SwiftUI
import RuulUI
import RuulCore

/// Top-level tab container shown after onboarding. Tabs (Inicio, Grupo,
/// Historial, Ajustes) corresponden al patrón híbrido de scope DS v3 §4.2.
///
/// Chrome: iOS 26 native TabView. La razón está dentro del `body` (líneas
/// ~150): `RuulTabBar` overlay produjo un duplicate visual (native bar +
/// floating capsule) bajo iOS 26, así que la canonical Liquid Glass surface
/// es el TabView nativo + `.tabBarMinimizeBehavior(.onScrollDown)`. La
/// `.tint(...)` aplica el accent del grupo activo (DS §13.4).
public struct MainTabView: View {
    public init() {}

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
    /// Bumped after the ResourceWizard creates a non-event resource so
    /// HomeView's nonEventResources section re-fetches via .task(id:).
    @State private var resourceRefreshToken: UUID = UUID()

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
    /// Push GroupHistoryView desde Grupo → Más → "Historial del grupo".
    /// AppShell.md: Actividad ya no es tab top-level — vive como linkout
    /// adentro de Grupo para no competir con el dashboard de Resumen.
    @State private var groupHistoryRoute: Bool = false
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

    /// G1: "Más → Acuerdos" push. Routes a la lista completa de reglas
    /// (RulesView) en el groupTab stack.
    @State private var acuerdosRoute: Bool = false
    /// G1: "Más → Sanciones" push. Routes a `MyFinesView` en el groupTab stack.
    @State private var sancionesRoute: Bool = false
    @State private var groupRulesSettingsPresented: Bool = false

    // Fase B: multi-grupo. Three sheets — switcher (lists groups + entry
    // points), create (new group from scratch), join (with invite code).
    @State private var groupSwitcherPresented: Bool = false
    @State private var createGroupPresented: Bool = false
    @State private var joinGroupPresented: Bool = false
    @State private var inviteSharePresented: Bool = false
    /// Cached `member.invite` policy decision for the active group.
    /// Refreshed on group switch via `.task(id:)`. The Inicio header
    /// "Invitar gente" icon hides when this is false — direct +
    /// admin_only-with-permission resolve to true; everything else
    /// (admin_only-without-permission, vote_required, denied) hides
    /// the affordance entirely.
    @State private var canInviteMembers: Bool = false

    // Sprint 3 polish — placeholder handlers wired to real flows.
    /// Picker sheet shown por tap del "+" en OpenVotesListView. Routes a
    /// CreateGeneralProposalSheet o CreateRuleChangeSheet.
    @State private var createVoteSheetPresented: Bool = false
    @State private var createGeneralProposalPresented: Bool = false
    @State private var createRuleChangePresented: Bool = false
    /// Settings → Salir del grupo: tracking del network call para deshabilitar
    /// el botón mientras corre (alert se cierra con tap en "Salir").
    @State private var leaveGroupInProgress: Bool = false

    public enum Tab: String, RuulTabItem, CaseIterable {
        case home, group, create, decisions, profile

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .home:      return "Inicio"
            case .group:     return "Grupo"
            case .create:    return "Crear"
            case .decisions: return "Decisiones"
            case .profile:   return "Perfil"
            }
        }
        public var symbol: String {
            switch self {
            case .home:      return "house.fill"
            case .group:     return "person.3.fill"
            case .create:    return "plus.circle.fill"
            case .decisions: return "hand.raised.fill"
            case .profile:   return "person.crop.circle.fill"
            }
        }
        /// Default `nil` from the protocol extension; runtime badge counts
        /// are projected by `TabBadged` below so the static enum stays pure.
        public var badgeCount: Int? { nil }
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

    /// Native TabView badge for the Home tab (Pendientes folded in).
    /// Returns 0 when there's nothing pending — SwiftUI hides the badge.
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

    /// Selection binding for the native TabView. When the user picks the
    /// `.create` tab, the setter doesn't update `selectedTab` — instead it
    /// flips `creationRoute` so the ResourceWizard cover (declared at body
    /// level) presents. The previously-selected tab stays highlighted, so
    /// dismissing the wizard returns the user to where they were.
    private var createTabIntercept: Binding<Tab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                if newTab == .create {
                    // Beta 1 W3 A-3.4: with no active group the only thing
                    // "+" can usefully mean is "create your first group".
                    // The previous behavior was a silent no-op — user
                    // tapped "+", nothing happened, no feedback. Now we
                    // route them to CreateGroupSheet (already wired
                    // below via `createGroupPresented`).
                    if app.activeGroup != nil {
                        creationRoute = true
                    } else {
                        createGroupPresented = true
                    }
                    // intentionally leave selectedTab as-is
                } else {
                    selectedTab = newTab
                }
            }
        )
    }

    public var body: some View {
        // iOS 26's native TabView already renders a Liquid Glass tab bar.
        // The "+" sits inline as a real tab item between Grupo and Historial.
        // Tapping it doesn't navigate — `createTabIntercept` catches the
        // selection, reverts it, and presents the ResourceWizard cover.
        TabView(selection: createTabIntercept) {
            homeTab
                .tabItem { Label(Tab.home.label, systemImage: Tab.home.symbol) }
                .tag(Tab.home)
                .badge(inboxBadgeCount) // Pendientes folded into Home
            groupTab
                .tabItem { Label(Tab.group.label, systemImage: Tab.group.symbol) }
                .tag(Tab.group)
            // The "+" tab. Its body is never shown (selection intercept
            // immediately reverts before the TabView swaps content), but
            // a tab item still needs a destination view to register.
            Color.clear
                .tabItem { Label(Tab.create.label, systemImage: Tab.create.symbol) }
                .tag(Tab.create)
            decisionsTab
                .tabItem { Label(Tab.decisions.label, systemImage: Tab.decisions.symbol) }
                .tag(Tab.decisions)
            profileTab
                .tabItem { Label(Tab.profile.label, systemImage: Tab.profile.symbol) }
                .tag(Tab.profile)
        }
        // DS v3 §13.4: tab bar selected-state tint reflects el accent del
        // grupo activo (subtle on-brand cue). Falls back a textPrimary cuando
        // todavía no hay grupo cargado.
        .tint(app.activeGroup?.category.ramp.accent ?? Color.ruulTextPrimary)
        .animation(.ruulGroupSwitch, value: app.activeGroupId)
        // DS v3 §13.2: el TabView nativo de iOS 26 ya renderiza Liquid Glass
        // por default. Aplicar `.toolbarBackground(.ultraThinMaterial, ...)`
        // overridería ese glass con un material plano — antipatrón explícito.
        // iOS 26 §6.2: tab bar se minimiza al scroll down y re-expande al
        // scroll up. Aprovecha la real estate y evita hide manual.
        .tabBarMinimizeBehavior(.onScrollDown)
        .task { await bootstrap() }
        .task(id: app.activeGroup?.id) {
            // Resolves member.invite for the active group so the Inicio
            // header icon shows / hides based on policy. Re-runs on every
            // group switch.
            await refreshCanInviteMembers()
        }
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
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $joinGroupPresented) {
            JoinGroupSheet { _ in
                // same: activeGroupId is set inside the sheet, switch is reactive
            }
            .environment(app)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $inviteSharePresented) {
            if let group = app.activeGroup {
                GroupInfoSheet(group: group)
                    .environment(app)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $groupRulesSettingsPresented) {
            if let group = app.activeGroup {
                GroupRulesSettingsView(coordinator: GroupRulesCoordinator(
                    group: group,
                    actorUserId: app.session?.user.id ?? UUID(),
                    policyRepo: app.policyRepo
                ))
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
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // Universal create wizard cover. Lives at body level (not inside
        // homeTab) so the "+" works from any tab — Inicio / Grupo /
        // Historial / Ajustes all present the same wizard.
        .fullScreenCover(isPresented: $creationRoute) {
            eventCreationScreen
        }
        .onChange(of: creationRoute) { wasOpen, isOpen in
            // Refresh on cover dismissal regardless of source tab.
            if wasOpen && !isOpen {
                Task {
                    async let h: Void = homeCoordinator?.refresh(force: true) ?? ()
                    async let g: Void? = groupHistoryCoordinator?.refresh()
                    _ = await (h, g)
                }
            }
        }
    }

    // MARK: - Tabs (v3): Grupo / Historial / Ajustes

    /// Tab "Historial" — timeline de SystemEvents del grupo activo via
    /// `HistoryTabView`. Antes vivía como push desde Profile.
    ///
    /// Round 3: el detail sheet expone un CTA "Ver multa / Ver voto / Ver
    /// evento / Ver regla" cuando el event tiene un detail relacionado.
    /// El handler (`routeFromHistoryEvent`) decide qué tab activar y qué
    /// route state setear. Como `fineDetailRoute` está declarado en
    /// homeTab + groupTab + settingsTab stacks, el push ocurre en el tab
    /// destino (switch antes del set para que el push sea visible).
    /// Tab "Decisiones" — governance surface dedicada: `OpenVotesListView`
    /// para el grupo activo + sheets de creación. Reusa `openVotesDestination`
    /// (también accesible via Grupo → Más → Decisiones). Per AppShell 2026-05-12.
    @ViewBuilder
    private var decisionsTab: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let group = app.activeGroup {
                    HStack {
                        RuulGroupSwitcher(activeGroup: group) {
                            groupSwitcherPresented = true
                        }
                        Spacer()
                    }
                    .padding(.horizontal, RuulSpacing.screenPadding)
                    .padding(.vertical, RuulSpacing.md)
                    openVotesDestination
                } else {
                    ZStack {
                        Color.ruulBackground.ignoresSafeArea()
                        RuulLoadingState()
                    }
                }
            }
            .background(Color.ruulBackground)
            .navigationDestination(item: $voteDetailRoute) { ctx in
                voteDetailDestination(for: ctx)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// Router para SystemEvent taps en el History timeline. Resuelve el
    /// detail relacionado al event.eventType y dispara el push correcto.
    /// Cambia `selectedTab` antes de setear el route porque los
    /// `navigationDestination(item:)` viven en NavigationStacks específicos
    /// (home / group / settings), no en historyTab.
    ///
    /// Convención de tabs:
    /// - fines / appeals → groupTab (donde está el `fineDetailRoute` push)
    /// - votes → groupTab (`voteDetailRoute`)
    /// - events → homeTab (`detailRoute`)
    /// - rules → groupTab (`ruleDetailRoute`)
    @MainActor
    private func routeFromHistoryEvent(_ event: SystemEvent) {
        guard let resourceId = event.resourceId else { return }
        Task {
            switch event.eventType {
            case .fineOfficialized, .fineVoided, .finePaid, .fineReminderSent:
                if let fine = try? await app.fineRepo.fine(id: resourceId) {
                    selectedTab = .group
                    fineDetailRoute = fine
                }
            case .voteOpened, .voteCast, .voteResolved:
                if let vote = try? await app.voteRepo.vote(id: resourceId) {
                    selectedTab = .group
                    voteDetailRoute = VoteDetailRouteContext(vote: vote)
                }
            case .appealCreated, .appealResolved:
                // resourceId es appeal_id; resolver appeal → fine para
                // routear al FineDetailView (que ya muestra appeal state).
                if let appeal = try? await app.appealRepo.appeal(id: resourceId),
                   let fine = try? await app.fineRepo.fine(id: appeal.fineId) {
                    selectedTab = .group
                    fineDetailRoute = fine
                }
            case .eventClosed, .eventCreated, .checkInRecorded:
                if let evt = try? await app.eventRepo.event(resourceId) {
                    selectedTab = .home
                    detailRoute = evt
                }
            case .ruleEnabledChanged, .ruleAmountChanged:
                // rulesCoordinator.rules es la fuente in-memory; no hay
                // repo.rule(id:) — buscamos por id sobre la lista cacheada.
                if let rules = rulesCoordinator?.rules,
                   let rule = rules.first(where: { $0.id == resourceId }) {
                    selectedTab = .group
                    ruleDetailRoute = rule
                }
            default:
                // Sin destination canónico — la sheet ya cerró, no-op.
                break
            }
        }
    }

    /// Tab "Ajustes" — dual scope (cuenta global + este grupo) via
    /// `SettingsTabView`. `onOpenHistory` ahora salta a la tab Historial
    /// directamente en lugar de pushear adentro de la stack de Ajustes.
    @ViewBuilder
    private var profileTab: some View {
        NavigationStack {
            SwiftUI.Group {
                if let pCoord = profileCoordinator,
                   app.activeGroup != nil {
                    SettingsTabView(
                        profileCoordinator: pCoord,
                        onOpenMyFines: { myFinesRoute = true },
                        onOpenMyLedger: { myLedgerRoute = true },
                        onOpenHistory: { selectedTab = .home }, // Activity folded into Home (CTA "Ver actividad")
                        onOpenSettings: { settingsRoute = true },
                        onEditProfile: { editProfilePresented = true },
                        onSignOut: {
                            // app.signOut revokes the APNs token first
                            // so this device stops receiving pushes for
                            // the user that just left.
                            Task { try? await app.signOut() }
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
                    .navigationDestination(isPresented: $myLedgerRoute) {
                        MyLedgerView(coordinator: MyLedgerCoordinator(
                            userId: app.session?.user.id ?? UUID(),
                            allGroups: app.groups,
                            ledgerRepo: app.ledgerRepo,
                            groupsRepo: app.groupsRepo
                        ))
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
                    voteRepo: app.voteRepo,
                    changeFeed: app.multiDeviceChangeFeed
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
                Task {
                    async let r: Void? = rulesCoordinator?.refresh()
                    async let i: Void? = inboxCoordinator?.refresh()
                    _ = await (r, i)
                }
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
                            Task {
                                async let r: Void? = rulesCoordinator?.refresh()
                                async let i: Void? = inboxCoordinator?.refresh()
                                _ = await (r, i)
                            }
                        }
                    )
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                }
            }
            .sheet(isPresented: $createRuleChangePresented, onDismiss: {
                Task {
                    async let r: Void? = rulesCoordinator?.refresh()
                    async let i: Void? = inboxCoordinator?.refresh()
                    _ = await (r, i)
                }
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
                            Task {
                                async let r: Void? = rulesCoordinator?.refresh()
                                async let i: Void? = inboxCoordinator?.refresh()
                                _ = await (r, i)
                            }
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
            // Wrap in a @State-holding container so re-renders of MainTabView
            // (triggered by inboxCoordinator/groupHistoryCoordinator refresh
            // chains) don't cancel the in-flight `.task { coord.refresh() }`
            // by instantiating a new coordinator on each pass.
            VoteDetailDestinationContainer(
                vote: ctx.vote,
                group: group,
                userMemberId: userMemberId,
                voteRepo: app.voteRepo,
                castRepo: app.voteCastRepo,
                analytics: app.analytics,
                changeFeed: app.multiDeviceChangeFeed
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
    private func currentGroupMember(in group: RuulCore.Group) -> Member? {
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
            try await app.groupsRepo.leaveGroup(groupId: group.id)
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

    private func resolveUserMemberId(in group: RuulCore.Group) -> UUID? {
        guard let userId = app.session?.user.id else { return nil }
        return memberDirectory[userId]?.member.id
    }

    @State private var myFinesRoute: Bool = false
    @State private var myLedgerRoute: Bool = false
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
            analytics: app.analytics,
            changeFeed: app.multiDeviceChangeFeed
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
                    onSubmitted: {
                        async let d: Void = coord.refresh()
                        async let m: Void? = myFinesCoordinator?.refresh()
                        async let i: Void? = inboxCoordinator?.refresh()
                        _ = await (d, m, i)
                    }
                )
            },
            currentUserId: userId
        )
    }

    private func reviewProposedScreen(_ event: Event) -> some View {
        // Same pattern as voteDetailDestination: keep coord in @State so
        // it survives parent re-renders (inboxCoordinator/groupHistory chains).
        ReviewProposedDestinationContainer(
            event: event,
            fineRepo: app.fineRepo,
            changeFeed: app.multiDeviceChangeFeed,
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
                selectedTab = .group // fineDetailRoute push lives en groupTab
                fineDetailRoute = fine
            }
        case .fineVoided:
            if let fine = try? await app.fineRepo.fine(id: action.referenceId) {
                selectedTab = .group
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
        case .hostAssigned:
            // Tier 5 Beta: the host-assigned inbox row points at the
            // event itself (reference_id === events.id). Open the
            // resource detail so the host can see when + where + the
            // rotation context (next-host preview, policy).
            if let event = try? await app.eventRepo.event(action.referenceId) {
                detailRoute = event
                selectedTab = .home
            }
        case .slotPending, .contributionDue, .compensationDue:
            // Not used by V1 template — no-op for now.
            break
        }
    }

    /// Home tab — operational center of the active group. Per AppShell.md:
    /// aterriza directo en `HomeView`; la lista de grupos vive dentro del
    /// `GroupSwitcherSheet`. Sin pantalla intermedia.
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
                        onInvitePeople: canInviteMembers ? { inviteSharePresented = true } : nil,
                        onSwitchGroup: { groupSwitcherPresented = true },
                        resourceRefreshToken: resourceRefreshToken
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
                    // fineDetailRoute push lives on groupTab + profileTab only;
                    // routeFromHistoryEvent / handleInboxAction switch to .group
                    // before setting it. Removed from homeTab to avoid duplicate
                    // navigationDestination(item:) bindings on the same @State.
                    .navigationDestination(item: $reviewProposedRoute) { event in
                        reviewProposedScreen(event)
                    }
                    .onChange(of: reviewProposedRoute) { wasSet, isNil in
                        if wasSet != nil && isNil == nil {
                            Task {
                                async let i: Void? = inboxCoordinator?.refresh()
                                async let f: Void? = myFinesCoordinator?.refresh()
                                _ = await (i, f)
                            }
                        }
                    }
                    .navigationDestination(item: $voteDetailRouteFromInbox) { ctx in
                        voteDetailDestination(for: ctx)
                    }
                    .onChange(of: voteDetailRouteFromInbox) { wasSet, isNil in
                        if wasSet != nil && isNil == nil {
                            Task { await inboxCoordinator?.refresh() }
                        }
                    }
                    .ruulSheet(item: $voteOnAppealRoute) { ctx in
                        voteOnAppealSheet(ctx)
                    }
                    .fullScreenCover(item: $detailRoute) { event in
                        eventDetailScreen(event)
                    }
                    .onChange(of: detailRoute) { wasOpen, isOpen in
                        if wasOpen != nil && isOpen == nil {
                            Task {
                                async let h: Void = homeCoordinator?.refresh(force: true) ?? ()
                                async let i: Void? = inboxCoordinator?.refresh()
                                _ = await (h, i)
                            }
                        }
                    }
                    .fullScreenCover(item: $scannerRoute) { scannerCoord in
                        CheckInScannerView(coordinator: scannerCoord)
                    }
                    .fullScreenCover(item: $editRoute) { event in
                        eventEditScreen(event)
                    }
                } else if app.groups.isEmpty {
                    ZStack {
                        Color.ruulBackground.ignoresSafeArea()
                        EmptyGroupsView(
                            onCreate: { createGroupPresented = true },
                            onJoin: { joinGroupPresented = true }
                        )
                    }
                    .transition(.opacity)
                } else {
                    ZStack {
                        Color.ruulBackground.ignoresSafeArea()
                        HomeViewSkeleton()
                    }
                    .transition(.opacity)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// Tab "Grupo" — hub completo del grupo activo via `GroupTabView`
    /// (Resumen / Recursos / Dinero / Miembros / Más). Detail pushes
    /// (acuerdos, sanciones, ruleDetail, openVotes, voteDetail, fineDetail,
    /// eventDetail) se atan a este NavigationStack. Per AppShell 2026-05-12.
    @ViewBuilder
    private var groupTab: some View {
        NavigationStack {
            SwiftUI.Group {
                if let rulesCoord = rulesCoordinator,
                   let group = app.activeGroup {
                    GroupTabView(
                        activeGroup: group,
                        userId: app.session?.user.id ?? UUID(),
                        rulesCoordinator: rulesCoord,
                        myFinesCoordinator: myFinesCoordinator,
                        inboxCoordinator: inboxCoordinator,
                        upcomingEvents: homeCoordinator?.upcomingEvents ?? [],
                        myRSVPs: homeCoordinator?.myRSVPs ?? [:],
                        onSwitchGroup: { groupSwitcherPresented = true },
                        onOpenEvent: { event in detailRoute = event },
                        onOpenFine: { fine in fineDetailRoute = fine },
                        onOpenInboxAction: { action in
                            await handleInboxAction(action)
                        },
                        onCreateResource: { creationRoute = true },
                        onOpenAcuerdos: { acuerdosRoute = true },
                        onOpenDecisiones: {
                            openVotesRoute = OpenVotesRouteContext(id: group.id)
                        },
                        onOpenSanciones: { sancionesRoute = true },
                        onOpenGroupRules: { groupRulesSettingsPresented = true },
                        onOpenActivity: { groupHistoryRoute = true }
                    )
                    .navigationDestination(isPresented: $groupHistoryRoute) {
                        if let coord = groupHistoryCoordinator {
                            GroupHistoryView(coordinator: coord)
                                .navigationTitle("Actividad")
                                .navigationBarTitleDisplayMode(.large)
                        }
                    }
                    .navigationDestination(item: $openVotesRoute) { _ in
                        openVotesDestination
                    }
                    .navigationDestination(item: $voteDetailRoute) { ctx in
                        voteDetailDestination(for: ctx)
                    }
                    .navigationDestination(item: $fineDetailRoute) { fine in
                        fineDetailScreen(fine)
                    }
                    .navigationDestination(isPresented: $acuerdosRoute) {
                        RulesView(
                            coordinator: rulesCoord,
                            voteRepo: app.voteRepo,
                            policyRepo: app.policyRepo,
                            actorUserId: app.session?.user.id ?? UUID(),
                            userActionRepo: app.userActionRepo,
                            onSeeOpenVotes: {
                                openVotesRoute = OpenVotesRouteContext(id: group.id)
                            },
                            onSelectRule: { rule in ruleDetailRoute = rule }
                        )
                    }
                    .navigationDestination(isPresented: $sancionesRoute) {
                        if let fCoord = myFinesCoordinator {
                            MyFinesView(coordinator: fCoord) { fine in
                                fineDetailRoute = fine
                            }
                        }
                    }
                    .navigationDestination(item: $ruleDetailRoute) { rule in
                        RuleDetailView(
                            rule: rule,
                            canEditRules: rulesCoord.canEditRules,
                            onEdit: {
                                ruleEditRoute = RuleEditRouteContext(
                                    rule: rule,
                                    group: group,
                                    proposedAmount: nil,
                                    pendingActionId: nil
                                )
                            },
                            onProposeChange: {
                                ruleChangeInitialRule = rule
                                createRuleChangePresented = true
                            }
                        )
                    }
                    .toolbar(.hidden, for: .navigationBar)
                } else {
                    ZStack {
                        Color.ruulBackground.ignoresSafeArea()
                        RuulLoadingState()
                    }
                }
            }
        }
    }

    /// Empty-state hero for users with no groups. Beta 1 W3 A-3.3:
    /// migrated to the canonical `EmptyStateView` primitive with both
    /// primary + secondary CTAs (`EmptyStateView` gained
    /// `secondaryAction` support in the same commit).
    private struct EmptyGroupsView: View {
        let onCreate: () -> Void
        let onJoin: () -> Void

        var body: some View {
            VStack(spacing: 0) {
                Spacer(minLength: RuulSpacing.xxl)
                EmptyStateView(
                    systemImage: "person.3",
                    title: "Aún no tienes grupos",
                    message: "Crea uno nuevo o únete a uno con código de invitación.",
                    primaryAction: (label: "Crear grupo", perform: onCreate),
                    secondaryAction: (label: "Unirme con código", perform: onJoin)
                )
                Spacer()
            }
        }
    }

    /// Skeleton view shown during the brief homeCoordinator init window.
    /// Mirrors HomeView's hero+upcoming structure so the transition into
    /// the real content feels continuous (no jarring spinner-to-content).
    private struct HomeViewSkeleton: View {
        @State private var pulse: Bool = false

        var body: some View {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                // Header skeleton (group name + settings)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                        shimmerBlock(width: 80, height: 12)
                        shimmerBlock(width: 180, height: 36)
                    }
                    Spacer()
                    Circle()
                        .fill(Color.ruulSurface)
                        .frame(width: 40, height: 40)
                }
                .padding(.top, RuulSpacing.md)

                // Hero skeleton
                RoundedRectangle(cornerRadius: RuulRadius.extraLarge, style: .continuous)
                    .fill(Color.ruulSurface)
                    .frame(height: 220)

                // Upcoming list skeleton
                VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                    shimmerBlock(width: 100, height: 10)
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                            .fill(Color.ruulSurface)
                            .frame(height: 64)
                    }
                }
            }
            .padding(.horizontal, RuulSpacing.lg)
            .opacity(pulse ? 0.55 : 1.0)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
        }

        private func shimmerBlock(width: CGFloat, height: CGFloat) -> some View {
            RoundedRectangle(cornerRadius: RuulRadius.small, style: .continuous)
                .fill(Color.ruulSurface)
                .frame(width: width, height: height)
        }
    }

    private func eventDetailScreen(_ event: Event) -> some View {
        guard let group = app.groups.first(where: { $0.id == event.groupId }) else {
            return AnyView(EmptyView())
        }
        let userId = app.session?.user.id ?? UUID()
        return AnyView(
            EventDetailHost(
                event: event,
                group: group,
                currentUserId: userId,
                memberDirectory: memberDirectory,
                calendarService: calendarService,
                onClose: { detailRoute = nil },
                onEditEvent: { editRoute = $0 },
                onScannerOpen: { openScanner(for: $0) }
            )
        )
    }

    @ViewBuilder
    private func eventEditScreen(_ event: Event) -> some View {
        if let group = app.groups.first(where: { $0.id == event.groupId }) {
            let editCoord = ResourceEditCoordinator(
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
            // OpenPlatform E.4: route event creation through the new
            // ResourceWizard. The legacy CreateEventView remains in the
            // codebase as a fallback / edit surface but is no longer the
            // primary creation path.
            ResourceWizardSheet(
                group: group,
                suggestedDate: suggested,
                onCreated: { _ in
                    Task {
                        await homeCoordinator?.refresh(force: true)
                        // Bump the token so HomeView re-fetches its
                        // non-event resources section and the new
                        // asset/slot/fund shows up immediately.
                        await MainActor.run { resourceRefreshToken = UUID() }
                    }
                }
            )
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

    private func nextDefaultDate(for group: RuulCore.Group) -> Date {
        // Default: tomorrow at 20:30. Group-level frequency is gone post
        // BigBang; ResourceSeries (Phase 2) will provide the real default.
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
        var comps = calendar.dateComponents([.year, .month, .day], from: tomorrow)
        comps.hour = 20
        comps.minute = 30
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

    /// Resolves `member.invite` for the active group and caches the
    /// boolean used by the Inicio header to show/hide the Invitar
    /// gente icon. Fail-closed: any throw / non-`.allowed` decision
    /// hides the icon.
    @MainActor
    private func refreshCanInviteMembers() async {
        guard let group = app.activeGroup,
              let uid = app.session?.user.id else {
            canInviteMembers = false
            return
        }
        do {
            let decision = try await app.policyRepo.resolve(
                groupId: group.id,
                actorUserId: uid,
                action: .memberInvite,
                targetPayload: [:]
            )
            if case .allowed = decision {
                canInviteMembers = true
            } else {
                canInviteMembers = false
            }
        } catch {
            canInviteMembers = false
        }
    }

    @MainActor
    private func rebuildCoordinators(for group: RuulCore.Group) async {
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
            groupsRepo: app.groupsRepo,
            changeFeed: app.multiDeviceChangeFeed,
            analytics: app.analytics
        )
        myFinesCoordinator = MyFinesCoordinator(
            userId: userId,
            fineRepo: app.fineRepo,
            groupsRepo: app.groupsRepo,
            changeFeed: app.multiDeviceChangeFeed
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

        // Fire initial refreshes for non-Home coordinators that don't have
        // their own `.task { refresh() }` on view appear. HomeCoordinator
        // refreshes via `HomeView.task`. InboxCoordinator was previously
        // only refreshed on rule-edit dismiss + handleInboxAction — empty
        // until then, which hid the Pendientes section despite real rows.
        await inboxCoordinator?.refresh()
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
            actorUserId: userId,
            governance: app.governance,
            policyRepo: app.policyRepo,
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
        // so we just need the RuulCore.Group instance for the sheet builder.
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
public struct RuleEditRouteContext: Identifiable, Hashable, Sendable {
    public let rule: GroupRule
    public let group: RuulCore.Group
    public let proposedAmount: Int?
    public let pendingActionId: UUID?

    public init(rule: GroupRule, group: RuulCore.Group, proposedAmount: Int?, pendingActionId: UUID?) {
        self.rule = rule
        self.group = group
        self.proposedAmount = proposedAmount
        self.pendingActionId = pendingActionId
    }
    public var id: UUID { rule.id }
}

/// Identifiable wrapper for the `OpenVotesListView` push destination on
/// the groupTab stack (post-Fase 4b). The id is the active group's id so
/// SwiftUI rebuilds the destination on group switch.
public struct OpenVotesRouteContext: Identifiable, Hashable, Sendable {
    public let id: UUID

    public init(id: UUID) {
        self.id = id
    }
}

/// Identifiable wrapper for the `VoteDetailView` push destination. Post-Fase
/// 4b vive en groupTab stack (vote-row tap from `OpenVotesListView`) y en
/// homeTab stack (`.votePending` desde sección Pendientes). Identity es vote id.
public struct VoteDetailRouteContext: Identifiable, Hashable, Sendable {
    public let vote: Vote

    public init(vote: Vote) {
        self.vote = vote
    }
    public var id: UUID { vote.id }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(vote.id)
    }
    public static func == (lhs: VoteDetailRouteContext, rhs: VoteDetailRouteContext) -> Bool {
        lhs.vote.id == rhs.vote.id
    }
}

// CheckInScannerCoordinator must be Identifiable for fullScreenCover(item:).
extension CheckInScannerCoordinator: Identifiable {
    public nonisolated var id: UUID { event.id }
}

// Wrapper used by ruulSheet(item:) when routing the appellant vote screen.
public struct AppealRouteContext: Identifiable, Hashable, Sendable {
    public let appeal: Appeal
    public let fine: Fine

    public init(appeal: Appeal, fine: Fine) {
        self.appeal = appeal
        self.fine = fine
    }
    public var id: UUID { appeal.id }
}

// MARK: - Destination containers (preserve coord across re-renders)

/// Holds a `VoteDetailCoordinator` in @State so the navigationDestination's
/// `.task { coord.refresh() }` doesn't get cancelled mid-flight when the
/// parent (MainTabView) re-renders due to refresh chains.
@MainActor
private struct VoteDetailDestinationContainer: View {
    let vote: Vote
    let group: RuulCore.Group
    let userMemberId: UUID
    let voteRepo: any VoteRepository
    let castRepo: any VoteCastRepository
    let analytics: any AnalyticsService

    @State private var coord: VoteDetailCoordinator

    init(
        vote: Vote,
        group: RuulCore.Group,
        userMemberId: UUID,
        voteRepo: any VoteRepository,
        castRepo: any VoteCastRepository,
        analytics: any AnalyticsService,
        changeFeed: (any MultiDeviceChangeFeed)? = nil
    ) {
        self.vote = vote
        self.group = group
        self.userMemberId = userMemberId
        self.voteRepo = voteRepo
        self.castRepo = castRepo
        self.analytics = analytics
        self._coord = State(wrappedValue: VoteDetailCoordinator(
            vote: vote,
            group: group,
            userMemberId: userMemberId,
            voteRepo: voteRepo,
            castRepo: castRepo,
            analytics: analytics,
            changeFeed: changeFeed
        ))
    }

    var body: some View {
        VoteDetailView(coordinator: coord)
    }
}

/// Same wrapper pattern for ReviewProposedFinesCoordinator.
@MainActor
private struct ReviewProposedDestinationContainer: View {
    let event: Event
    let fineRepo: any FineRepository
    let memberLookup: (UUID) -> String
    let onSelectFine: (Fine) -> Void

    @State private var coord: ReviewProposedFinesCoordinator

    init(
        event: Event,
        fineRepo: any FineRepository,
        changeFeed: (any MultiDeviceChangeFeed)? = nil,
        memberLookup: @escaping (UUID) -> String,
        onSelectFine: @escaping (Fine) -> Void
    ) {
        self.event = event
        self.fineRepo = fineRepo
        self.memberLookup = memberLookup
        self.onSelectFine = onSelectFine
        self._coord = State(wrappedValue: ReviewProposedFinesCoordinator(
            event: event,
            fineRepo: fineRepo,
            changeFeed: changeFeed
        ))
    }

    var body: some View {
        ReviewProposedFinesView(
            coordinator: coord,
            memberLookup: memberLookup,
            onSelectFine: onSelectFine
        )
    }
}
