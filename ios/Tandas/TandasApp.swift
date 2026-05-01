import SwiftUI
import SwiftData
import Supabase
import UIKit
import OSLog

@main
struct TandasApp: App {
    @State private var appState: AppState
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("ruul_appearance") private var appearanceRaw: String = AppearanceOption.system.rawValue

    private var appearance: AppearanceOption {
        AppearanceOption(rawValue: appearanceRaw) ?? .system
    }

    init() {
        let useMocks = ProcessInfo.processInfo.environment["TANDAS_USE_MOCKS"] == "1"
        if useMocks {
            let auth = MockAuthService()
            let profile = MockProfileRepository(seed: Profile(id: UUID(), displayName: "", avatarUrl: nil, phone: nil))
            let groups = MockGroupsRepository()
            let invites = MockInviteRepository()
            let rules = MockRuleRepository()
            let otp = MockOTPService()
            let events = MockEventRepository()
            let rsvps = MockRSVPRepository()
            let checkIns = MockCheckInRepository()
            let notifTokens = MockNotificationTokenRepository()
            let analytics = LogAnalyticsService()
            _appState = State(initialValue: AppState(
                auth: auth,
                profileRepo: profile,
                groupsRepo: groups,
                inviteRepo: invites,
                ruleRepo: rules,
                otp: otp,
                eventRepo: events,
                rsvpRepo: rsvps,
                checkInRepo: checkIns,
                notificationTokenRepo: notifTokens,
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
            let otp = LiveOTPService(client: client)
            let events = LiveEventRepository(client: client)
            let rsvps = LiveRSVPRepository(client: client)
            let checkIns = LiveCheckInRepository(client: client)
            let notifTokens = LiveNotificationTokenRepository(client: client)
            let analytics = LogAnalyticsService()
            _appState = State(initialValue: AppState(
                auth: auth,
                profileRepo: profile,
                groupsRepo: groups,
                inviteRepo: invites,
                ruleRepo: rules,
                otp: otp,
                eventRepo: events,
                rsvpRepo: rsvps,
                checkInRepo: checkIns,
                notificationTokenRepo: notifTokens,
                notifications: NotificationService(tokenRepo: notifTokens),
                walletService: StubWalletPassService(),
                analytics: analytics,
                realtimeFactory: { eventId in
                    RSVPRealtimeService(client: client, eventId: eventId)
                }
            ))
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
