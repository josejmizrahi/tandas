import SwiftUI

/// Top-level tab container shown after onboarding. V1 has 1 tab (Home);
/// future prompts add Rules, Multas, Settings.
struct MainTabView: View {
    @Environment(AppState.self) private var app
    @State private var homeCoordinator: HomeCoordinator?
    @State private var detailRoute: Event?
    @State private var creationRoute: Bool = false
    @State private var pastRoute: Bool = false
    @State private var scannerRoute: CheckInScannerCoordinator?

    var body: some View {
        TabView {
            homeTab
                .tabItem {
                    Label("Inicio", systemImage: "house.fill")
                }
        }
        .tint(Color.ruulAccentPrimary)
        .task { await bootstrap() }
        .onChange(of: app.pendingEventDeepLink) { _, link in
            Task { await handleDeepLink(link) }
        }
    }

    @ViewBuilder
    private var homeTab: some View {
        NavigationStack {
            if let coord = homeCoordinator {
                HomeView(
                    coordinator: coord,
                    userId: app.session?.userId ?? UUID(),
                    onCreateEvent: { creationRoute = true },
                    onOpenEvent: { event in detailRoute = event },
                    onOpenPastEvents: { pastRoute = true }
                )
                .navigationDestination(isPresented: $pastRoute) {
                    if let group = app.groups.first {
                        PastEventsView(
                            group: group,
                            userId: app.session?.userId ?? UUID(),
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
            userId: app.session?.userId ?? UUID(),
            eventRepo: app.eventRepo,
            rsvpRepo: app.rsvpRepo,
            checkInRepo: app.checkInRepo,
            lifecycle: app.eventLifecycle,
            notifications: app.notifications,
            walletService: app.walletService,
            analytics: EventAnalytics(analytics: app.analytics)
        )
        return AnyView(
            EventDetailView(
                coordinator: coord,
                memberLookup: { id in (name: "Member", avatarURL: nil) },  // V1.x wires real lookup
                onScannerOpen: { openScanner(for: coord) }
            )
        )
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
            memberLookup: { _ in "Member" }
        )
        scannerRoute = coord
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
        homeCoordinator = HomeCoordinator(
            group: group,
            userId: app.session?.userId ?? UUID(),
            eventRepo: app.eventRepo,
            rsvpRepo: app.rsvpRepo
        )
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
