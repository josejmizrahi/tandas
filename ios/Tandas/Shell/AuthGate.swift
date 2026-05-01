import SwiftUI

@MainActor
@Observable
final class AppState {
    var session: AppSession?
    var profile: Profile?
    var groups: [Group] = []
    var isBootstrapping: Bool = true
    var bootstrapError: String?

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
        bootstrapError = nil
        do {
            async let pTask = profileRepo.loadMine()
            async let gTask = groupsRepo.listMine()
            let (p, g) = try await (pTask, gTask)
            self.profile = p
            self.groups = g
        } catch {
            self.bootstrapError = "\(error)"
            // Fall through to OnboardingView with an empty profile so the user
            // isn't trapped on the spinner if the row is missing or RLS blocks.
            self.profile = Profile(
                id: session?.user.id ?? UUID(),
                displayName: "",
                avatarUrl: nil,
                phone: session?.user.phone
            )
            self.groups = []
        }
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
            } else {
                MainTabView()
            }
        }
        .task { await app.start() }
    }
}

struct BootstrappingView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            Brand.Surface.canvas.ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Brand.Surface.textPrimary)
                if let err = app.bootstrapError {
                    Text("Bootstrap error:\n\(err)")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        }
    }
}
