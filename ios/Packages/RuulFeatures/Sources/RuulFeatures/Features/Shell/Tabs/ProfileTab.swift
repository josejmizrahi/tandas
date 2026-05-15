import SwiftUI
import RuulCore

/// Thin tab wrapper for Profile. Embeds ProfileView inside a NavigationStack.
/// Navigation callbacks are wired to RootRouter via @Environment injection.
@MainActor
public struct ProfileTab: View {
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router
    let profileCoordinator: ProfileCoordinator?

    public init(profile: ProfileCoordinator?) {
        self.profileCoordinator = profile
    }

    public var body: some View {
        NavigationStack {
            if let coord = profileCoordinator {
                ProfileView(
                    coordinator: coord,
                    onOpenMyFines: { router.openSanciones() },
                    onOpenHistory: { router.selectTab(.home) },
                    onOpenSettings: { router.openSettings() },
                    onEditProfile: { router.openEditProfile() },
                    onSignOut: {
                        Task { try? await app.signOut() }
                    },
                    groupScope: app.activeGroup != nil ? ProfileView.GroupScopeContext(
                        onOpenMembers: { router.openMembers() },
                        onOpenGovernance: {},
                        onLeaveGroup: {},
                        onOpenAcuerdos: { router.openAcuerdos() }
                    ) : nil
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
