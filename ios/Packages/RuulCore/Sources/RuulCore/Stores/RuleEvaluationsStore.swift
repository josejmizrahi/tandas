import Foundation
import Observation

/// V2-G3.5 — store for the engine audit feed. Per-group view: holds
/// the latest page + an optional filter on a single rule. The list is
/// append-only on the server so the store keeps it simple: load, then
/// "load more" via `loadMore(...)` using the oldest createdAt as cursor.
@MainActor
@Observable
public final class RuleEvaluationsStore {
    public private(set) var evaluations: [GroupRuleEvaluation] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?
    public private(set) var hasMore: Bool = true

    /// When set, the surface filters the list locally to evaluations
    /// matching this rule. Server-side filtering is V3 (would need a
    /// separate RPC parameter).
    public var ruleFilter: UUID?

    private let repository: CanonicalRuleEvaluationsRepository
    private let pageSize: Int
    private var loadedGroupId: UUID?

    public init(
        repository: CanonicalRuleEvaluationsRepository,
        pageSize: Int = 50
    ) {
        self.repository = repository
        self.pageSize = pageSize
    }

    public var visibleEvaluations: [GroupRuleEvaluation] {
        guard let filter = ruleFilter else { return evaluations }
        return evaluations.filter { $0.ruleId == filter }
    }

    public func refresh(groupId: UUID) async {
        if loadedGroupId != groupId || evaluations.isEmpty {
            phase = .loading
        }
        do {
            let page = try await repository.evaluations(
                groupId: groupId,
                limit: pageSize,
                before: nil
            )
            evaluations = page
            phase = .loaded
            loadedGroupId = groupId
            errorMessage = nil
            hasMore = page.count == pageSize
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            phase = .failed(message: message)
        }
    }

    public func refreshIfNeeded(groupId: UUID) async {
        if loadedGroupId == groupId, !evaluations.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    public func loadMore(groupId: UUID) async {
        guard hasMore, let oldest = evaluations.last?.createdAt else { return }
        do {
            let next = try await repository.evaluations(
                groupId: groupId,
                limit: pageSize,
                before: oldest
            )
            evaluations.append(contentsOf: next)
            hasMore = next.count == pageSize
        } catch {
            errorMessage = UserFacingError.from(error).message
        }
    }

    public func clearError() { errorMessage = nil }
}
