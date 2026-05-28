import Foundation
import Observation

/// `@MainActor` store for Primitiva 19 (Accounting) movements list.
/// Pages newest-first by `seq` cursor. Filter is a Set of canonical
/// `transaction_type` strings (empty = "Todos"). Switching the filter
/// re-fetches from the top so the cursor stays consistent.
@MainActor
@Observable
public final class MoneyMovementsStore {
    public private(set) var movements: [MoneyMovement] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?
    public private(set) var isLoadingMore: Bool = false
    public private(set) var reachedEnd: Bool = false

    /// Active type filter. Empty set = "all". Setting it via
    /// `setFilter(_:groupId:)` triggers a refresh so the wire-level
    /// `p_filter` stays in sync with the chip row.
    public private(set) var activeFilter: Set<MoneyMovementType> = []

    private let repository: CanonicalMovementsRepository
    private var loadedKey: CacheKey?
    private let pageSize: Int = 50

    public init(repository: CanonicalMovementsRepository) {
        self.repository = repository
    }

    private struct CacheKey: Equatable {
        let groupId: UUID
        let filter: [String]
    }

    // MARK: - Derived

    public var isEmpty: Bool { movements.isEmpty }

    // MARK: - Intents

    public func refresh(groupId: UUID) async {
        let filter = sortedFilterWire
        let key = CacheKey(groupId: groupId, filter: filter)
        if movements.isEmpty || loadedKey != key {
            phase = .loading
        }
        do {
            let fetched = try await repository.movements(
                groupId: groupId,
                limit: pageSize,
                filter: filter.isEmpty ? nil : filter,
                beforeSeq: nil
            )
            movements = fetched
            phase = .loaded
            loadedKey = key
            errorMessage = nil
            reachedEnd = fetched.count < pageSize
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            phase = .failed(message: message)
        }
    }

    public func refreshIfNeeded(groupId: UUID) async {
        let key = CacheKey(groupId: groupId, filter: sortedFilterWire)
        if loadedKey == key, !movements.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    /// Append the next older page. No-op when already paginating, the
    /// list is empty, or we've reached the tail.
    public func loadMore(groupId: UUID) async {
        guard !isLoadingMore, !reachedEnd, let cursor = movements.last?.seq else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let filter = sortedFilterWire
        do {
            let next = try await repository.movements(
                groupId: groupId,
                limit: pageSize,
                filter: filter.isEmpty ? nil : filter,
                beforeSeq: cursor
            )
            movements.append(contentsOf: next)
            reachedEnd = next.count < pageSize
        } catch {
            errorMessage = UserFacingError.from(error).message
        }
    }

    /// Replaces the filter set and refreshes from the top.
    public func setFilter(_ filter: Set<MoneyMovementType>, groupId: UUID) async {
        activeFilter = filter
        await refresh(groupId: groupId)
    }

    public func clear() {
        movements = []
        phase = .idle
        loadedKey = nil
        errorMessage = nil
        reachedEnd = false
    }

    public func clearError() { errorMessage = nil }

    // MARK: - Helpers

    /// Wire-stable order so cache-key equality stays deterministic
    /// regardless of insertion order in `activeFilter`.
    private var sortedFilterWire: [String] {
        activeFilter.map(\.rawValue).sorted()
    }
}
