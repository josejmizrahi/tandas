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

    public init(
        group: RuulCore.Group,
        actorUserId: UUID,
        groupsRepo: any GroupsRepository
    ) {
        self.group = group
        self.actorUserId = actorUserId
        self.groupsRepo = groupsRepo
    }

    public func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            self.members = try await groupsRepo.membersWithProfiles(of: group.id)
        } catch {
            log.warning("members refresh failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar los miembros")
        }
    }

    public func clearError() { error = nil }

    /// True when the calling user is a founder in this group (= admin).
    public var isCurrentUserAdmin: Bool {
        members.first(where: { $0.member.userId == actorUserId })?.member.isFounder ?? false
    }

    public func member(for userId: UUID) -> MemberWithProfile? {
        members.first(where: { $0.member.userId == userId })
    }

    public var activeMembers: [MemberWithProfile] {
        members.filter { $0.member.active }
    }

    /// True when the calling user may grant or revoke roles. Resolved
    /// locally via the role catalog on `group` — server is still the
    /// authoritative gate via `has_permission(assignRoles)`.
    public var canManageRoles: Bool {
        guard let me = members.first(where: { $0.member.userId == actorUserId })?.member else {
            return false
        }
        if me.isFounder { return true }
        let catalog = group.effectiveRoles
        for roleId in me.rawRoles {
            if let def = catalog[roleId], def.grants(.assignRoles) { return true }
        }
        return false
    }

    /// Count of distinct active founders. Used by `MemberRolesPicker`
    /// to disable the founder toggle on the last holder so the UI
    /// doesn't offer an action the server would reject anyway.
    public var founderCount: Int {
        activeMembers.filter { $0.member.isFounder }.count
    }

    /// True when the calling user may remove other members from the
    /// group. Hides the kick swipe-action; server-side `remove_member`
    /// RPC is still the authoritative gate.
    public var canRemoveMembers: Bool {
        permission(.removeMember)
    }

    private func permission(_ p: Permission) -> Bool {
        guard let me = members.first(where: { $0.member.userId == actorUserId })?.member else {
            return false
        }
        if me.isFounder { return true }
        let catalog = group.effectiveRoles
        for roleId in me.rawRoles {
            if let def = catalog[roleId], def.grants(p) { return true }
        }
        return false
    }
}
