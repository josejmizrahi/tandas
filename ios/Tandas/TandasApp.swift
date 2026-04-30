import SwiftUI
import Supabase

@main
struct TandasApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.supabase, SupabaseEnvironment.shared)
        }
    }
}

private struct SupabaseClientKey: EnvironmentKey {
    static let defaultValue: SupabaseClient = SupabaseEnvironment.shared
}

extension EnvironmentValues {
    var supabase: SupabaseClient {
        get { self[SupabaseClientKey.self] }
        set { self[SupabaseClientKey.self] = newValue }
    }
}

struct ContentView: View {
    @Environment(\.supabase) private var supabase
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                Text("Tandas")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Supabase: \(SupabaseEnvironment.configuredHost)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
        }
    }
}
