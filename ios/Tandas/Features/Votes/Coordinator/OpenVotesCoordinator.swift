import Foundation
import Observation
import OSLog
import RuulUI
import RuulCore

/// Coordinator del OpenVotesListView. Lista cross-vote_type de votes
/// con status='open' del grupo activo. Sectiona por urgencia
/// (closing-soon < 24h vs other) para que el founder/miembros vean
/// primero lo que está por cerrar.
@Observable @MainActor
final class OpenVotesCoordinator {
    let group: Group
    private let voteRepo: any VoteRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "votes")

    private(set) var openVotes: [Vote] = []
    private(set) var isLoading: Bool = false
    private(set) var error: CoordinatorError?
    private(set) var lastRefreshedAt: Date?

    private let cacheTTL: TimeInterval = 60

    init(group: Group, voteRepo: any VoteRepository) {
        self.group = group
        self.voteRepo = voteRepo
    }

    func refresh(force: Bool = false) async {
        if !force, let last = lastRefreshedAt,
           Date.now.timeIntervalSince(last) < cacheTTL {
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            openVotes = try await voteRepo.openVotes(for: group.id)
            lastRefreshedAt = .now
        } catch {
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar los votos abiertos")
            log.warning("openVotes refresh failed: \(error.localizedDescription)")
        }
    }

    func clearError() { error = nil }

    /// Sectioned: closing-soon (next 24h) vs other (≥24h until close).
    func sectioned() -> [(Section, [Vote])] {
        let cutoff = Date.now.addingTimeInterval(24 * 3600)
        var closingSoon: [Vote] = []
        var open: [Vote] = []
        for v in openVotes {
            if v.closesAt <= cutoff { closingSoon.append(v) } else { open.append(v) }
        }
        var result: [(Section, [Vote])] = []
        if !closingSoon.isEmpty { result.append((.closingSoon, closingSoon)) }
        if !open.isEmpty        { result.append((.open, open)) }
        return result
    }

    enum Section: Hashable {
        case closingSoon
        case open

        var title: String {
            switch self {
            case .closingSoon: return "Cierran pronto"
            case .open:        return "Abiertos"
            }
        }
    }
}
