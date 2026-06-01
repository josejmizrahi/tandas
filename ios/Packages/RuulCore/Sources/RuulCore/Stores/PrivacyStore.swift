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
    /// D.22 — constitutional change always opens a vote.
    public private(set) var lastGovernanceOutcome: ActionOutcome?

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
        // Optimistic update so the picker doesn't snap back while the
        // server-side vote opens. We revert on denied/failed.
        visibility = next
        do {
            let outcome = try await repository.setVisibilityViaGovernance(
                groupId: groupId,
                visibility: next
            )
            lastGovernanceOutcome = outcome
            switch outcome {
            case .directAllowed:
                await refresh(groupId: groupId)
                errorMessage = nil
                return true
            case .decisionOpened:
                // Revert local optimistic so the picker reflects current
                // (unchanged) state until the decision passes.
                visibility = previous
                return true
            case .denied(let reason, let missingPermission):
                visibility = previous
                errorMessage = missingPermission.map { "Falta permiso: \($0)" } ?? reason
                return false
            case .unsupported(let reason, _):
                visibility = previous
                errorMessage = "Acción no soportada (\(reason))"
                return false
            case .failed(let reason, let message):
                visibility = previous
                errorMessage = message ?? reason
                return false
            }
        } catch {
            visibility = previous
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearError() { errorMessage = nil }
    public func clearGovernanceOutcome() { lastGovernanceOutcome = nil }
}
