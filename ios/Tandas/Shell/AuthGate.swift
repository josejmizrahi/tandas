import SwiftUI

@MainActor
@Observable
final class AppState {
    var session: AppSession?
    var profile: Profile?
    var groups: [Group] = []
    var isBootstrapping: Bool = true
    var bootstrapError: String?

    /// Pending invite code from a Universal Link / custom URL scheme.
    /// When set, the onboarding root view routes to the invited flow.
    var pendingInviteCode: String?

    /// Pending event deep link from a Universal Link / custom URL scheme /
    /// notification tap. MainTabView picks this up and routes to detail.
    var pendingEventDeepLink: EventDeepLink?

    let auth: any AuthService
    let profileRepo: any ProfileRepository
    let groupsRepo: any GroupsRepository
    let inviteRepo: any InviteRepository
    let ruleRepo: any RuleRepository
    let otp: any OTPService

    // Event layer
    let eventRepo: any EventRepository
    let rsvpRepo: any RSVPRepository
    let checkInRepo: any CheckInRepository
    let notificationTokenRepo: any NotificationTokenRepository
    let eventLifecycle: EventLifecycleService
    let notifications: NotificationService?
    let walletService: any WalletPassService
    let analytics: any AnalyticsService

    init(
        auth: any AuthService,
        profileRepo: any ProfileRepository,
        groupsRepo: any GroupsRepository,
        inviteRepo: any InviteRepository,
        ruleRepo: any RuleRepository,
        otp: any OTPService,
        eventRepo: any EventRepository,
        rsvpRepo: any RSVPRepository,
        checkInRepo: any CheckInRepository,
        notificationTokenRepo: any NotificationTokenRepository,
        notifications: NotificationService? = nil,
        walletService: any WalletPassService = StubWalletPassService(),
        analytics: any AnalyticsService = LogAnalyticsService()
    ) {
        self.auth = auth
        self.profileRepo = profileRepo
        self.groupsRepo = groupsRepo
        self.inviteRepo = inviteRepo
        self.ruleRepo = ruleRepo
        self.otp = otp
        self.eventRepo = eventRepo
        self.rsvpRepo = rsvpRepo
        self.checkInRepo = checkInRepo
        self.notificationTokenRepo = notificationTokenRepo
        self.notifications = notifications
        self.walletService = walletService
        self.analytics = analytics
        self.eventLifecycle = EventLifecycleService(eventRepo: eventRepo)
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

    func handleIncomingURL(_ url: URL) {
        if let code = InviteLinkGenerator.parseInviteCode(from: url) {
            pendingInviteCode = code
        } else if let link = EventDeepLink(url: url) {
            pendingEventDeepLink = link
        }
    }

    func handleIncomingNotification(userInfo: [AnyHashable: Any]) {
        if let link = EventDeepLink(userInfo: userInfo) {
            pendingEventDeepLink = link
        }
    }

    func consumePendingInvite() {
        pendingInviteCode = nil
    }

    func consumeEventDeepLink() {
        pendingEventDeepLink = nil
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
                MainTabView()
            }
        }
        .task { await app.start() }
        .task { await refreshOnboardingState() }
    }

    /// Onboarding shows when:
    /// - There's an active OnboardingProgress row in SwiftData (covers the
    ///   case where the founder is mid-flow at OTP — session becomes
    ///   non-nil but flow isn't done), OR
    /// - The user is logged out, OR
    /// - The user has no groups yet.
    private var shouldShowOnboarding: Bool {
        hasActiveOnboarding
            || app.session == nil
            || (app.profile?.needsOnboarding ?? false)
            || app.groups.isEmpty
    }

    @MainActor
    private func refreshOnboardingState() async {
        let manager = OnboardingProgressManager(context: modelContext)
        hasActiveOnboarding = (try? manager.loadActive()) != nil
        hasCheckedOnboarding = true
    }
}

struct BootstrappingView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            ProgressView()
                .controlSize(.large)
                .tint(Color.ruulAccentPrimary)
        }
    }
}
