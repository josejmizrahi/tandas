import SwiftUI

@MainActor
@Observable
final class AppState {
    var session: AppSession?
    var profile: Profile?
    var groups: [Group] = []
    var isBootstrapping: Bool = true

    /// Pending invite code from a Universal Link / custom URL scheme.
    /// When set, the onboarding root view routes to the invited flow.
    var pendingInviteCode: String?

    let auth: any AuthService
    let profileRepo: any ProfileRepository
    let groupsRepo: any GroupsRepository
    let inviteRepo: any InviteRepository
    let ruleRepo: any RuleRepository
    let otp: any OTPService

    init(
        auth: any AuthService,
        profileRepo: any ProfileRepository,
        groupsRepo: any GroupsRepository,
        inviteRepo: any InviteRepository,
        ruleRepo: any RuleRepository,
        otp: any OTPService
    ) {
        self.auth = auth
        self.profileRepo = profileRepo
        self.groupsRepo = groupsRepo
        self.inviteRepo = inviteRepo
        self.ruleRepo = ruleRepo
        self.otp = otp
    }

    func start() async {
        for await s in await auth.sessionStream {
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

    func handleIncomingURL(_ url: URL) {
        if let code = InviteLinkGenerator.parseInviteCode(from: url) {
            pendingInviteCode = code
        }
    }

    func consumePendingInvite() {
        pendingInviteCode = nil
    }
}

struct AuthGate: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var modelContext
    @State private var hasActiveOnboarding: Bool = false
    @State private var hasCheckedOnboarding: Bool = false

    var body: some View {
        SwiftUI.Group {
            if app.isBootstrapping || !hasCheckedOnboarding {
                BootstrappingView()
            } else if shouldShowOnboarding {
                OnboardingRootView(pendingInviteCode: app.pendingInviteCode) { _ in
                    Task {
                        app.consumePendingInvite()
                        await refreshOnboardingState()
                        await app.refreshProfileAndGroups()
                    }
                }
            } else {
                MainPlaceholderView()
            }
        }
        .task {
            await app.start()
            await refreshOnboardingState()
        }
    }

    /// Onboarding shows when:
    /// - There's an active OnboardingProgress row in SwiftData (covers the
    ///   case where the founder is mid-flow at step 5b OTP — session
    ///   becomes non-nil but flow isn't done), OR
    /// - The user is logged out (fresh launch / pending invite).
    private var shouldShowOnboarding: Bool {
        hasActiveOnboarding || app.session == nil || (app.profile?.needsOnboarding ?? false)
    }

    @MainActor
    private func refreshOnboardingState() async {
        let manager = OnboardingProgressManager(context: modelContext)
        hasActiveOnboarding = (try? manager.loadActive()) != nil
        hasCheckedOnboarding = true
    }
}

struct BootstrappingView: View {
    var body: some View {
        ZStack {
            RuulMeshBackground(.cool)
            ProgressView()
                .controlSize(.large)
                .tint(Color.ruulAccentPrimary)
        }
    }
}

/// Placeholder shown post-onboarding until the home/main-app prompt lands.
struct MainPlaceholderView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            VStack(spacing: RuulSpacing.s4) {
                if let profile = app.profile {
                    Text("Hola, \(profile.displayName)")
                        .ruulTextStyle(RuulTypography.titleLarge)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
                Text("Próximamente: home, eventos, multas.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            .padding(RuulSpacing.s5)
        }
    }
}
