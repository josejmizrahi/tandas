import SwiftUI
import SwiftData
import Supabase

@main
struct TandasApp: App {
    @State private var appState: AppState

    init() {
        let useMocks = ProcessInfo.processInfo.environment["TANDAS_USE_MOCKS"] == "1"
        if useMocks {
            let auth = MockAuthService()
            let profile = MockProfileRepository(seed: Profile(id: UUID(), displayName: "", avatarUrl: nil, phone: nil))
            let groups = MockGroupsRepository()
            let invites = MockInviteRepository()
            let rules = MockRuleRepository()
            let otp = MockOTPService()
            _appState = State(initialValue: AppState(
                auth: auth,
                profileRepo: profile,
                groupsRepo: groups,
                inviteRepo: invites,
                ruleRepo: rules,
                otp: otp
            ))
        } else {
            let client = SupabaseEnvironment.shared
            let auth = LiveAuthService(client: client)
            let profile = LiveProfileRepository(client: client)
            let groups = LiveGroupsRepository(client: client)
            let invites = LiveInviteRepository(client: client)
            let rules = LiveRuleRepository(client: client)
            let otp = LiveOTPService(client: client)
            _appState = State(initialValue: AppState(
                auth: auth,
                profileRepo: profile,
                groupsRepo: groups,
                inviteRepo: invites,
                ruleRepo: rules,
                otp: otp
            ))
        }
    }

    var body: some Scene {
        WindowGroup {
            AuthGate()
                .environment(appState)
                .ruulTheme()
                .preferredColorScheme(.dark)
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
        }
        .modelContainer(for: [OnboardingProgress.self])
    }
}
