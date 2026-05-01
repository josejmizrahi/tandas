import SwiftUI
import Supabase

@main
struct TandasApp: App {
    @State private var appState: AppState
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
            // Luma-style: respeta sistema o user preference (Auto/Claro/Oscuro).
            AuthGate()
                .environment(appState)
                .ruulTheme()
                .preferredColorScheme(appearance.colorScheme)
                #if DEBUG
                .ruulShowcaseShakeListener()
                #endif
        }
    }
}

