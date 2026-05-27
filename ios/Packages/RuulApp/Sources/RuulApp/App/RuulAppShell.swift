import SwiftUI
import RuulCore

/// Root view for the Foundation iOS surface. Branches on
/// `SessionStore.state`:
///
/// - `.bootstrapping` → small splash while AuthService loads its cached
///   session.
/// - `.signedOut` → `SignInWithOTPView` (phone OTP, the only auth path
///   enabled in slice 4a).
/// - `.signedIn` → `GroupListView` inside a `NavigationStack`.
///
/// Mounted only under the `-FoundationShell` launch argument from
/// `TandasApp.swift`. The legacy `AuthGate`/RuulFeatures shell keeps
/// owning release builds until the cutover.
public struct RuulAppShell: View {
    @State private var container: DependencyContainer

    public init(container: DependencyContainer = DependencyContainer()) {
        _container = State(initialValue: container)
    }

    public var body: some View {
        content
            .task {
                container.bootstrap()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch container.sessionStore.state {
        case .bootstrapping:
            BootstrappingView()
        case .signedOut:
            SignInWithOTPView(container: container)
        case .signedIn:
            NavigationStack {
                GroupListView(container: container)
            }
        }
    }
}

private struct BootstrappingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Cargando…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
