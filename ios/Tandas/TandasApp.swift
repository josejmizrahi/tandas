import SwiftUI
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
            _appState = State(initialValue: AppState(auth: auth, profileRepo: profile, groupsRepo: groups))
        } else {
            let client = SupabaseEnvironment.shared
            let auth = LiveAuthService(client: client)
            let profile = LiveProfileRepository(client: client)
            let groups = LiveGroupsRepository(client: client)
            _appState = State(initialValue: AppState(auth: auth, profileRepo: profile, groupsRepo: groups))
        }
    }

    var body: some Scene {
        WindowGroup {
            // Note: .preferredColorScheme(.dark) is intentionally retained
            // during DS V1. The new design system supports light + dark + HC,
            // but every existing feature view (LoginView, OnboardingView,
            // WelcomeView, GroupsListView) was authored for dark only and
            // would render incorrectly in light. The override is removed when
            // those features are migrated in subsequent prompts.
            AuthGate()
                .environment(appState)
                .ruulTheme()
                .preferredColorScheme(.dark)
                #if DEBUG
                .ruulShowcaseShakeListener()
                #endif
        }
    }
}

