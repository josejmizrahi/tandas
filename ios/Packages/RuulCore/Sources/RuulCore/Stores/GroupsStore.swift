import Foundation
import Observation

/// `@MainActor` store for "groups the caller belongs to" — drives the
/// home list. Refresh is explicit; Foundation does not subscribe to
/// realtime, so callers refetch after RPCs that mutate membership
/// (`createGroup`, `acceptInvite`, `leaveGroup`).
@MainActor
@Observable
public final class GroupsStore {
    public private(set) var groups: [GroupListItem] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var selectedGroupId: UUID?

    private let repository: CanonicalGroupRepository

    public init(repository: CanonicalGroupRepository) {
        self.repository = repository
    }

    /// Fetches the caller's group list. Sets `phase = .loading` on first
    /// load (when there is no prior data) and keeps showing the previous
    /// list during a re-fetch (UI can show a discreet refresh indicator
    /// instead of replacing the rows with a spinner).
    public func refresh() async {
        if groups.isEmpty { phase = .loading }
        do {
            groups = try await repository.listMyGroups()
            phase = .loaded
            // If the selection no longer exists in the new list, clear it
            // so downstream stores can react.
            if let id = selectedGroupId, !groups.contains(where: { $0.id == id }) {
                selectedGroupId = nil
            }
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Pure UI selection setter — does not touch any downstream store.
    /// `CurrentGroupStore` observes this id (or is told to load it)
    /// elsewhere in the app.
    public func selectGroup(id: UUID?) {
        selectedGroupId = id
    }

    /// Resolves the currently-selected group row, if any. Convenience
    /// for views that need the joined membership id without re-deriving
    /// from `groups`.
    public var selectedGroup: GroupListItem? {
        guard let id = selectedGroupId else { return nil }
        return groups.first(where: { $0.id == id })
    }
}
