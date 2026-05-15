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
}
