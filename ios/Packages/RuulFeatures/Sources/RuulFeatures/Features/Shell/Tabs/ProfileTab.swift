import SwiftUI
import RuulCore
import RuulUI

/// Thin tab wrapper for "Yo" (Nivel 0). Embeds MyProfileView inside a
/// NavigationStack and forwards navigation to the RootRouter.
@MainActor
public struct ProfileTab: View {
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router
    let profileCoordinator: ProfileCoordinator?
    let myFinesCoordinator: MyFinesCoordinator?

    @State private var path = NavigationPath()
    @State private var showChangePhone = false
    @State private var showChangeEmail = false
    @State private var showTimeline = false
    @State private var showDevices = false
    @State private var showNotificationPreferences = false

    private enum ProfileNav: Hashable { case language, timezone }

    public init(profile: ProfileCoordinator?, myFines: MyFinesCoordinator?) {
        self.profileCoordinator = profile
        self.myFinesCoordinator = myFines
    }

    public var body: some View {
        NavigationStack(path: $path) {
            if let coord = profileCoordinator {
                MyProfileView(
                    coordinator: coord,
                    onOpenMyFines: { router.openSanciones() },
                    onOpenHistory: { router.selectTab(.home) },
                    onEditProfile: { router.openEditProfile() },
                    onSignOut: { Task { try? await app.signOut() } },
                    onOpenTimeline: { showTimeline = true },
                    outstandingPillAmount: myFinesCoordinator?.totalOutstanding,
                    onChangePhone: { showChangePhone = true },
                    onChangeEmail: { showChangeEmail = true },
                    onPickLanguage: { path.append(ProfileNav.language) },
                    onPickTimezone: { path.append(ProfileNav.timezone) },
                    onOpenNotificationPreferences: { showNotificationPreferences = true },
                    onOpenDevices: { showDevices = true },
                    onOpenGroupSwitcher: { router.openGroupSwitcher() }
                )
                .navigationDestination(for: ProfileNav.self) { dest in
                    switch dest {
                    case .language: LanguagePickerView()
                    case .timezone: TimezonePickerView()
                    }
                }
                .fullScreenCover(isPresented: $showChangePhone) { ChangePhoneFlow() }
                .fullScreenCover(isPresented: $showChangeEmail) { ChangeEmailFlow() }
                .fullScreenCover(isPresented: $showTimeline) { MyTimelineView().environment(app) }
                .fullScreenCover(isPresented: $showDevices) { DevicesView().environment(app) }
                .fullScreenCover(isPresented: $showNotificationPreferences) {
                    NotificationPreferencesView().environment(app)
                }
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
