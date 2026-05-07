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
    @State private var fineDetailRoute: Fine?
    @State private var reviewProposedRoute: Event?
    @State private var voteOnAppealRoute: AppealRouteContext?
    @State private var feedRoute: Bool = false
    /// Phase G3: route state for `EditRuleSheet` opened pre-loaded from a
    /// `ruleChangeApplyPending` inbox tap or a `RuleChangeDeepLink` push /
    /// universal link. Setting this presents the sheet via `.sheet(item:)`.
    @State private var ruleEditRoute: RuleEditRouteContext?
    /// Phase G2 follow-up: route state for `OpenVotesListView` pushed from
    /// the "Votos abiertos" section of `RulesView`. Lives on the rulesTab
    /// `NavigationStack`.
    @State private var openVotesRoute: OpenVotesRouteContext?
    /// Phase G2 follow-up: route state for `VoteDetailView` pushed from a
    /// vote row tap inside `OpenVotesListView` (rulesTab stack).
    @State private var voteDetailRoute: VoteDetailRouteContext?
    /// Phase G2 follow-up: route state for `VoteDetailView` pushed from an
    /// inbox tap on a `.votePending` action. Lives on the inboxTab stack so
    /// the destination resolves on the same NavigationStack the user is on.
    @State private var voteDetailRouteFromInbox: VoteDetailRouteContext?

    // Fase B: multi-grupo. Three sheets — switcher (lists groups + entry
    // points), create (new group from scratch), join (with invite code).
    @State private var groupSwitcherPresented: Bool = false
    @State private var createGroupPresented: Bool = false
    @State private var joinGroupPresented: Bool = false
    @State private var inviteSharePresented: Bool = false

    enum Tab: String, RuulTabItem, CaseIterable {
        case home, inbox, rules, me

        var id: String { rawValue }
        var label: String {
            switch self {
            case .home:  return "Inicio"
            case .inbox: return "Inbox"
            case .rules: return "Reglas"
            case .me:    return "Yo"
            }
        }
        var symbol: String {
            switch self {
            case .home:  return "house.fill"
            case .inbox: return "tray.fill"
            case .rules: return "list.bullet.clipboard.fill"
            case .me:    return "person.crop.circle.fill"
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
                badgeCount: tab == .inbox ? (inboxCoordinator?.actions.count ?? 0) : nil
            )
        }
    }

    /// Native TabView badge for the Inbox tab (rendered via `.badge(_)`).
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
            inboxTab
                .tabItem { Label(Tab.inbox.label, systemImage: Tab.inbox.symbol) }
                .tag(Tab.inbox)
                .badge(inboxBadgeCount)
            rulesTab
                .tabItem { Label(Tab.rules.label, systemImage: Tab.rules.symbol) }
                .tag(Tab.rules)
            profileTab
                .tabItem { Label(Tab.me.label, systemImage: Tab.me.symbol) }
                .tag(Tab.me)
        }
        .tint(Color.ruulTextPrimary)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
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

    // MARK: - Inbox tab

    @ViewBuilder
    private var rulesTab: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GroupContextHeader(
                    group: app.activeGroup,
                    onTap: { groupSwitcherPresented = true }
                )
                if let coord = rulesCoordinator {
                    RulesView(
                        coordinator: coord,
                        voteRepo: app.voteRepo,
                        userActionRepo: app.userActionRepo,
                        onSeeOpenVotes: {
                            if let group = app.activeGroup {
                                openVotesRoute = OpenVotesRouteContext(id: group.id)
                            }
                        }
                    )
                    .navigationDestination(item: $openVotesRoute) { _ in
                        openVotesDestination
                    }
                    .navigationDestination(item: $voteDetailRoute) { ctx in
                        voteDetailDestination(for: ctx)
                    }
                } else {
                    ZStack {
                        Color.ruulBackgroundCanvas.ignoresSafeArea()
                        RuulLoadingState()
                    }
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
                // Phase G2 follow-up: wiring CreateVoteSheet (general
                // proposal + rule_change pickers) is its own task. For the
                // dead-tap fix the "+" toolbar button is intentionally a
                // no-op; an empty-state CTA in OpenVotesListView calls the
                // same closure. Tracked separately.
                onCreateVote: {}
            )
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
                    castRepo: app.voteCastRepo
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
    private func resolveUserMemberId(in group: Group) -> UUID? {
        guard let userId = app.session?.user.id else { return nil }
        return memberDirectory[userId]?.member.id
    }

    @ViewBuilder
    private var inboxTab: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GroupContextHeader(
                    group: app.activeGroup,
                    onTap: { groupSwitcherPresented = true }
                )
                if let coord = inboxCoordinator {
                    ActionInboxView(coordinator: coord) { action in
                        Task { await handleInboxAction(action) }
                    }
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
                } else {
                    ZStack {
                        Color.ruulBackgroundCanvas.ignoresSafeArea()
                        RuulLoadingState()
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    @State private var myFinesRoute: Bool = false
    @State private var historyRoute: Bool = false
    @State private var settingsRoute: Bool = false

    @ViewBuilder
    private var profileTab: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GroupContextHeader(
                    group: app.activeGroup,
                    onTap: { groupSwitcherPresented = true }
                )
                if let pCoord = profileCoordinator {
                    ProfileView(
                        coordinator: pCoord,
                        onOpenMyFines: { myFinesRoute = true },
                        onOpenHistory: { historyRoute = true },
                        onOpenSettings: { settingsRoute = true },
                        onSignOut: {
                            Task { try? await app.auth.signOut() }
                        }
                    )
                    .navigationDestination(isPresented: $myFinesRoute) {
                        if let fCoord = myFinesCoordinator {
                            MyFinesView(coordinator: fCoord) { fine in
                                fineDetailRoute = fine
                            }
                        }
                    }
                    .navigationDestination(isPresented: $historyRoute) {
                        groupHistoryScreen
                    }
                    .navigationDestination(item: $fineDetailRoute) { fine in
                        fineDetailScreen(fine)
                    }
                    .sheet(isPresented: $settingsRoute) {
                        SettingsSheet()
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                    }
                } else {
                    ProfileTabStub()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

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

    @ViewBuilder
    private var groupHistoryScreen: some View {
        if let group = app.activeGroup {
            GroupHistoryView(coordinator: GroupHistoryCoordinator(
                groupId: group.id,
                repo: app.systemEventRepo
            ))
        } else {
            EmptyView()
        }
    }

    private func fineDetailScreen(_ fine: Fine) -> some View {
        let coord = FineDetailCoordinator(
            fine: fine,
            userId: app.session?.user.id ?? UUID(),
            fineRepo: app.fineRepo,
            appealRepo: app.appealRepo
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
        return ReviewProposedFinesView(coordinator: coord) { userId in
            memberDirectory[userId]?.displayName ?? "Miembro"
        }
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
                        userId: app.session?.user.id ?? UUID(),
                        onCreateEvent: { creationRoute = true },
                        onOpenEvent: { event in detailRoute = event },
                        onOpenPastEvents: { pastRoute = true },
                        onSwitchGroup: { groupSwitcherPresented = true },
                        onInvitePeople: { inviteSharePresented = true },
                        onOpenFeed: { feedRoute = true }
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
                        Color.ruulBackgroundCanvas.ignoresSafeArea()
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
/// resolved rule + group + the deep-link-supplied proposed amount so the
/// sheet can pre-load draftAmount in one render. `pendingActionId` is
/// non-nil only on the inbox-tap path; nil on push / URL deep-links.
struct RuleEditRouteContext: Identifiable, Hashable {
    let rule: GroupRule
    let group: Group
    let proposedAmount: Int
    let pendingActionId: UUID?
    var id: UUID { rule.id }
}

/// Identifiable wrapper for the `OpenVotesListView` push destination on
/// the rulesTab stack. The id is the active group's id so SwiftUI rebuilds
/// the destination on group switch.
struct OpenVotesRouteContext: Identifiable, Hashable {
    let id: UUID
}

/// Identifiable wrapper for the `VoteDetailView` push destination. Used on
/// both the rulesTab stack (vote-row tap from `OpenVotesListView`) and the
/// inboxTab stack (`.votePending` action tap). Identity is the vote id.
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
