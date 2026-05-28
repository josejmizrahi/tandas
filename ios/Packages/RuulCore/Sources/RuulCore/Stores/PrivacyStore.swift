import Foundation
import Observation

/// `@MainActor` store for B7 (Privacy). Holds the current group
/// visibility and applies updates through `set_group_visibility(...)`.
/// Backend gates on `group.update`, so non-admins see a permission
/// error on save and the local state reverts.
@MainActor
@Observable
public final class PrivacyStore {
    public private(set) var visibility: GroupVisibility?
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    private let repository: CanonicalPrivacyRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalPrivacyRepository) {
        self.repository = repository
    }

    // MARK: - Intents

    public func refresh(groupId: UUID) async {
        if visibility == nil || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            visibility = try await repository.visibility(groupId: groupId)
            phase = .loaded
            loadedGroupId = groupId
            errorMessage = nil
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            phase = .failed(message: message)
        }
    }

    public func refreshIfNeeded(groupId: UUID) async {
        if loadedGroupId == groupId, visibility != nil {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    @discardableResult
    public func setVisibility(_ next: GroupVisibility, groupId: UUID) async -> Bool {
        let previous = visibility
        visibility = next
        do {
            let updated = try await repository.setVisibility(groupId: groupId, visibility: next)
            visibility = updated
            errorMessage = nil
            return true
        } catch {
            visibility = previous
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearError() { errorMessage = nil }
}
