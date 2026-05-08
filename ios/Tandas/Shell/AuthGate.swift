import SwiftUI
import RuulUI

@MainActor
@Observable
final class AppState {
    var session: AppSession?
    var profile: Profile?
    var groups: [Group] = []
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
    var activeGroup: Group? {
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
        // No proactive anon sign-in. Anonymous sessions are an
        // implementation detail of `GroupsRepository.createInitial`
        // (it has a reactive sign-out + anon + retry path) — the app
        // launch must NOT pre-create one, otherwise:
        //   - Returning logged-out users get a fresh anon session and
        //     AuthGate's `session != nil` short-circuits SignInView,
        //     dragging them back into onboarding.
        //   - First-time users on an old keychain (reinstall with a
        //     stale-but-still-decryptable session) get the same.
        //
        // First-time founders without a session get their anon at the
        // moment they tap "Continuar" on GroupIdentityView, which is
        // also the moment we have a real intent to create data.
        for await s in auth.sessionStream {
            self.session = s
            if let s {
                // Defensive: a real (email/phone) session means the
                // user has authenticated at some point on this device.
                // If the keychain restored a session but the
                // `hasOnboarded` flag is missing (e.g. legacy device
                // pre-keychain-migration, or a fresh install where
                // keychain survived but UserDefaults didn't), promote
                // it now so AuthGate routes to SignInView next time
                // they sign out instead of founder onboarding.
                let isReal = s.user.email != nil || s.user.phone != nil
                if isReal && !OnboardingCompletion.hasOnboarded {
                    OnboardingCompletion.mark()
                }
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
            } else if app.session == nil && hasOnboarded {
                // Returning user logged out: ALWAYS go to SignInView.
                // Above the onboarding branch so a stale
                // OnboardingProgress row can't drag the user back
                // into the flow.
                SignInView()
            } else if hasActiveOnboarding || shouldShowOnboarding {
                // Single branch (consolidated): SwiftUI keeps the
                // OnboardingRootView's @State coordinatorBundle
                // alive across `hasActiveOnboarding` flicker (e.g.,
                // when the entity gets persisted mid-flow flipping
                // the flag from false → true). Splitting into two
                // branches with the same content caused view-tree
                // resets that re-ran bootstrap and recreated the
                // coordinator at .identity, dropping the user back
                // to "¿Cómo te llamas?" mid-flow.
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

    /// Onboarding shows for first-time users. Returning users (hasOnboarded
    /// flag set, session nil) see SignInView instead — handled above.
    private var shouldShowOnboarding: Bool {
        app.session == nil
            || (app.profile?.needsOnboarding ?? false)
            || app.groups.isEmpty
    }

    @MainActor
    private func refreshOnboardingState() async {
        let manager = OnboardingProgressManager(context: modelContext)
        // Stale-entity policy. We only clear when we are confident no
        // active onboarding could be in progress:
        //
        //   - `isCleanLoggedOut`: session is nil AND the device has
        //     completed onboarding before. SignInView will take over.
        //
        //   - `hasUsableGroup`: a real (non-anon) auth session exists
        //     AND at least one group is loaded. The user has finished
        //     onboarding — any persisted entity is residue. We detect
        //     "real session" via session.user.email/phone so an anon
        //     session created mid-flow (groups still empty for ms)
        //     does not trip this branch.
        //
        // We deliberately do NOT clear just because `hasOnboarded ==
        // true`: a returning user starting a SECOND onboarding flow
        // (after re-installing or "Crear cuenta nueva") still has the
        // flag set from before, and clearing would wipe their fresh
        // entity mid-flow → re-bootstrap → coord.start() → bounce
        // back to identity.
        let isCleanLoggedOut = app.session == nil && hasOnboarded
        let isAnonSession = (app.session?.user.email == nil) && (app.session?.user.phone == nil)
        let hasUsableGroup = app.session != nil && !isAnonSession && !app.groups.isEmpty
        if isCleanLoggedOut || hasUsableGroup {
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
