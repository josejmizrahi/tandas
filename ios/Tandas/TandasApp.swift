import SwiftUI
import Supabase

@main
struct TandasApp: App {
    @State private var appState: AppState

    init() {
        let client = SupabaseEnvironment.shared
        let auth = LiveAuthService(client: client)
        let profile = LiveProfileRepository(client: client)
        let groups = LiveGroupsRepository(client: client)
        _appState = State(initialValue: AppState(
            auth: auth, profileRepo: profile, groupsRepo: groups
        ))
    }

    var body: some Scene {
        WindowGroup {
            AuthGate()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
    }
}

// Stub views — implemented in tasks 9, 11, 12, 16
struct LoginView: View { var body: some View { Text("LoginView (stub)").foregroundStyle(.white) } }
struct OnboardingView: View { var body: some View { Text("OnboardingView (stub)").foregroundStyle(.white) } }
struct EmptyGroupsView: View { var body: some View { Text("EmptyGroupsView (stub)").foregroundStyle(.white) } }
struct GroupsListView: View { var body: some View { Text("GroupsListView (stub)").foregroundStyle(.white) } }
