import Foundation
import Observation

/// `@MainActor` store for the currently-focused group context. Holds the
/// group + caller's membership id + the canonical summary (counts +
/// recent events). Money lives in a sibling `MoneyStore` so each store
/// owns one cohesive slice.
@MainActor
@Observable
public final class CurrentGroupStore {
    public private(set) var group: GroupListItem?
    public private(set) var summary: CanonicalGroupSummary?
    public private(set) var phase: StorePhase = .idle

    private let repository: CanonicalGroupRepository

    public init(repository: CanonicalGroupRepository) {
        self.repository = repository
    }

    /// Switches the focused group and triggers a summary refresh. Pass
    /// `nil` to clear (e.g. after `leaveGroup`).
    public func setGroup(_ group: GroupListItem?) async {
        self.group = group
        summary = nil
        if group == nil {
            phase = .idle
            return
        }
        await refresh()
    }

    /// Re-fetches `group_summary` for the currently-focused group.
    /// No-op when no group is selected.
    public func refresh() async {
        guard let group else {
            phase = .idle
            return
        }
        if summary == nil { phase = .loading }
        do {
            summary = try await repository.groupSummary(groupId: group.id)
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Membership id for the caller in the focused group. `nil` when
    /// no group is selected — features that need this should gate
    /// before calling money RPCs.
    public var myMembershipId: UUID? {
        group?.membershipId
    }
}
