import Foundation
import Observation
import OSLog
import RuulCore

@Observable
@MainActor
public final class MembersCoordinator {
    public let group: RuulCore.Group
    public let actorUserId: UUID
    private let groupsRepo: any GroupsRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "members")

    public var members: [MemberWithProfile] = []
    public var isLoading: Bool = false
    public var error: CoordinatorError?
    /// True después de que `refresh()` completó al menos una vez. Permite
    /// distinguir "primera carga" de "loaded empty" cuando `members == []`.
    /// Consumido por `LoadPhase.fromCollection` en la computed `phase`.
    public private(set) var hasLoaded: Bool = false

    public init(
        group: RuulCore.Group,
        actorUserId: UUID,
        groupsRepo: any GroupsRepository
    ) {
        self.group = group
        self.actorUserId = actorUserId
        self.groupsRepo = groupsRepo
    }

    /// Adapter para `AsyncContentView`. Deriva el `LoadPhase` desde los
    /// campos `@Observable` que ya mantenemos.
    public var phase: LoadPhase<[MemberWithProfile]> {
        LoadPhase.fromCollection(
            value: members,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            error: error
        )
    }

    /// Phase derivado sobre `activeMembers` — las vistas que solo muestran
    /// miembros activos (Members list/admin) usan esto para que el caso
    /// `.empty` se evalúe contra el subset visible y no contra la lista
    /// total (que incluye placeholders/inactivos invisibles).
    public var activePhase: LoadPhase<[MemberWithProfile]> {
        LoadPhase.fromCollection(
            value: activeMembers,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            error: error
        )
    }

    public func refresh() async {
        isLoading = true
        error = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            self.members = try await groupsRepo.membersWithProfiles(of: group.id)
        } catch {
            log.warning("members refresh failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar los miembros")
        }
    }

    public func clearError() { error = nil }

    /// True when the calling user has admin role. Mig 00262 separó
    /// admin de founder — pre-mig todos los founders eran auto-admin;
    /// post-mig el backfill garantiza que los founders existentes
    /// también tengan admin role, así que `isAdmin` (que cubre ambos)
    /// es la verificación correcta.
    public var isCurrentUserAdmin: Bool {
        members.first(where: { $0.member.userId == actorUserId })?.member.isAdmin ?? false
    }

    public func member(for userId: UUID) -> MemberWithProfile? {
        members.first(where: { $0.member.userId == userId })
    }

    public var activeMembers: [MemberWithProfile] {
        members.filter { $0.member.active }
    }

    /// True when the calling user may grant or revoke roles. Resolved
    /// locally via the role catalog on `group` — server is still the
    /// authoritative gate via `has_permission(assignRoles)`. Sprint E
    /// (V20 fix): dropped the `me.isAdmin → return true` short-circuit
    /// — after mig 00290 every admin has the role in roles[] explicitly,
    /// so the catalog walk is sufficient. Custom roles get the same
    /// chance to declare assignRoles.
    public var canManageRoles: Bool {
        permission(.assignRoles)
    }

    /// Count of distinct active admins. Used by `MemberRolesPicker`
    /// to disable the admin toggle on the last holder so el UI no
    /// ofrezca una acción que el server rechazaría. Post-mig 00262
    /// es admin (no founder) lo que importa para el "último que puede
    /// modificar el grupo" check — el founder badge es identidad
    /// histórica, no protege capacidades operativas.
    public var adminCount: Int {
        activeMembers.filter { $0.member.isAdmin }.count
    }

    /// Count de active founders. Post-mig 00262 esto es identidad
    /// (no permisos) — para gating de "último admin" usa `adminCount`.
    /// Sigue siendo útil para MemberRolesPicker que muestra el founder
    /// toggle como disabled/badge cuando solo hay uno.
    public var founderCount: Int {
        activeMembers.filter { $0.member.isFounder }.count
    }

    /// True when the calling user may remove other members from the
    /// group. Hides the kick swipe-action; server-side `remove_member`
    /// RPC is still the authoritative gate.
    public var canRemoveMembers: Bool {
        permission(.removeMember)
    }

    /// Sprint E (V20 fix): dropped the `me.isAdmin → return true`
    /// short-circuit. Every role's permissions are now resolved via the
    /// catalog walk, so a custom role can grant or deny any permission
    /// without the admin-role shortcut hiding the answer. Founders + admins
    /// still get the right answer because mig 00290 backfilled 'admin' into
    /// their roles[] and the admin role in the catalog already grants
    /// modifyGovernance/Rules/Members/assignRoles/removeMember/etc.
    private func permission(_ p: Permission) -> Bool {
        guard let me = members.first(where: { $0.member.userId == actorUserId })?.member else {
            return false
        }
        let catalog = group.effectiveRoles
        for roleId in me.rawRoles {
            if let def = catalog[roleId], def.grants(p) { return true }
        }
        return false
    }
}
