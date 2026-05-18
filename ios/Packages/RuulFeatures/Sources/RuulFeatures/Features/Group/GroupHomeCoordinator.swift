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
    private let actorUserId: UUID?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "group.home")

    public var group: Group?
    public var memberCount: Int = 0
    public var myRole: String?          // "founder" | "member" | "admin"
    /// Verbatim roles from `group_members.roles` jsonb for the calling
    /// user. Drives Phase 5 permission-gated affordances in
    /// `GroupHomeView`. Empty until the first successful refresh.
    public var myRawRoles: [String] = []
    public var activeModules: [GroupModule] = []
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
        actorUserId: UUID? = nil
    ) {
        self.groupId = groupId
        self.groupsRepo = groupsRepo
        self.moduleRegistry = moduleRegistry
        self.groupSummaryRepo = groupSummaryRepo
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
            async let summaryTask: Void = loadSummary()
            let detail = try await detailTask
            _ = await summaryTask
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

    // MARK: - Summary

    public func loadSummary() async {
        guard let repo = groupSummaryRepo, let userId = actorUserId else { return }
        do {
            self.summary = try await repo.summary(groupId: groupId, userId: userId)
        } catch {
            log.warning("group summary load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resolveModules(slugs: [String]) -> [GroupModule] {
        slugs.compactMap { slug in moduleRegistry.modules.first(where: { $0.id == slug }) }
    }
}
