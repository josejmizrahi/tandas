import Foundation
import Observation

/// D.22 — Search MVP store. Holds the live query string, the latest
/// results, and a debounced fetch pipeline. Query mutations cancel the
/// in-flight task and reschedule after `debounceMillis`. Min length 2
/// is enforced client-side too (mirroring the backend) so we don't
/// fire a round-trip for single characters.
@MainActor
@Observable
public final class SearchStore {
    public var query: String = "" {
        didSet {
            guard oldValue != query else { return }
            scheduleSearch()
        }
    }
    public private(set) var results: [SearchResult] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    /// Active group, set by the call site before presenting the sheet.
    /// While nil the store is dormant (no fetches).
    public var groupId: UUID? {
        didSet {
            if oldValue != groupId {
                results = []
                phase = .idle
                errorMessage = nil
            }
        }
    }

    /// Tuneable. 300ms is the canonical default and matches typing cadence
    /// without saturating the backend on every keystroke.
    public var debounceMillis: Int = 300

    private let repository: CanonicalSearchRepository
    private var task: Task<Void, Never>?

    public init(repository: CanonicalSearchRepository) {
        self.repository = repository
    }

    // MARK: - Derived

    public var groupedResults: [(section: SearchEntityType, items: [SearchResult])] {
        let grouped = Dictionary(grouping: results, by: \.entityType)
        return SearchEntityType.allCases.compactMap { type in
            guard let items = grouped[type], !items.isEmpty else { return nil }
            return (type, items)
        }
    }

    public var isEmpty: Bool {
        results.isEmpty
    }

    /// True only while a fetch is in-flight (not for idle/loaded/failed).
    public var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    // MARK: - Intents

    /// Reset both query + results. Used when the sheet is dismissed or
    /// the group changes.
    public func clear() {
        task?.cancel()
        task = nil
        query = ""
        results = []
        phase = .idle
        errorMessage = nil
    }

    private func scheduleSearch() {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.count < 2 {
            // Client-side min-length parity with backend. Avoid a round-trip
            // and surface an immediate empty state.
            results = []
            phase = .idle
            errorMessage = nil
            return
        }
        guard let gid = groupId else {
            results = []
            phase = .idle
            return
        }
        let delay = debounceMillis
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            if Task.isCancelled { return }
            await self?.runSearch(groupId: gid, query: q)
        }
    }

    private func runSearch(groupId: UUID, query: String) async {
        phase = .loading
        do {
            let fetched = try await repository.search(groupId: groupId, query: query)
            if Task.isCancelled { return }
            results = fetched
            phase = .loaded
            errorMessage = nil
        } catch {
            if Task.isCancelled { return }
            let message = UserFacingError.from(error).message
            results = []
            phase = .failed(message: message)
            errorMessage = message
        }
    }
}
