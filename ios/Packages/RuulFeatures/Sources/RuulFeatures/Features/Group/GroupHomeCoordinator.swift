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
    private let eventRepo: (any EventRepository)?
    private let fineRepo: (any FineRepository)?
    private let fundRepo: (any FundRepository)?
    private let actorUserId: UUID?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "group.home")

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
    public var groupFundsCount: Int = 0
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
        eventRepo: (any EventRepository)? = nil,
        fineRepo: (any FineRepository)? = nil,
        fundRepo: (any FundRepository)? = nil,
        actorUserId: UUID? = nil
    ) {
        self.groupId = groupId
        self.groupsRepo = groupsRepo
        self.moduleRegistry = moduleRegistry
        self.groupSummaryRepo = groupSummaryRepo
        self.userActionRepo = userActionRepo
        self.myActivityRepo = myActivityRepo
        self.eventRepo = eventRepo
        self.fineRepo = fineRepo
        self.fundRepo = fundRepo
        self.actorUserId = actorUserId
    }

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
            async let fundsCountTask: Void = loadFundsCount()
            let detail = try await detailTask
            self.members = await membersTask
            _ = await summaryTask
            _ = await pendingsTask
            _ = await activityTask
            _ = await eventsCountTask
            _ = await finesCountTask
            _ = await fundsCountTask
            self.group = detail.group
            self.memberCount = detail.memberCount
            self.myRole = detail.myRole
            self.myRawRoles = detail.myRawRoles
            self.activeModules = resolveModules(slugs: detail.group.activeModules ?? [])
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
            self.upcomingEventsCount = events.count
        } catch {
            log.warning("group upcomingEvents count failed: \(error.localizedDescription, privacy: .public)")
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

    private func loadFundsCount() async {
        guard let repo = fundRepo else { return }
        do {
            let funds = try await repo.listForGroup(groupId)
            self.groupFundsCount = funds.count
        } catch {
            log.warning("group funds count failed: \(error.localizedDescription, privacy: .public)")
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
}
