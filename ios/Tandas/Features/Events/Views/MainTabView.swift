import SwiftUI

/// Top-level tab container shown after onboarding. Sprint 1b: expanded
/// from 1 → 4 tabs (Inicio, Inbox, Reglas, Yo) using ResourceTabBar so
/// the platform-template architecture is reflected in the chrome from
/// day one. Inbox / Reglas / Yo render stub placeholders until Sprint
/// 1c fills them with the real ActionInboxView, RulesView, ProfileView.
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
    @State private var fineDetailRoute: Fine?
    @State private var reviewProposedRoute: Event?
    @State private var voteOnAppealRoute: AppealRouteContext?

    enum Tab: Hashable, Sendable { case home, inbox, rules, me }

    var body: some View {
        ResourceTabBar(
            tabs: [
                .init(id: Tab.home,  label: "Inicio", systemImage: "house.fill"),
                .init(id: Tab.inbox, label: "Inbox",  systemImage: "tray.fill",
                      badge: badgeForInbox),
                .init(id: Tab.rules, label: "Reglas", systemImage: "list.bullet.clipboard.fill"),
                .init(id: Tab.me,    label: "Yo",     systemImage: "person.crop.circle.fill")
            ],
            selection: $selectedTab
        ) { tab in
            switch tab {
            case .home:  homeTab
            case .inbox: inboxTab
            case .rules: RulesTabStub()
            case .me:    profileTab
            }
        }
        .task { await bootstrap() }
        .onChange(of: app.pendingEventDeepLink) { _, link in
            Task { await handleDeepLink(link) }
        }
    }

    private var badgeForInbox: ResourceTabBadge? {
        let count = inboxCoordinator?.actions.count ?? 0
        return count > 0 ? .count(count) : nil
    }

    // MARK: - Inbox tab

    @ViewBuilder
    private var inboxTab: some View {
        NavigationStack {
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
                .ruulSheet(item: $voteOnAppealRoute) { ctx in
                    voteOnAppealSheet(ctx)
                }
            } else {
                ZStack {
                    Color.ruulBackgroundCanvas.ignoresSafeArea()
                    ProgressView().tint(Color.ruulAccentPrimary)
                }
            }
        }
    }

    @ViewBuilder
    private var profileTab: some View {
        NavigationStack {
            if let coord = myFinesCoordinator {
                MyFinesView(coordinator: coord) { fine in
                    fineDetailRoute = fine
                }
                .navigationDestination(item: $fineDetailRoute) { fine in
                    fineDetailScreen(fine)
                }
            } else {
                ProfileTabStub()
            }
        }
    }

    private func fineDetailScreen(_ fine: Fine) -> some View {
        let coord = FineDetailCoordinator(
            fine: fine,
            userId: app.session?.user.id ?? UUID(),
            fineRepo: app.fineRepo,
            appealRepo: app.appealRepo
        )
        return FineDetailView(
            coordinator: coord,
            onAppeal: nil,
            onViewAppeal: { appeal in
                voteOnAppealRoute = AppealRouteContext(appeal: appeal, fine: fine)
            }
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
        switch action.actionType {
        case .finePending:
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
        case .slotPending, .votePending, .contributionDue, .compensationDue:
            // Not used by V1 template — no-op for now.
            break
        }
    }

    @ViewBuilder
    private var homeTab: some View {
        NavigationStack {
            if let coord = homeCoordinator {
                HomeView(
                    coordinator: coord,
                    userId: app.session?.user.id ?? UUID(),
                    onCreateEvent: { creationRoute = true },
                    onOpenEvent: { event in detailRoute = event },
                    onOpenPastEvents: { pastRoute = true }
                )
                .navigationDestination(isPresented: $pastRoute) {
                    if let group = app.groups.first {
                        PastEventsView(
                            group: group,
                            userId: app.session?.user.id ?? UUID(),
                            eventRepo: app.eventRepo
                        ) { event in detailRoute = event }
                    }
                }
                .fullScreenCover(item: $detailRoute) { event in
                    eventDetailScreen(event)
                }
                .fullScreenCover(isPresented: $creationRoute) {
                    eventCreationScreen
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
                    ProgressView().tint(Color.ruulAccentPrimary)
                }
            }
        }
    }

    private func eventDetailScreen(_ event: Event) -> some View {
        guard let group = app.groups.first(where: { $0.id == event.groupId }) else {
            return AnyView(EmptyView())
        }
        let coord = EventDetailCoordinator(
            event: event,
            group: group,
            userId: app.session?.user.id ?? UUID(),
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
        return AnyView(
            EventDetailView(
                coordinator: coord,
                memberLookup: lookupMember,
                onScannerOpen: { openScanner(for: coord) },
                calendarService: calendarService,
                onEdit: { editRoute = coord.event }
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
        if let group = app.groups.first {
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
        guard let group = app.groups.first, homeCoordinator == nil else { return }
        let userId = app.session?.user.id ?? UUID()
        homeCoordinator = HomeCoordinator(
            group: group,
            userId: userId,
            eventRepo: app.eventRepo,
            rsvpRepo: app.rsvpRepo
        )
        inboxCoordinator = InboxCoordinator(
            userId: userId,
            groupId: group.id,
            userActionRepo: app.userActionRepo
        )
        myFinesCoordinator = MyFinesCoordinator(
            userId: userId,
            fineRepo: app.fineRepo
        )
        await refreshMemberDirectory(for: group.id)
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
