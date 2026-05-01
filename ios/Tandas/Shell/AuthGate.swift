import SwiftUI

@MainActor
@Observable
final class AppState {
    var session: AppSession?
    var profile: Profile?
    var groups: [Group] = []
    var isBootstrapping: Bool = true

    let auth: any AuthService
    let profileRepo: any ProfileRepository
    let groupsRepo: any GroupsRepository

    init(
        auth: any AuthService,
        profileRepo: any ProfileRepository,
        groupsRepo: any GroupsRepository
    ) {
        self.auth = auth
        self.profileRepo = profileRepo
        self.groupsRepo = groupsRepo
    }

    func start() async {
        for await s in auth.sessionStream {
            self.session = s
            if s != nil {
                await refreshProfileAndGroups()
            } else {
                self.profile = nil
                self.groups = []
            }
            self.isBootstrapping = false
        }
    }

    func refreshProfileAndGroups() async {
        async let p = (try? await profileRepo.loadMine())
        async let g = ((try? await groupsRepo.listMine()) ?? [])
        let (profile, groups) = await (p, g)
        self.profile = profile
        self.groups = groups
    }
}

struct AuthGate: View {
    @Environment(AppState.self) private var app

    var body: some View {
        SwiftUI.Group {
            if app.isBootstrapping {
                BootstrappingView()
            } else if app.session == nil {
                LoginView()
            } else if let profile = app.profile, profile.needsOnboarding {
                OnboardingView()
            } else if app.profile == nil {
                BootstrappingView()  // brief flicker while profile loads
            } else if app.groups.isEmpty {
                EmptyGroupsView()
            } else {
                GroupsListView()
            }
        }
        .task { await app.start() }
    }
}

struct BootstrappingView: View {
    var body: some View {
        ZStack {
            MeshBackground()
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        }
    }
}
