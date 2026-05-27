import Foundation
import Observation

/// `@MainActor` store for Primitiva 12 (Trust/Reputation). Holds the
/// reputation events for a *single subject* at a time — typical use
/// is "open a member's history". The store keys cache by
/// `(groupId, subjectMembershipId)` so re-opening the same member
/// doesn't refetch.
@MainActor
@Observable
public final class ReputationStore {
    public private(set) var events: [GroupReputationEvent] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    private let repository: CanonicalReputationRepository
    private var loadedKey: CacheKey?

    public init(repository: CanonicalReputationRepository) {
        self.repository = repository
    }

    private struct CacheKey: Equatable {
        let groupId: UUID
        let subjectMembershipId: UUID
    }

    // MARK: - Derived

    public var isEmpty: Bool { events.isEmpty }

    // MARK: - Intents

    /// Refresh from the backend. Always hits the repository — callers
    /// that want idempotency for the same key should use
    /// `refreshIfNeeded(...)`.
    public func refresh(groupId: UUID, subjectMembershipId: UUID, limit: Int = 50) async {
        let key = CacheKey(groupId: groupId, subjectMembershipId: subjectMembershipId)
        if events.isEmpty || loadedKey != key {
            phase = .loading
        }
        do {
            let fetched = try await repository.eventsForMember(
                groupId: groupId,
                subjectMembershipId: subjectMembershipId,
                limit: limit
            )
            events = fetched
            phase = .loaded
            loadedKey = key
            errorMessage = nil
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            phase = .failed(message: message)
        }
    }

    /// No-op when the same `(group, subject)` pair is already loaded.
    public func refreshIfNeeded(groupId: UUID, subjectMembershipId: UUID, limit: Int = 50) async {
        let key = CacheKey(groupId: groupId, subjectMembershipId: subjectMembershipId)
        if loadedKey == key, !events.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId, subjectMembershipId: subjectMembershipId, limit: limit)
    }

    /// Drop everything — used when the surface closes so the next open
    /// for a different member starts fresh.
    public func clear() {
        events = []
        phase = .idle
        loadedKey = nil
        errorMessage = nil
    }

    public func clearError() { errorMessage = nil }
}
