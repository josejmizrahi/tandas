import Foundation
import OSLog

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
    /// notification tap. `RootShell` picks this up and routes to detail.
    public var pendingEventDeepLink: EventDeepLink?

    /// Pending rule_change deep link (Phase G3).
    public var pendingRuleChangeDeepLink: RuleChangeDeepLink?

    /// Pending vote deep link (Level 15 — notification tap → vote detail).
    public var pendingVoteId: UUID?

    /// Pending fine deep link (Level 15 — notification tap → fine detail).
    public var pendingFineId: UUID?

    public let auth: any AuthService
    public let profileRepo: any ProfileRepository
    public let groupsRepo: any GroupsRepository
    public let inviteRepo: any InviteRepository
    public let ruleRepo: any RuleRepository
    public let voteRepo: any VoteRepository
    public let voteCastRepo: any VoteCastRepository
    /// CRUD + resolver over `public.group_policies` (mig 00087). Coordinators
    /// that mutate rules wrap `ruleRepo` in an `InterceptingRuleRepository`
    /// composed from this + `voteRepo` to get governance-aware writes.
    public let policyRepo: any GroupPolicyRepository
    public let governance: any GovernanceServiceProtocol
    public let otp: any OTPService
    public let templateRegistry: TemplateRegistry

    /// Catalog of platform modules. Boots cold from `ModuleRegistry.v1Fallback`
    /// and is replaced via `loadModuleRegistry(client:)` after the
    /// `list_modules()` RPC returns. Server-side `public.modules` (mig 00060)
    /// is the canonical source — V1Modules.swift is now just the offline
    /// fallback.
    public var moduleRegistry: ModuleRegistry = .v1Fallback

    /// Catalog of rule shapes (triggers/conditions/consequences). Boots
    /// cold from `RuleShapeRegistry.v1Fallback` and is refreshed by
    /// `loadRuleShapeRegistry()` after `list_rule_shapes` returns. Drives
    /// dynamic rule-builder forms — mig 00084 is the canonical source.
    public var ruleShapeRegistry: RuleShapeRegistry = .v1Fallback

    /// Catalog of curated rule templates for the Beta 1 Rule Builder.
    /// Boots cold from `MockRuleTemplateRepository.defaultBetaCatalog`
    /// (5 attendance-fine variants from mig 00182) and is refreshed by
    /// `loadRuleTemplates()` after `list_rule_templates` returns. Drives
    /// the Template Gallery + Param Form UI. Per Governance.md §0.5.
    public var ruleTemplates: [RuleBuilderTemplate] = MockRuleTemplateRepository.defaultBetaCatalog

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
    /// Triggers `send-event-notification` edge fn (host reminders, etc.)
    /// with a per-event 30-min rate limit. Beta 1 W1 D-1.1.
    public let eventNotificationDispatcher: any EventNotificationDispatcher
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
    /// Phase 2 Slice 2.3 RPC bindings (create_asset, create_slot,
    /// assign_slot, book_slot, request_slot_swap). Polymorphic over
    /// `resources` table; consumed by Asset/Slot/Booking UI in Slice 2.4.
    public let slotLifecycleRepo: any SlotLifecycleRepository
    /// Canonical asset spec lifecycle (mig 00200): custody, maintenance,
    /// valuation, transfer, checkout, usage, damage. Asset becomes a
    /// universal "objeto persistente socialmente gobernable" rather
    /// than a palco-shaped slot container.
    public let assetLifecycleRepo: any AssetLifecycleRepository

    // OpenPlatform Capability Foundation (post BigBang mig 00078)
    public let resourceSeriesRepo: any ResourceSeriesRepository
    public let resourceCapabilityRepo: any ResourceCapabilityRepository
    public let ledgerRepo: any LedgerRepository
    /// Tier 6 slice 18 (mig 00136): per-member balance projection over
    /// `ledger_entries`. Read-time aggregation, no cache. MoneySectionView
    /// renders top balances inline; group-wide views use balancesForGroup.
    public let balanceRepo: any BalanceRepository
    /// Mig 00198: per-fund balance + lifecycle (contribute/expense/lock).
    /// Reads from `fund_balance_view`; writers wrap `record_ledger_entry`
    /// with fund-specific invariants. Fund detail views read here.
    public let fundRepo: any FundRepository
    public let rsvpActionRepo: any RsvpActionRepository
    /// Atomic ResourceWizard submit — calls `build_resource_from_draft`
    /// RPC (mig 00101). Builders that route through this avoid the
    /// N-call orchestration that risked orphan rows on partial failure.
    /// Founder framing 2026-05-11 #5.
    public let resourceDraftRepo: any ResourceDraftRepository
    /// Right resource_type lifecycle: transfer/delegate/revoke/suspend/
    /// restore/exercise/updateMetadata. Mig 00198 + 00199.
    public let rightRepo: any RightRepository
    /// Space resource_type (mig 00203): list / get / create reservable
    /// venues. No dedicated table — reads `resources WHERE resource_type='space'`.
    public let spaceRepo: any SpaceRepository
    /// Slot resource_type (mig 00070 + 00204): typed reads of reservable
    /// asset windows. Writes go through `slotLifecycleRepo` (assign/book/swap)
    /// or `resourceDraftRepo` (wizard-driven create).
    public let slotRepo: any SlotRepository
    /// Bookings atom (mig 00216): append-only claims on slots. Read-only
    /// surface; writes flow through `slotLifecycleRepo.bookSlot` (which
    /// the refactored `book_slot` RPC now persists into this table
    /// instead of polymorphic resources).
    public let bookingRepo: any BookingRepository
    /// Pilot ResourceBuilder for events. Phase 2+ adds builders for slot,
    /// fund, asset following the same shape.
    public let eventBuilder: EventResourceBuilder

    /// Universal Resource Wizard registry — maps ResourceType → builder.
    /// Drives the type picker + final submit routing.
    public let resourceBuilders: ResourceBuilderRegistry

    public let systemEventEmitter: SystemEventEmitter

    /// Builds an `RSVPRealtimeService` for a given event id. nil in mock /
    /// preview environments — coordinator falls back to manual refresh.
    public let realtimeFactory: ((UUID) -> RSVPRealtimeService)?

    /// Cross-device sync feed (Beta 1 W3 E-3.1). nil in mock / preview;
    /// AppState `start()` activates it once a session is live, and
    /// `signOut()` tears it down before clearing the session.
    public let multiDeviceChangeFeed: (any MultiDeviceChangeFeed)?

    public init(
        auth: any AuthService,
        profileRepo: any ProfileRepository,
        groupsRepo: any GroupsRepository,
        inviteRepo: any InviteRepository,
        ruleRepo: any RuleRepository,
        voteRepo: any VoteRepository,
        voteCastRepo: any VoteCastRepository,
        policyRepo: any GroupPolicyRepository,
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
        slotLifecycleRepo: any SlotLifecycleRepository,
        assetLifecycleRepo: any AssetLifecycleRepository,
        resourceSeriesRepo: any ResourceSeriesRepository,
        resourceCapabilityRepo: any ResourceCapabilityRepository,
        ledgerRepo: any LedgerRepository,
        balanceRepo: any BalanceRepository,
        fundRepo: any FundRepository,
        rsvpActionRepo: any RsvpActionRepository,
        resourceDraftRepo: any ResourceDraftRepository,
        rightRepo: any RightRepository,
        spaceRepo: any SpaceRepository,
        slotRepo: any SlotRepository,
        bookingRepo: any BookingRepository,
        notifications: NotificationService? = nil,
        eventNotificationDispatcher: any EventNotificationDispatcher = MockEventNotificationDispatcher(),
        walletService: any WalletPassService = StubWalletPassService(),
        analytics: any AnalyticsService = LogAnalyticsService(),
        realtimeFactory: ((UUID) -> RSVPRealtimeService)? = nil,
        multiDeviceChangeFeed: (any MultiDeviceChangeFeed)? = nil
    ) {
        self.auth = auth
        self.profileRepo = profileRepo
        self.groupsRepo = groupsRepo
        self.inviteRepo = inviteRepo
        self.ruleRepo = ruleRepo
        self.voteRepo = voteRepo
        self.voteCastRepo = voteCastRepo
        self.policyRepo = policyRepo
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
        self.slotLifecycleRepo = slotLifecycleRepo
        self.assetLifecycleRepo = assetLifecycleRepo
        self.resourceSeriesRepo = resourceSeriesRepo
        self.resourceCapabilityRepo = resourceCapabilityRepo
        self.ledgerRepo = ledgerRepo
        self.balanceRepo = balanceRepo
        self.fundRepo = fundRepo
        self.rsvpActionRepo = rsvpActionRepo
        self.resourceDraftRepo = resourceDraftRepo
        self.rightRepo = rightRepo
        self.spaceRepo = spaceRepo
        self.slotRepo = slotRepo
        self.bookingRepo = bookingRepo
        let eventBuilder = EventResourceBuilder(
            eventRepo: eventRepo,
            ruleRepo: ruleRepo,
            capabilityRepo: resourceCapabilityRepo,
            seriesRepo: resourceSeriesRepo,
            resourceRepo: resourceRepo,
            draftRepo: resourceDraftRepo
        )
        let assetBuilder = AssetResourceBuilder(
            slotRepo: slotLifecycleRepo,
            capabilityRepo: resourceCapabilityRepo,
            draftRepo: resourceDraftRepo
        )
        // Tier 6 slice 19 (mig 00137): fund resource type unlocked
        // via build_resource_from_draft. Picker card flips from
        // "Próximamente" to creatable.
        let fundBuilder = FundResourceBuilder(draftRepo: resourceDraftRepo)
        // mig 00198: canonical `right` resource_type creation path. The
        // sixth Resource type — normative claims (derechos, equity,
        // membresías externas, custodia). Routes through
        // build_resource_from_draft → create_right RPC.
        let rightBuilder = RightResourceBuilder(draftRepo: resourceDraftRepo)
        // mig 00203: space resource_type creation path. Persistent
        // reservable venues (salón, cancha, sala). Routes through
        // build_resource_from_draft → create_space RPC.
        let spaceBuilder = SpaceResourceBuilder(draftRepo: resourceDraftRepo)
        // mig 00204: slot resource_type creation path. Reservable window
        // of a parent asset. The `BuilderField.resourcePicker` (shipped
        // commit 7e29b8d) is what unblocked the assetId selection from
        // the wizard; mig 00204 closes the SQL side. Routes through
        // build_resource_from_draft → create_slot RPC.
        let slotBuilder = SlotResourceBuilder(draftRepo: resourceDraftRepo)
        self.eventBuilder = eventBuilder
        self.resourceBuilders = ResourceBuilderRegistry(builders: [
            eventBuilder, assetBuilder, fundBuilder, rightBuilder, spaceBuilder, slotBuilder
        ])
        self.systemEventEmitter = SystemEventEmitter(repository: systemEventRepo)
        self.notifications = notifications
        self.eventNotificationDispatcher = eventNotificationDispatcher
        self.walletService = walletService
        self.analytics = analytics
        self.realtimeFactory = realtimeFactory
        self.multiDeviceChangeFeed = multiDeviceChangeFeed
        self.eventLifecycle = EventLifecycleService(eventRepo: eventRepo)
        if let raw = UserDefaults.standard.string(forKey: Self.activeGroupKey),
           let id = UUID(uuidString: raw) {
            self.activeGroupId = id
        }
    }

    /// Factory: builds an `InterceptingRuleRepository` for the given user.
    /// Coordinators that mutate rules call this to get a governance-aware
    /// wrapper around the raw `ruleRepo`. The wrapper consults
    /// `resolve_governance` before each write — direct-apply, vote-open,
    /// or denied — without changing the underlying live repo.
    ///
    /// Each call instantiates a fresh actor because `actorUserId` is
    /// pinned at construction; coordinators that outlive a session
    /// switch should rebuild this when `session.user.id` changes.
    public func makeInterceptingRuleRepo(userId: UUID) -> InterceptingRuleRepository {
        InterceptingRuleRepository(
            inner: ruleRepo,
            policyRepo: policyRepo,
            voteRepo: voteRepo,
            actorUserId: userId
        )
    }

    /// Optional server loader for `moduleRegistry`. Wired by `TandasApp`
    /// in live mode; nil in mock/preview where `v1Fallback` is enough.
    public var moduleRegistryLoader: LiveModuleRegistry?

    /// Optional server loader for `ruleShapeRegistry`. Wired by
    /// `TandasApp` in live mode. Mocks/previews rely on `v1Fallback`.
    public var ruleShapeRepo: (any RuleShapeRepository)?

    /// Optional server loader for `ruleTemplates`. Wired by `TandasApp`
    /// in live mode. Mocks/previews rely on the seed catalog in
    /// `MockRuleTemplateRepository.defaultBetaCatalog`.
    public var ruleTemplateRepo: (any RuleTemplateRepository)?

    /// `resource_links` gateway (mig 00198, Plans/Active/EventResource.md
    /// §12 — event uses space/asset/fund/right). Optional so existing
    /// AppState constructors don't break; UI sections degrade to a hidden
    /// state when nil. Wired by `TandasApp` in live mode; mocks/previews
    /// can assign a `MockResourceLinkRepository` directly.
    public var resourceLinkRepo: (any ResourceLinkRepository)?

    /// `event_lifecycle_view` gateway (mig 00207, Plans/Active/
    /// EventResource.md §17 — derived state from atoms). Optional so
    /// existing AppState constructors don't break; readers degrade to
    /// `resources.status` when nil. Wired by `TandasApp` in live mode.
    public var eventLifecycleRepo: (any EventLifecycleRepository)?

    /// Cross-group user activity feed (mig 00224, `my_activity_v1`).
    /// Optional so existing constructors don't break; `MyTimelineView`
    /// degrades to an empty state when nil. Wired by `TandasApp` in
    /// live mode; mock/preview environments can assign `MockMyActivityRepository`.
    public var myActivityRepo: (any MyActivityRepository)?

    /// Aggregated per-group stats (memberCount, balance, fines, votes, actions).
    /// Optional so existing constructors don't break; GroupHomeView degrades
    /// to hiding the summarySection when nil. Wired by `TandasApp` in
    /// live mode; mock/preview environments can assign `MockGroupSummaryRepository`.
    public var groupSummaryRepo: (any GroupSummaryRepository)?

    /// Per-user per-type notification opt-out (mig 00232).
    /// Optional so existing constructors don't break; `NotificationPreferencesView`
    /// degrades to showing default ON states when nil. Wired by `TandasApp`
    /// in live mode; mock/preview can assign `MockNotificationPreferenceRepository`.
    public var notificationPreferenceRepo: (any NotificationPreferenceRepository)?

    /// Refreshes `moduleRegistry` from the server-side `public.modules`
    /// catalog (mig 00060). Falls back to the existing registry on error
    /// — the cold-start `v1Fallback` is always good enough for the V1
    /// surface, so a transient network blip doesn't degrade UX.
    public func loadModuleRegistry() async {
        guard let loader = moduleRegistryLoader else { return }
        do {
            let server = try await loader.load()
            let drift = ModuleRegistry.v1Fallback.drift(against: server)
            if drift.hasDrift {
                Self.driftLog.warning(
                    "Module catalog drift vs v1Fallback — missing on server: \(drift.missingFromOther, privacy: .public); extra on server: \(drift.extraInOther, privacy: .public)"
                )
            }
            self.moduleRegistry = server
        } catch {
            // Keep current (fallback or last-good) registry. Transient
            // network blips don't degrade UX; the v1Fallback covers V1.
        }
    }

    private static let driftLog = Logger(
        subsystem: "com.josejmizrahi.ruul",
        category: "module-registry"
    )

    /// Refreshes `ruleShapeRegistry` from `list_rule_shapes` (mig 00084).
    /// Same resilience contract as `loadModuleRegistry`: silent on error,
    /// previously-loaded (or fallback) registry stays usable.
    public func loadRuleShapeRegistry() async {
        guard let repo = ruleShapeRepo else { return }
        do {
            self.ruleShapeRegistry = try await repo.load()
        } catch {
            // Keep v1Fallback / last-good registry on failure.
        }
    }

    /// Refreshes `ruleTemplates` from `list_rule_templates` (mig 00182).
    /// Same resilience contract: silent on error, last-good catalog stays.
    public func loadRuleTemplates() async {
        guard let repo = ruleTemplateRepo else { return }
        do {
            self.ruleTemplates = try await repo.loadTemplates()
        } catch {
            // Keep seed catalog on failure.
        }
    }

    public func start() async {
        for await s in auth.sessionStream {
            self.session = s
            if s != nil {
                // list_modules() RPC is grant-restricted to authenticated;
                // refresh the catalog only once we have a session. v1Fallback
                // covers the pre-auth surface.
                async let modules:   Void = loadModuleRegistry()
                async let shapes:    Void = loadRuleShapeRegistry()
                async let templates: Void = loadRuleTemplates()
                _ = await (modules, shapes, templates)
                await refreshProfileAndGroups()
                // Beta 1 W3 E-3.1: open cross-device realtime channels
                // once we have a session. RLS scopes incoming rows so a
                // single un-filtered channel per table is enough.
                await multiDeviceChangeFeed?.start()
            } else {
                self.profile = nil
                self.groups = []
                await multiDeviceChangeFeed?.stop()
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

    /// Sign out + revoke the device's APNs token in one step. Use this
    /// everywhere instead of calling `auth.signOut()` directly: a bare
    /// `auth.signOut` leaves the `notification_tokens` row owned by the
    /// now-gone session, so a shared device that swaps users keeps
    /// receiving pushes addressed to the original account.
    ///
    /// The revoke is best-effort — failures are logged inside
    /// `NotificationService.revokeTokenIfRegistered()` but never block the
    /// sign-out. The user always ends up logged out client-side even if
    /// the server-side revoke didn't reach the DB.
    public func signOut() async throws {
        await notifications?.revokeTokenIfRegistered()
        await multiDeviceChangeFeed?.stop()
        try await auth.signOut()
    }

    public func handleIncomingURL(_ url: URL) {
        // Invite codes take precedence (ruul://invite/...)
        if let code = InviteLinkGenerator.parseInviteCode(from: url) {
            pendingInviteCode = code
            return
        }
        // Unified deeplink catalog (Level 15)
        if let link = NotificationDeepLink(url: url) {
            applyDeepLink(link)
            return
        }
        // Legacy fallbacks for back-compat
        if let ruleLink = RuleChangeDeepLink(url: url) {
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

        // Unified deeplink catalog (Level 15)
        if let link = NotificationDeepLink(userInfo: userInfo) {
            applyDeepLink(link)
            return
        }
        // Legacy fallback
        if let link = EventDeepLink(userInfo: userInfo) {
            pendingEventDeepLink = link
        }
    }

    private func applyDeepLink(_ link: NotificationDeepLink) {
        switch link {
        case .event(let id):
            pendingEventDeepLink = EventDeepLink(eventId: id)
        case .vote(let id):
            pendingVoteId = id
        case .fine(let id):
            pendingFineId = id
        case .ruleChange(let ruleId, let amount):
            // Reconstruct the canonical URL so RuleChangeDeepLink.init?(url:) can parse it.
            let proposedAmount = amount ?? 0
            if let url = URL(string: "ruul://rule/\(ruleId.uuidString)/edit?proposedAmount=\(proposedAmount)"),
               let ruleLink = RuleChangeDeepLink(url: url) {
                pendingRuleChangeDeepLink = ruleLink
            }
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

    public func consumeVoteDeepLink() {
        pendingVoteId = nil
    }

    public func consumeFineDeepLink() {
        pendingFineId = nil
    }
}
