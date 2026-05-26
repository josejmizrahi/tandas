import Foundation
import Observation
import OSLog
import RuulCore

@Observable
@MainActor
public final class GroupHomeCoordinator {
    public let groupId: UUID
    private let groupsRepo: any GroupsRepository
    private let moduleRegistry: ModuleRegistry
    private let groupSummaryRepo: (any GroupSummaryRepository)?
    private let userActionRepo: (any UserActionRepository)?
    private let myActivityRepo: (any MyActivityRepository)?
    private let systemEventRepo: (any SystemEventRepository)?
    private let eventRepo: (any EventRepository)?
    private let fineRepo: (any FineRepository)?
    private let fundRepo: (any FundRepository)?
    private let resourceRepo: (any ResourceRepository)?
    private let ledgerRepo: (any LedgerRepository)?
    /// 2026-05-25: polymorphic "Próximo" sources. `voteRepo` powers
    /// `.voteClosing` items; `slotRepo` powers `.slotRotation`.
    private let voteRepo: (any VoteRepository)?
    private let slotRepo: (any SlotRepository)?
    private let actorUserId: UUID?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "group.home")

    /// Multi-device change-feed subscription. Mirrors the
    /// `InboxCoordinator` pattern (RootShell L157-178): when another
    /// device resolves a UserAction, this coordinator's
    /// `pendingActions` reloads so the group home doesn't drift from
    /// the home tab's inbox. Pre-2026-05-24 this coordinator was the
    /// only one of the three pending sources without a change-feed
    /// subscription, producing visible inconsistency cross-tab.
    nonisolated(unsafe) private var changeFeedTask: Task<Void, Never>?

    public var group: Group?
    public var memberCount: Int = 0
    public var myRole: String?          // "founder" | "member" | "admin"
    /// Verbatim roles from `group_members.roles` jsonb for the calling
    /// user. Drives Phase 5 permission-gated affordances in
    /// `GroupSpaceView`. Empty until the first successful refresh.
    public var myRawRoles: [String] = []
    public var activeModules: [GroupModule] = []
    /// Sample of members for the PresenceHeader avatar stack. Top 8
    /// fetched in parallel with `refresh()`; never errors hard — empty
    /// stack is acceptable degradation.
    public var members: [MemberWithProfile] = []
    /// Full membership (not capped at 8 like `members`). Drives the
    /// payer/recipient pickers in `RecordSharedExpenseSheet`. Populated
    /// alongside `members` in `loadMembers`.
    public var allMembers: [MemberWithProfile] = []
    /// Recent items from `my_activity_v1` filtered to this group. Top
    /// 5, newest first. Populated only if `myActivityRepo` is wired.
    public var recentActivity: [MyActivityItem] = []
    /// Pending UserActions for the current user in this group. Drives
    /// the PendingsBlock list. Loaded in parallel with summary.
    public var pendingActions: [UserAction] = []
    /// Counts surfaced by the SpacesGrid tiles. Computed via the same
    /// repos the tile destinations use (eventRepo / fineRepo /
    /// fundRepo) so the tile count matches the list length — the old
    /// GroupSummary path counted "resources WHERE status=open" which
    /// drifted from `upcomingEvents`'s real filter.
    public var upcomingEventsCount: Int = 0
    public var groupFinesCount: Int = 0
    /// Funds for this group (one row per fund+currency) — backs the
    /// "Otros fondos" tile count, which excludes the canonical shared
    /// pool (it has its own `SharedMoneyCard` surface).
    public var groupFunds: [Fund] = []
    /// Count of NON-shared-pool funds, distinct by `fundId`. The
    /// "Otros fondos" tile uses this and hides entirely at 0 (founder
    /// decision 2, 2026-05-21). Cross-references the shared pool via id
    /// per founder decision 9.1 option (c) — zero schema change.
    public var otherFundsCount: Int {
        let sharedId = sharedPoolSummary?.sharedPoolId
        let ids = Set(groupFunds.lazy.filter { $0.fundId != sharedId }.map { $0.fundId })
        return ids.count
    }
    /// SharedMoney Phase 3 (mig 00361): the group's canonical shared
    /// pool projection. Drives `SharedMoneyCard`. Loaded in parallel via
    /// `fundRepo.summaryForGroup`; nil until the first successful load
    /// (or when `fundRepo` isn't wired, e.g. lightweight previews).
    public var sharedPoolSummary: SharedPoolSummary?
    /// SharedMoney Phase 4 brick C.2: active assets in this group
    /// (resource_type = 'asset', status != archived). Backs the
    /// "Activos" tile count. Loaded in parallel via `resourceRepo.list`;
    /// empty until first successful load (or if `resourceRepo` isn't
    /// wired). The tile hides entirely when this is empty.
    public var groupAssets: [ResourceRow] = []
    public var groupAssetsCount: Int { groupAssets.count }
    /// SharedMoney P3 (mig 00136): all members' net positions in this
    /// group, derived from `member_balances_per_group`. Drives the
    /// "Tu posición" card on GroupSpaceView + `GroupBalancesView`
    /// subscreen. Empty until first load (or when `ledgerRepo`/
    /// `actorUserId` isn't wired).
    public var groupBalances: [MemberGroupBalance] = []
    /// FASE 4 Wave 4 Phase 3 (mig 20260525230000): per-member breakdown
    /// of stake / receivable / obligation / settlement net. The greedy
    /// peer-settlement plan reads `netPeerPositionCents` from these
    /// rows (NOT `groupBalances.netCents`, which conflates aportes
    /// con deuda). Empty until first load.
    public var groupObligations: [MemberObligationSummary] = []

    /// Upcoming events in the group, ordered ascending by `startsAt`.
    /// Kept for back-compat with consumers that read raw events
    /// (HomeOverviewView, EventsHistory, etc.). The Próximo cluster
    /// reads from `upcomingItems` instead.
    public var upcomingEvents: [Event] = []

    /// 2026-05-25 polymorphic Próximo: merged + sorted upcoming items
    /// across Event / Vote (closing) / Slot (rotation). New sources
    /// land here by extending `UpcomingItem` + adding a loader in
    /// `loadUpcomingItems` — no caller changes.
    public var upcomingItems: [UpcomingItem] = []

    /// Open votes for this group whose `closesAt` is in the future.
    /// Populated alongside `upcomingItems` so the votes are also
    /// addressable as `[Vote]` if a future surface needs them.
    public var openVotes: [Vote] = []

    /// Upcoming slot rotations (`startsAt > now`). Same back-compat
    /// rationale as `openVotes`.
    public var upcomingSlots: [Slot] = []

    /// Recent ledger entries for the group, newest first. Drives the
    /// "Dinero reciente" cluster on GroupSpaceView. Polymorphic via
    /// `resourceId` + `metadata` — the cluster renders any type.
    public var recentMoneyEntries: [LedgerEntry] = []

    /// Resources currently in use in the group — assets with a
    /// custodian, spaces with a checked-in member. Drives the "En uso"
    /// cluster on GroupSpaceView. Slot in-use is intentionally not
    /// surfaced (semantics ambiguous per founder rule 2026-05-24).
    public var inUseItems: [InUseProjection] = []

    /// Group-wide system events for the "Acabó de pasar" cluster
    /// (V4 fix 2026-05-25). Replaces the per-user `recentActivity`
    /// source — the cluster now reads from `system_events` so rows
    /// say "José pagó la cena" instead of "Tú pagaste la cena".
    /// Top 5 newest. Empty until first successful refresh.
    public var groupActivityEvents: [SystemEvent] = []
    /// The viewer's own balance for the group's currency, derived from
    /// `groupBalances` once `group` + `actorUserId` resolve. nil when
    /// the user has no entries yet (settled). UI hides the card in
    /// that case.
    public var viewerBalance: MemberGroupBalance? {
        guard let group, let userId = actorUserId else { return nil }
        // Map user_id → group_members.id via the loaded members list.
        guard let myMemberId = allMembers
            .first(where: { $0.member.userId == userId })?.member.id else { return nil }
        return groupBalances.first(where: {
            $0.memberId == myMemberId && $0.currency == group.currency
        })
    }

    /// FASE 4 Wave 4 Phase 3 Tier 1 (mig 20260525230000): viewer's
    /// obligations row — uses `netPeerPositionCents` (excludes stake)
    /// so labels stop mintiendo cuando hay aportes. Surfaces should
    /// prefer THIS over `viewerBalance` for "Te deben / Le debes"
    /// strings.
    public var viewerObligation: MemberObligationSummary? {
        guard let group, let userId = actorUserId else { return nil }
        guard let myMemberId = allMembers
            .first(where: { $0.member.userId == userId })?.member.id else { return nil }
        return groupObligations.first(where: {
            $0.memberId == myMemberId && $0.currency == group.currency
        })
    }
    public var isLoading: Bool = false
    public var error: CoordinatorError?
    /// True después de que `refresh()` completó al menos una vez. Permite
    /// distinguir "primera carga" de "loaded" cuando `group != nil` por
    /// otra razón. Consumido por `phase` para construir el `LoadPhase`.
    public private(set) var hasLoaded: Bool = false

    /// Adapter para `AsyncContentView`. Deriva el `LoadPhase` desde los
    /// campos `@Observable` que ya mantenemos. Escalar (single Group),
    /// así que usamos `LoadPhase.from` con `isEmpty = { _ in false }`
    /// (un grupo cargado nunca es "empty" — la pantalla siempre tiene
    /// algo que mostrar una vez que `group != nil`).
    public var phase: LoadPhase<Group> {
        LoadPhase.from(
            value: group,
            isLoading: isLoading,
            error: error
        )
    }

    /// Aggregated group stats — nil until the first successful refresh.
    public var summary: GroupSummary?

    /// True when the calling user holds the `admin` role (post-mig-00262
    /// capability bundle). Founders are also admin via mig 00290 backfill.
    /// Prefer `hasPermission(.modifyGovernance)` over this for new gating;
    /// kept because several callers display admin-specific UI affordances.
    public var isCurrentUserAdmin: Bool {
        myRawRoles.contains("admin") || myRole == "admin" || myRole == "founder"
    }

    /// True when the calling user has p_permission in this group,
    /// resolved against `group.effectiveRoles` and `myRawRoles`. Mirrors
    /// the server's `has_permission` RPC (mig 00228) — UI gating only;
    /// the server is still the authoritative gate.
    public func hasPermission(_ p: Permission) -> Bool {
        guard let group else { return false }
        let catalog = group.effectiveRoles
        // Post-mig-00290: admin lives in roles[] directly. No alias needed.
        for raw in myRawRoles {
            if let def = catalog[raw], def.grants(p) { return true }
        }
        // Legacy fallback for sessions where myRawRoles wasn't populated
        // (e.g. older GroupDetail without myRawRoles). Honors text-only
        // 'admin'/'founder' rows that predate the backfill.
        if myRawRoles.isEmpty {
            for legacy in ["admin", "founder"] where myRole == legacy {
                if let def = catalog[legacy], def.grants(p) { return true }
            }
        }
        return false
    }

    public init(
        groupId: UUID,
        groupsRepo: any GroupsRepository,
        moduleRegistry: ModuleRegistry = .v1Fallback,
        groupSummaryRepo: (any GroupSummaryRepository)? = nil,
        userActionRepo: (any UserActionRepository)? = nil,
        myActivityRepo: (any MyActivityRepository)? = nil,
        systemEventRepo: (any SystemEventRepository)? = nil,
        eventRepo: (any EventRepository)? = nil,
        fineRepo: (any FineRepository)? = nil,
        fundRepo: (any FundRepository)? = nil,
        resourceRepo: (any ResourceRepository)? = nil,
        ledgerRepo: (any LedgerRepository)? = nil,
        voteRepo: (any VoteRepository)? = nil,
        slotRepo: (any SlotRepository)? = nil,
        actorUserId: UUID? = nil,
        changeFeed: (any MultiDeviceChangeFeed)? = nil
    ) {
        self.groupId = groupId
        self.groupsRepo = groupsRepo
        self.moduleRegistry = moduleRegistry
        self.groupSummaryRepo = groupSummaryRepo
        self.userActionRepo = userActionRepo
        self.myActivityRepo = myActivityRepo
        self.systemEventRepo = systemEventRepo
        self.eventRepo = eventRepo
        self.fineRepo = fineRepo
        self.fundRepo = fundRepo
        self.resourceRepo = resourceRepo
        self.ledgerRepo = ledgerRepo
        self.voteRepo = voteRepo
        self.slotRepo = slotRepo
        self.actorUserId = actorUserId
        if let feed = changeFeed {
            self.changeFeedTask = Task { [weak self] in
                for await change in feed.changes {
                    if Task.isCancelled { return }
                    guard let self else { return }
                    if change.table == .userAction {
                        await self.loadPendingActions()
                    }
                }
            }
        }
    }

    deinit { changeFeedTask?.cancel() }

    public func refresh() async {
        isLoading = true
        error = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            async let detailTask = groupsRepo.get(groupId)
            async let membersTask = loadMembers()
            async let summaryTask: Void = loadSummary()
            async let pendingsTask: Void = loadPendingActions()
            async let activityTask: Void = loadRecentActivity()
            async let eventsCountTask: Void = loadUpcomingEventsCount()
            async let finesCountTask: Void = loadFinesCount()
            async let fundsTask: Void = loadFunds()
            async let sharedPoolTask: Void = loadSharedPoolSummary()
            async let assetsTask: Void = loadAssets()
            async let balancesTask: Void = loadBalances()
            async let recentMoneyTask: Void = loadRecentMoney()
            async let inUseTask: Void = loadInUse()
            async let groupActivityTask: Void = loadGroupActivity()
            async let openVotesTask: Void = loadOpenVotes()
            async let upcomingSlotsTask: Void = loadUpcomingSlots()
            let detail = try await detailTask
            self.members = await membersTask
            _ = await summaryTask
            _ = await pendingsTask
            _ = await activityTask
            _ = await eventsCountTask
            _ = await finesCountTask
            _ = await fundsTask
            _ = await sharedPoolTask
            _ = await assetsTask
            _ = await balancesTask
            _ = await recentMoneyTask
            _ = await inUseTask
            _ = await groupActivityTask
            _ = await openVotesTask
            _ = await upcomingSlotsTask
            self.group = detail.group
            self.memberCount = detail.memberCount
            self.myRole = detail.myRole
            self.myRawRoles = detail.myRawRoles
            self.activeModules = resolveModules(slugs: detail.group.activeModules ?? [])
            // Merge polymorphic Próximo sources after all dependents
            // resolve (allMembers needs to be set for holder resolution).
            rebuildUpcomingItems()
        } catch {
            log.warning("group home refresh failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar el grupo")
        }
    }

    public func clearError() { error = nil }

    // MARK: - Parallel loads

    public func loadSummary() async {
        guard let repo = groupSummaryRepo, let userId = actorUserId else { return }
        do {
            self.summary = try await repo.summary(groupId: groupId, userId: userId)
        } catch {
            log.warning("group summary load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Top 8 members for the PresenceHeader stack. Soft-fails — an
    /// empty stack still renders a valid header.
    private func loadMembers() async -> [MemberWithProfile] {
        do {
            let all = try await groupsRepo.membersWithProfiles(of: groupId)
            self.allMembers = all
            return Array(all.prefix(8))
        } catch {
            log.warning("group members load failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func loadPendingActions() async {
        guard let repo = userActionRepo, let userId = actorUserId else { return }
        do {
            self.pendingActions = try await repo.pending(userId: userId, groupId: groupId)
        } catch {
            log.warning("group pending actions load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadUpcomingEventsCount() async {
        guard let repo = eventRepo else { return }
        do {
            let events = try await repo.upcomingEvents(in: groupId, limit: 100)
            self.upcomingEvents = events
            self.upcomingEventsCount = events.count
        } catch {
            log.warning("group upcomingEvents load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Loads the most recent ledger entries for this group. Drives the
    /// "Dinero reciente" cluster. Soft-fails — empty list is a valid
    /// rendering state (the cluster auto-hides per situational-stream
    /// doctrine when there's nothing to show).
    private func loadRecentMoney() async {
        guard let repo = ledgerRepo else { return }
        do {
            let entries = try await repo.list(groupId: groupId, limit: 20)
            self.recentMoneyEntries = entries
        } catch {
            log.warning("group recent money load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Loads "in use right now" projections via the polymorphic
    /// `inUseInGroup` repo method. Drives the "En uso" cluster.
    /// Soft-fails — empty list is the doctrine-correct rendering
    /// state (cluster auto-hides when nothing is in use).
    private func loadInUse() async {
        guard let repo = resourceRepo else { return }
        do {
            self.inUseItems = try await repo.inUseInGroup(groupId)
        } catch {
            log.warning("group in-use load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Loads the most recent group-wide system events for the "Acabó
    /// de pasar" cluster. V4 fix 2026-05-25: replaces the per-user
    /// `MyActivityRepository.loadRecent` source so the feed reads
    /// "José confirmó asistencia" instead of "Tú confirmaste". Top 5
    /// newest; soft-fails (empty list auto-hides the cluster per
    /// doctrine).
    private func loadGroupActivity() async {
        guard let repo = systemEventRepo else { return }
        do {
            let events = try await repo.query(
                filter: SystemEventFilter(groupId: groupId),
                limit: 5,
                offset: 0
            )
            self.groupActivityEvents = events
        } catch {
            log.warning("group activity load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadFinesCount() async {
        guard let repo = fineRepo, let userId = actorUserId else { return }
        do {
            let all = try await repo.myFines(userId: userId)
            self.groupFinesCount = all.filter { $0.groupId == groupId }.count
        } catch {
            log.warning("group fines count failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadFunds() async {
        guard let repo = fundRepo else { return }
        do {
            self.groupFunds = try await repo.listForGroup(groupId)
        } catch {
            log.warning("group funds load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// P3 (mig 00136): per-member net balances in the group. Soft-fails —
    /// the card simply stays hidden if the read errors. Read is small
    /// (one row per (member, currency)) so no pagination needed.
    /// FASE 4 Wave 4 Phase 3: also loads `member_obligations_view` for
    /// the 3-dim breakdown used by the peer-settlement greedy.
    private func loadBalances() async {
        guard let repo = ledgerRepo else { return }
        do {
            self.groupBalances = try await repo.balancesForGroup(groupId)
        } catch {
            log.warning("group balances load failed: \(error.localizedDescription, privacy: .public)")
        }
        self.groupObligations =
            (try? await repo.obligationsForGroup(groupId)) ?? []
    }

    /// Loads active assets in the group (resource_type='asset'). Soft-
    /// fails — the tile simply doesn't appear if the repo isn't wired
    /// or the call errors. Limit 100 mirrors `loadUpcomingEventsCount`'s
    /// posture; groups with >100 assets won't surface a precise count
    /// but the tile still shows "100+".
    private func loadAssets() async {
        guard let repo = resourceRepo else { return }
        do {
            self.groupAssets = try await repo.list(
                in: groupId,
                types: [.asset],
                statuses: nil,
                limit: 100
            )
        } catch {
            log.warning("group assets load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Loads the canonical shared pool projection. Soft-fails — the
    /// card simply stays hidden if the pool can't be read. Currency is
    /// unknown at parallel-kickoff (group detail hasn't resolved yet);
    /// for V1 single-currency the view emits exactly one row so
    /// `preferredCurrency: nil` resolves to the group's currency.
    private func loadSharedPoolSummary() async {
        guard let repo = fundRepo else { return }
        do {
            self.sharedPoolSummary = try await repo.summaryForGroup(groupId, preferredCurrency: nil)
        } catch {
            log.warning("shared pool summary load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Filters cross-group `my_activity_v1` by current group. Optional —
    /// the repo is wired only in live builds, so previews/mocks pass nil.
    private func loadRecentActivity() async {
        guard let repo = myActivityRepo else { return }
        do {
            let cross = try await repo.loadRecent(limit: 40)
            self.recentActivity = Array(cross.filter { $0.groupId == groupId }.prefix(5))
        } catch {
            log.warning("group activity load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resolveModules(slugs: [String]) -> [GroupModule] {
        slugs.compactMap { slug in moduleRegistry.modules.first(where: { $0.id == slug }) }
    }

    // MARK: - Polymorphic Próximo sources (2026-05-25)

    /// Loads open votes for the group. The Próximo cluster will filter
    /// these by `closesAt` imminence at merge time.
    private func loadOpenVotes() async {
        guard let repo = voteRepo else { return }
        do {
            self.openVotes = try await repo.openVotes(for: groupId)
        } catch {
            log.warning("group open votes load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Loads all non-archived slots for the group. `rebuildUpcomingItems`
    /// filters to `startsAt > now` for the Próximo merge.
    private func loadUpcomingSlots() async {
        guard let repo = slotRepo else { return }
        do {
            let all = try await repo.listForGroup(groupId)
            let now = Date()
            self.upcomingSlots = all.filter { $0.startsAt > now }
        } catch {
            log.warning("group upcoming slots load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Merges all polymorphic upcoming sources into `upcomingItems`,
    /// sorted ascending by `occursAt`. Called after parallel loaders
    /// complete (so member names can be resolved for slot holders).
    /// Cap at 8 rows — the cluster itself further caps at 5 visible,
    /// the extras give us headroom for filter changes.
    private func rebuildUpcomingItems() {
        let now = Date()
        var items: [UpcomingItem] = []

        // Events: take what's already loaded by `loadUpcomingEventsCount`.
        items.append(contentsOf: upcomingEvents.map(UpcomingItem.event))

        // Votes: filter open + closesAt in the future. Status filter
        // is defensive — `openVotes` repo method should already return
        // status=.open, but pre-finalize jobs can leave stale rows.
        items.append(contentsOf:
            openVotes
                .filter { $0.status == .open && $0.closesAt > now }
                .map(UpcomingItem.voteClosing)
        )

        // Slots: resolve the holder name from `allMembers` (loaded in
        // parallel with the slots themselves). asset_name resolution
        // is deferred — the row falls back to a generic "Turno" title
        // when assetName is nil (no extra fetch on the hot path).
        items.append(contentsOf:
            upcomingSlots.map { slot in
                let holderName: String? = slot.assignedMemberId.flatMap { memberId in
                    allMembers.first(where: { $0.member.id == memberId })?.displayName
                }
                return UpcomingItem.slotRotation(
                    slot: slot,
                    holderName: holderName,
                    assetName: nil
                )
            }
        )

        items.sort { $0.occursAt < $1.occursAt }
        self.upcomingItems = Array(items.prefix(8))
    }
}
