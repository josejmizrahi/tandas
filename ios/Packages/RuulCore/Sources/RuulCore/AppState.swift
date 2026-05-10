import Foundation

@MainActor
@Observable
public final class AppState {
    public var session: AppSession?
    public var profile: Profile?
    public var groups: [RuulCore.Group] = []
    public var isBootstrapping: Bool = true
    public var bootstrapError: String?

    /// Currently selected group. Persisted across launches via UserDefaults
    /// so the user lands on the same group they were viewing last. Defaults
    /// to the first group on the user's list when unset or stale.
    public var activeGroupId: UUID? {
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
    public var activeGroup: RuulCore.Group? {
        if let id = activeGroupId, let g = groups.first(where: { $0.id == id }) {
            return g
        }
        return groups.first
    }

    private static let activeGroupKey = "ruul_active_group_id"

    /// Pending invite code from a Universal Link / custom URL scheme.
    /// When set, the onboarding root view routes to the invited flow.
    public var pendingInviteCode: String?

    /// Pending event deep link from a Universal Link / custom URL scheme /
    /// notification tap. MainTabView picks this up and routes to detail.
    public var pendingEventDeepLink: EventDeepLink?

    /// Pending rule_change deep link (Phase G3).
    public var pendingRuleChangeDeepLink: RuleChangeDeepLink?

    public let auth: any AuthService
    public let profileRepo: any ProfileRepository
    public let groupsRepo: any GroupsRepository
    public let inviteRepo: any InviteRepository
    public let ruleRepo: any RuleRepository
    public let voteRepo: any VoteRepository
    public let voteCastRepo: any VoteCastRepository
    public let governance: any GovernanceServiceProtocol
    public let otp: any OTPService
    public let templateRegistry: TemplateRegistry

    /// Catalog of platform modules. Boots cold from `ModuleRegistry.v1Fallback`
    /// and is replaced via `loadModuleRegistry(client:)` after the
    /// `list_modules()` RPC returns. Server-side `public.modules` (mig 00060)
    /// is the canonical source — V1Modules.swift is now just the offline
    /// fallback.
    public var moduleRegistry: ModuleRegistry = .v1Fallback

    /// Resolves runtime capabilities for the active group based on its
    /// template + activeModules. Computed so it always reflects the latest
    /// `moduleRegistry`; refreshing the registry post-boot automatically
    /// updates the resolver consumers see.
    public var capabilityResolver: CapabilityResolver {
        CapabilityResolver(modules: moduleRegistry)
    }

    // Event layer
    public let eventRepo: any EventRepository
    public let rsvpRepo: any RSVPRepository
    public let checkInRepo: any CheckInRepository
    public let notificationTokenRepo: any NotificationTokenRepository
    public let eventLifecycle: EventLifecycleService
    public let notifications: NotificationService?
    public let walletService: any WalletPassService
    public let analytics: any AnalyticsService

    // Platform layer
    public let systemEventRepo: any SystemEventRepository
    public let userActionRepo: any UserActionRepository
    public let appealRepo: any AppealRepository
    public let fineRepo: any FineRepository
    /// Polymorphic gateway to `public.resources` (Plan 1, Task 11).
    /// Read-only V1; writes still flow through resource-type-specific repos.
    public let resourceRepo: any ResourceRepository
    public let systemEventEmitter: SystemEventEmitter

    /// Builds an `RSVPRealtimeService` for a given event id. nil in mock /
    /// preview environments — coordinator falls back to manual refresh.
    public let realtimeFactory: ((UUID) -> RSVPRealtimeService)?

    public init(
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
        moduleRegistry: ModuleRegistry = .v1Fallback,
        eventRepo: any EventRepository,
        rsvpRepo: any RSVPRepository,
        checkInRepo: any CheckInRepository,
        notificationTokenRepo: any NotificationTokenRepository,
        systemEventRepo: any SystemEventRepository,
        userActionRepo: any UserActionRepository,
        appealRepo: any AppealRepository,
        fineRepo: any FineRepository,
        resourceRepo: any ResourceRepository,
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
        self.moduleRegistry = moduleRegistry
        self.eventRepo = eventRepo
        self.rsvpRepo = rsvpRepo
        self.checkInRepo = checkInRepo
        self.notificationTokenRepo = notificationTokenRepo
        self.systemEventRepo = systemEventRepo
        self.userActionRepo = userActionRepo
        self.appealRepo = appealRepo
        self.fineRepo = fineRepo
        self.resourceRepo = resourceRepo
        self.systemEventEmitter = SystemEventEmitter(repository: systemEventRepo)
        self.notifications = notifications
        self.walletService = walletService
        self.analytics = analytics
        self.realtimeFactory = realtimeFactory
        self.eventLifecycle = EventLifecycleService(eventRepo: eventRepo)
        if let raw = UserDefaults.standard.string(forKey: Self.activeGroupKey),
           let id = UUID(uuidString: raw) {
            self.activeGroupId = id
        }
    }

    /// Optional server loader for `moduleRegistry`. Wired by `TandasApp`
    /// in live mode; nil in mock/preview where `v1Fallback` is enough.
    public var moduleRegistryLoader: LiveModuleRegistry?

    /// Refreshes `moduleRegistry` from the server-side `public.modules`
    /// catalog (mig 00060). Falls back to the existing registry on error
    /// — the cold-start `v1Fallback` is always good enough for the V1
    /// surface, so a transient network blip doesn't degrade UX.
    public func loadModuleRegistry() async {
        guard let loader = moduleRegistryLoader else { return }
        do {
            self.moduleRegistry = try await loader.load()
        } catch {
            // Keep current (fallback or last-good) registry. Server drift
            // is checked by tests + CI parity, not by runtime.
        }
    }

    public func start() async {
        for await s in auth.sessionStream {
            self.session = s
            if s != nil {
                // list_modules() RPC is grant-restricted to authenticated;
                // refresh the catalog only once we have a session. v1Fallback
                // covers the pre-auth surface.
                await loadModuleRegistry()
                await refreshProfileAndGroups()
            } else {
                self.profile = nil
                self.groups = []
            }
            self.isBootstrapping = false
        }
    }

    public func refreshProfileAndGroups() async {
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
            self.profile = Profile(
                id: session?.user.id ?? UUID(),
                displayName: "",
                avatarUrl: nil,
                phone: session?.user.phone
            )
            self.groups = []
        }
    }

    public func handleIncomingURL(_ url: URL) {
        if let code = InviteLinkGenerator.parseInviteCode(from: url) {
            pendingInviteCode = code
        } else if let ruleLink = RuleChangeDeepLink(url: url) {
            pendingRuleChangeDeepLink = ruleLink
        } else if let link = EventDeepLink(url: url) {
            pendingEventDeepLink = link
        }
    }

    public func handleIncomingNotification(userInfo: [AnyHashable: Any]) {
        let kind = (userInfo["deep_link_kind"] as? String)
            ?? (userInfo["kind"] as? String)
            ?? "unknown"
        let beta = BetaAnalytics(analytics: analytics)
        Task { await beta.notificationTapped(kind: kind) }

        if let link = EventDeepLink(userInfo: userInfo) {
            pendingEventDeepLink = link
        }
    }

    public func consumePendingInvite() {
        pendingInviteCode = nil
    }

    public func consumeEventDeepLink() {
        pendingEventDeepLink = nil
    }

    public func consumeRuleChangeDeepLink() {
        pendingRuleChangeDeepLink = nil
    }
}
