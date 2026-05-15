import SwiftUI
import RuulCore

/// Thin tab wrapper for "Yo" (Nivel 0). Embeds MyProfileView inside a
/// NavigationStack and forwards navigation to the RootRouter.
@MainActor
public struct ProfileTab: View {
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router
    let profileCoordinator: ProfileCoordinator?
    let myFinesCoordinator: MyFinesCoordinator?

    public init(profile: ProfileCoordinator?, myFines: MyFinesCoordinator?) {
        self.profileCoordinator = profile
        self.myFinesCoordinator = myFines
    }

    public var body: some View {
        NavigationStack {
            if let coord = profileCoordinator {
                MyProfileView(
                    coordinator: coord,
                    onOpenMyFines: { router.openSanciones() },
                    onOpenHistory: { router.selectTab(.home) },
                    onEditProfile: { router.openEditProfile() },
                    onSignOut: {
                        Task { try? await app.signOut() }
                    },
                    outstandingPillAmount: myFinesCoordinator?.totalOutstanding
                )
                .environment(app)
                .task { await myFinesCoordinator?.refresh() }
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
