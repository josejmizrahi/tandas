import SwiftUI
import SwiftData
import Supabase
import UIKit
import OSLog
import Sentry
import RuulUI
import RuulCore

@main
struct TandasApp: App {
    @State private var appState: AppState
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("ruul_appearance") private var appearanceRaw: String = AppearanceOption.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    private var appearance: AppearanceOption {
        AppearanceOption(rawValue: appearanceRaw) ?? .system
    }

    init() {
        Self.startSentry()
        let useMocks = ProcessInfo.processInfo.environment["TANDAS_USE_MOCKS"] == "1"
        if useMocks {
            let auth = MockAuthService()
            let profile = MockProfileRepository(seed: Profile(id: UUID(), displayName: "", avatarUrl: nil, phone: nil))
            let groups = MockGroupsRepository()
            let invites = MockInviteRepository()
            let rules = MockRuleRepository()
            let votes = MockVoteRepository()
            let voteCasts = MockVoteCastRepository()
            let governance = GovernanceService()
            let otp = MockOTPService()
            let templates = TemplateRegistry(repository: MockTemplateRepository())
            let events = MockEventRepository()
            let rsvps = MockRSVPRepository()
            let checkIns = MockCheckInRepository()
            let notifTokens = MockNotificationTokenRepository()
            let systemEvents = MockSystemEventRepository()
            let userActions = MockUserActionRepository()
            let appeals = MockAppealRepository()
            let fines = MockFineRepository()
            let resources = MockResourceRepository()
            let slotLifecycle = MockSlotLifecycleRepository()
            let resourceSeries = MockResourceSeriesRepository()
            let resourceCapabilities = MockResourceCapabilityRepository()
            let ledger = MockLedgerRepository()
            let rsvpActions = MockRsvpActionRepository()
            let analytics = LogAnalyticsService()
            _appState = State(initialValue: AppState(
                auth: auth,
                profileRepo: profile,
                groupsRepo: groups,
                inviteRepo: invites,
                ruleRepo: rules,
                voteRepo: votes,
                voteCastRepo: voteCasts,
                governance: governance,
                otp: otp,
                templateRegistry: templates,
                eventRepo: events,
                rsvpRepo: rsvps,
                checkInRepo: checkIns,
                notificationTokenRepo: notifTokens,
                systemEventRepo: systemEvents,
                userActionRepo: userActions,
                appealRepo: appeals,
                fineRepo: fines,
                resourceRepo: resources,
                slotLifecycleRepo: slotLifecycle,
                resourceSeriesRepo: resourceSeries,
                resourceCapabilityRepo: resourceCapabilities,
                ledgerRepo: ledger,
                rsvpActionRepo: rsvpActions,
                notifications: NotificationService(tokenRepo: notifTokens),
                walletService: StubWalletPassService(),
                analytics: analytics
            ))
        } else {
            let client = SupabaseEnvironment.shared
            let auth = LiveAuthService(client: client)
            let profile = LiveProfileRepository(client: client)
            let groups = LiveGroupsRepository(client: client)
            let invites = LiveInviteRepository(client: client)
            let rules = LiveRuleRepository(client: client)
            let votes = LiveVoteRepository(client: client)
            let voteCasts = LiveVoteCastRepository(client: client)
            let governance = GovernanceService()
            let otp = LiveOTPService(client: client)
            let templates = TemplateRegistry(repository: LiveTemplateRepository(client: client))
            let events = LiveEventRepository(client: client)
            let rsvps = LiveRSVPRepository(client: client)
            let checkIns = LiveCheckInRepository(client: client)
            let notifTokens = LiveNotificationTokenRepository(client: client)
            let systemEvents = LiveSystemEventRepository(client: client)
            let userActions = LiveUserActionRepository(client: client)
            let appeals = LiveAppealRepository(client: client)
            let fines = LiveFineRepository(client: client)
            let resources = LiveResourceRepository(client: client)
            let slotLifecycle = LiveSlotLifecycleRepository(client: client)
            let resourceSeries = LiveResourceSeriesRepository(client: client)
            let resourceCapabilities = LiveResourceCapabilityRepository(client: client)
            let ledger = LiveLedgerRepository(client: client)
            let rsvpActions = LiveRsvpActionRepository(client: client)
            let analytics = LogAnalyticsService()
            let state = AppState(
                auth: auth,
                profileRepo: profile,
                groupsRepo: groups,
                inviteRepo: invites,
                ruleRepo: rules,
                voteRepo: votes,
                voteCastRepo: voteCasts,
                governance: governance,
                otp: otp,
                templateRegistry: templates,
                eventRepo: events,
                rsvpRepo: rsvps,
                checkInRepo: checkIns,
                notificationTokenRepo: notifTokens,
                systemEventRepo: systemEvents,
                userActionRepo: userActions,
                appealRepo: appeals,
                fineRepo: fines,
                resourceRepo: resources,
                slotLifecycleRepo: slotLifecycle,
                resourceSeriesRepo: resourceSeries,
                resourceCapabilityRepo: resourceCapabilities,
                ledgerRepo: ledger,
                rsvpActionRepo: rsvpActions,
                notifications: NotificationService(tokenRepo: notifTokens),
                walletService: StubWalletPassService(),
                analytics: analytics,
                realtimeFactory: { eventId in
                    RSVPRealtimeService(client: client, eventId: eventId)
                }
            )
            state.moduleRegistryLoader = LiveModuleRegistry(client: client)
            state.ruleShapeRepo = LiveRuleShapeRepository(client: client)
            _appState = State(initialValue: state)
        }
    }

    /// Sentry MVP — crash capture only. No performance monitoring, no
    /// breadcrumbs beyond the SDK defaults. PII (email, username, IP) is
    /// scrubbed in beforeSend so events stay anonymized; group_id /
    /// rule_id metadata that callers attach via tags survives. Privacy
    /// Policy v1.1 discloses Sentry as a third-party processor.
    private static func startSentry() {
        let dsn = (Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String) ?? ""
        guard !dsn.isEmpty else {
            // No DSN configured (e.g., local dev with stub xcconfig). Skip
            // SDK init; SentrySDK calls become no-ops.
            return
        }
        let shortVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let buildNumber = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = "ruul-ios@\(shortVersion)+\(buildNumber)"
            #if DEBUG
            options.environment = "development"
            #else
            options.environment = "production"
            #endif
            options.tracesSampleRate = 0.0
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.beforeSend = { event in
                event.user?.email = nil
                event.user?.username = nil
                event.user?.ipAddress = nil
                return event
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            // Luma-style: respeta sistema o user preference (Auto/Claro/Oscuro).
            AuthGate()
                .environment(appState)
                .ruulTheme()
                .preferredColorScheme(appearance.colorScheme)
                #if DEBUG
                .ruulShowcaseShakeListener()
                #endif
                .onOpenURL { url in
                    appState.handleIncomingURL(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        appState.handleIncomingURL(url)
                    }
                }
                .task {
                    appDelegate.bind(appState: appState)
                }
        }
        .modelContainer(for: [OnboardingProgress.self])
        // Beta 1 instrumentation (Plans/Active/Beta1.md §4): fire
        // app_opened on every transition into .active. Cheapest signal
        // for DAU + retention curves during the cena observation window.
        .onChange(of: scenePhase) { _, new in
            guard new == .active else { return }
            let beta = BetaAnalytics(analytics: appState.analytics)
            Task { await beta.appOpened() }
        }
    }
}

/// Bridges UIKit-only APNs callbacks to AppState.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private weak var appState: AppState?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "appdelegate")

    @MainActor
    func bind(appState: AppState) {
        self.appState = appState
        UNUserNotificationCenter.current().delegate = self
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            await appState?.notifications?.didRegisterDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        log.warning("APNs registration failed: \(error.localizedDescription)")
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Cross-actor send of non-Sendable types; opt out under our control.
        nonisolated(unsafe) let userInfo = response.notification.request.content.userInfo
        nonisolated(unsafe) let handler = completionHandler
        Task { @MainActor in
            self.appState?.handleIncomingNotification(userInfo: userInfo)
            handler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
