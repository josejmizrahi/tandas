import SwiftUI
import RuulUI
import RuulCore

@MainActor
@Observable
final class AppState {
    var session: AppSession?
    var profile: Profile?
    var groups: [RuulCore.Group] = []
    var isBootstrapping: Bool = true
    var bootstrapError: String?

    /// Currently selected group. Persisted across launches via UserDefaults
    /// so the user lands on the same group they were viewing last. Defaults
    /// to the first group on the user's list when unset or stale.
    var activeGroupId: UUID? {
        didSet {
            if let id = activeGroupId {
                UserDefaults.standard.set(id.uuidString, forKey: Self.activeGroupKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeGroupKey)
            }
        }
    }

    /// Resolves to the active group if it's still in `groups`, otherwise
    /// falls back to the first group. nil only if the user has zero groups.
    var activeGroup: RuulCore.Group? {
        if let id = activeGroupId, let g = groups.first(where: { $0.id == id }) {
            return g
        }
        return groups.first
    }

    private static let activeGroupKey = "ruul_active_group_id"

    /// Pending invite code from a Universal Link / custom URL scheme.
    /// When set, the onboarding root view routes to the invited flow.
    var pendingInviteCode: String?

    /// Pending event deep link from a Universal Link / custom URL scheme /
    /// notification tap. MainTabView picks this up and routes to detail.
    var pendingEventDeepLink: EventDeepLink?

    /// Pending rule_change deep link (Phase G3). Source: APNs push payload
    /// `deep_link` field written by `finalize_vote` v3 (migration 00032)
    /// when a rule_change vote resolves passed, or any URL of the form
    /// `ruul://rule/<UUID>/edit?proposedAmount=<Int>`. MainTabView picks
    /// this up and presents `EditRuleSheet` pre-loaded with the proposed
    /// amount + the originating UserAction id (when reachable from inbox).
    var pendingRuleChangeDeepLink: RuleChangeDeepLink?

    let auth: any AuthService
    let profileRepo: any ProfileRepository
    let groupsRepo: any GroupsRepository
    let inviteRepo: any InviteRepository
    let ruleRepo: any RuleRepository
    let voteRepo: any VoteRepository
    let voteCastRepo: any VoteCastRepository
    let governance: any GovernanceServiceProtocol
    let otp: any OTPService
    let templateRegistry: TemplateRegistry

    // Event layer
    let eventRepo: any EventRepository
    let rsvpRepo: any RSVPRepository
    let checkInRepo: any CheckInRepository
    let notificationTokenRepo: any NotificationTokenRepository
    let eventLifecycle: EventLifecycleService
    let notifications: NotificationService?
    let walletService: any WalletPassService
    let analytics: any AnalyticsService

    // Platform layer (Sprint 1a). Models + repos live; the rule engine is
    // server-side, in `process-system-events` / `evaluate-event-rules` edge
    // functions. The Swift side only emits via SystemEventEmitter and reads
    // back via the repos for inbox / appeals UI in Sprint 1c.
    let systemEventRepo: any SystemEventRepository
    let userActionRepo: any UserActionRepository
    let appealRepo: any AppealRepository
    let fineRepo: any FineRepository
    let systemEventEmitter: SystemEventEmitter

    /// Builds an `RSVPRealtimeService` for a given event id. nil in mock /
    /// preview environments — coordinator falls back to manual refresh.
    let realtimeFactory: ((UUID) -> RSVPRealtimeService)?

    init(
        auth: any AuthService,
        profileRepo: any ProfileRepository,
        groupsRepo: any GroupsRepository,
        inviteRepo: any InviteRepository,
        ruleRepo: any RuleRepository,
        voteRepo: any VoteRepository,
        voteCastRepo: any VoteCastRepository,
        governance: any GovernanceServiceProtocol,
        otp: any OTPService,
        templateRegistry: TemplateRegistry,
        eventRepo: any EventRepository,
        rsvpRepo: any RSVPRepository,
        checkInRepo: any CheckInRepository,
        notificationTokenRepo: any NotificationTokenRepository,
        systemEventRepo: any SystemEventRepository,
        userActionRepo: any UserActionRepository,
        appealRepo: any AppealRepository,
        fineRepo: any FineRepository,
        notifications: NotificationService? = nil,
        walletService: any WalletPassService = StubWalletPassService(),
        analytics: any AnalyticsService = LogAnalyticsService(),
        realtimeFactory: ((UUID) -> RSVPRealtimeService)? = nil
    ) {
        self.auth = auth
        self.profileRepo = profileRepo
        self.groupsRepo = groupsRepo
        self.inviteRepo = inviteRepo
        self.ruleRepo = ruleRepo
        self.voteRepo = voteRepo
        self.voteCastRepo = voteCastRepo
        self.governance = governance
        self.otp = otp
        self.templateRegistry = templateRegistry
        self.eventRepo = eventRepo
        self.rsvpRepo = rsvpRepo
        self.checkInRepo = checkInRepo
        self.notificationTokenRepo = notificationTokenRepo
        self.systemEventRepo = systemEventRepo
        self.userActionRepo = userActionRepo
        self.appealRepo = appealRepo
        self.fineRepo = fineRepo
        self.systemEventEmitter = SystemEventEmitter(repository: systemEventRepo)
        self.notifications = notifications
        self.walletService = walletService
        self.analytics = analytics
        self.realtimeFactory = realtimeFactory
        self.eventLifecycle = EventLifecycleService(eventRepo: eventRepo)
        // Restore last-active group selection. If the persisted id doesn't
        // match any current group at refresh time, `activeGroup` falls back
        // to groups.first.
        if let raw = UserDefaults.standard.string(forKey: Self.activeGroupKey),
           let id = UUID(uuidString: raw) {
            self.activeGroupId = id
        }
    }

    func start() async {
        // Sign-in-first architecture: the app never creates an
        // anonymous session. AuthGate routes to SignInView for any
        // unauthenticated launch, and the founder onboarding only
        // runs AFTER the user has signed in with Apple or phone OTP.
        //
        // Why we removed the anon path:
        //   - The previous "anon at launch + signInWithIdToken to
        //     promote to Apple later" pattern relied on Supabase
        //     reliably linking the anon user to the OAuth identity.
        //     In practice the link could fail and the group created
        //     during onboarding stayed orphaned to the anon user_id,
        //     leaving the verified user with `groups.isEmpty` post-
        //     sign-in and bouncing them back into onboarding forever.
        //   - The Supabase project now disables anonymous sign-ins
        //     entirely, so any attempt to fall back to anon would
        //     fail with `anonymous_provider_disabled` anyway.
        //
        // `OnboardingCompletion.mark()` is still called explicitly at
        // the end of the founder/invited flow and survives reinstall
        // via Keychain. We deliberately do NOT auto-mark on every
        // real session: that would short-circuit the first-time
        // guided flow for a user signing in for the first time
        // (a real session + empty groups would look "complete" and
        // route them to MainTabView's empty state instead of the
        // create-your-group flow).
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
            async let tTask: Void = templateRegistry.refresh()
            let (p, g) = try await (pTask, gTask)
            await tTask
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
        } else if let ruleLink = RuleChangeDeepLink(url: url) {
            // Try rule_change first — its scheme is `ruul://rule/...` so it
            // can't collide with `ruul://event/...`. Both inits are
            // null-returning for non-matching URLs, so order is just
            // a small tail-latency win.
            pendingRuleChangeDeepLink = ruleLink
        } else if let link = EventDeepLink(url: url) {
            pendingEventDeepLink = link
        }
    }

    func handleIncomingNotification(userInfo: [AnyHashable: Any]) {
        // Beta 1 instrumentation (Plans/Active/Beta1.md §4): track which
        // push notif kinds users actually act on. `kind` discriminator
        // mirrors what `dispatch-notifications` writes into the deep
        // link path (event/rule/vote/fine/invite/appeal).
        let kind = (userInfo["deep_link_kind"] as? String)
            ?? (userInfo["kind"] as? String)
            ?? "unknown"
        let beta = BetaAnalytics(analytics: analytics)
        Task { await beta.notificationTapped(kind: kind) }

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

    func consumeRuleChangeDeepLink() {
        pendingRuleChangeDeepLink = nil
    }
}

struct AuthGate: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var modelContext
    /// Mirrors `OnboardingCompletion.hasOnboarded` (Keychain-backed). We
    /// can't use `@AppStorage` because the flag lives in Keychain so it
    /// survives reinstalls; instead we re-read it on `.task` and on the
    /// `OnboardingCompletion.didChangeNotification` published by mark/clear.
    @State private var hasOnboarded: Bool = OnboardingCompletion.hasOnboarded
    @State private var hasActiveOnboarding: Bool = false
    @State private var hasCheckedOnboarding: Bool = false

    var body: some View {
        SwiftUI.Group {
            if app.isBootstrapping || !hasCheckedOnboarding {
                BootstrappingView()
            } else if app.session == nil {
                // Sign-in-first architecture: ANY unauthenticated state
                // routes here, including a brand-new device. There is
                // no anon-session entry into onboarding anymore — the
                // pre-Apple founder flow created groups under the anon
                // user_id and `signInWithIdToken` did not always link
                // them to the verified account, leaving groups
                // orphaned to a user nobody can sign back in as.
                // SignInView handles both Apple Sign In and Phone OTP;
                // both providers auto-create users on first-use, so
                // there is no separate "create account" path.
                SignInView()
            } else if hasActiveOnboarding || isFirstTimeAuth {
                // Authenticated branch: either we're mid-onboarding
                // (entity persisted, restoring on relaunch) OR this is
                // the user's first sign-in on this account and they
                // need the guided "name your group / invite friends"
                // flow.
                //
                // Single branch (consolidated): SwiftUI keeps the
                // OnboardingRootView's @State coordinatorBundle alive
                // across `hasActiveOnboarding` flicker (the flag
                // flips false→true after the first persist). Splitting
                // into two branches with the same content caused
                // view-tree resets that dropped the user back to
                // "¿Cómo te llamas?" mid-flow.
                onboardingFlow
            } else {
                MainTabView()
            }
        }
        .task { await app.start() }
        .task { await refreshOnboardingState() }
        .onChange(of: app.session?.user.id) { _, _ in
            Task { await refreshOnboardingState() }
        }
        // Keychain has no Combine surface, so listen for the explicit
        // mark/clear notification. Without this, SignInView's "Crear
        // nueva" tap would mutate keychain but AuthGate wouldn't
        // re-render until the next session change.
        .onReceive(NotificationCenter.default.publisher(for: OnboardingCompletion.didChangeNotification)) { _ in
            hasOnboarded = OnboardingCompletion.hasOnboarded
        }
    }

    private var onboardingFlow: some View {
        OnboardingRootView(pendingInviteCode: app.pendingInviteCode) { _ in
            Task {
                app.consumePendingInvite()
                await refreshOnboardingState()
                await app.refreshProfileAndGroups()
            }
        }
    }

    /// True for an authenticated user landing on this device for the
    /// first time: they have a real session but no record of having
    /// finished onboarding (`hasOnboarded` flag) AND no groups loaded
    /// for their account.
    ///
    /// Heuristic. The 100%-correct signal would be a server-side
    /// `profiles.onboarded_at` column; the heuristic mis-classifies a
    /// returning user whose groups vanished (left them all, or got
    /// orphaned to an old anon user_id) as "first time". Acceptable
    /// trade-off: those users land in the create-first-group flow,
    /// recover by creating a fresh group under their real user_id,
    /// and `OnboardingCompletion.mark()` at completion time prevents
    /// any future re-entry.
    private var isFirstTimeAuth: Bool {
        app.session != nil && app.groups.isEmpty && !hasOnboarded
    }

    @MainActor
    private func refreshOnboardingState() async {
        let manager = OnboardingProgressManager(context: modelContext)
        // Stale-entity policy under the sign-in-first architecture.
        // We only persist an OnboardingProgress while a session exists
        // and the user is genuinely in the create-first-group flow.
        // Anything else is residue:
        //   - `loggedOut`: session is nil → SignInView will take over,
        //     so any leftover onboarding row is from an abandoned flow.
        //   - `hasGroup`: at least one group loaded → the user is past
        //     the only step that creates persisted state. They belong
        //     in MainTabView, so the entity is residue.
        //
        // We deliberately do NOT clear an entity for an authenticated
        // user with `groups.isEmpty` and `!hasOnboarded`: that's the
        // mid-flow first-time founder, whose entity is *exactly* what
        // keeps the coordinator restoring at the right step on
        // relaunch.
        let loggedOut = app.session == nil
        let hasGroup = app.session != nil && !app.groups.isEmpty
        if loggedOut || hasGroup {
            try? manager.clear()
        }
        hasActiveOnboarding = (try? manager.loadActive()) != nil
        hasCheckedOnboarding = true
    }
}

struct BootstrappingView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            ProgressView()
                .controlSize(.large)
                .tint(Color.ruulAccent)
        }
    }
}
