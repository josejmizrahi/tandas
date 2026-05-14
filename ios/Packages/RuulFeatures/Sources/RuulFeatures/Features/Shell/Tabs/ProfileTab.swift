import SwiftUI
import RuulCore

/// Thin tab wrapper for Profile. Embeds ProfileView inside a NavigationStack.
/// All navigation callbacks are no-op stubs for Pass 1 — they will be
/// wired to RootRouter actions when RootShell is assembled in Task 9.
@MainActor
public struct ProfileTab: View {
    @Environment(AppState.self) private var app
    let profileCoordinator: ProfileCoordinator?

    public init(profile: ProfileCoordinator?) {
        self.profileCoordinator = profile
    }

    public var body: some View {
        NavigationStack {
            if let coord = profileCoordinator {
                ProfileView(
                    coordinator: coord,
                    onOpenMyFines: {},
                    onOpenHistory: {},
                    onOpenSettings: {},
                    onEditProfile: {},
                    onSignOut: {}
                )
                .environment(app)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
