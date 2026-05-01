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

