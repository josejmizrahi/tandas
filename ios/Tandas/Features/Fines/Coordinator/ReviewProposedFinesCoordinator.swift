import Foundation
import OSLog

@Observable @MainActor
final class ReviewProposedFinesCoordinator {
    let event: Event
    private(set) var fines: [Fine] = []
    private(set) var isLoading: Bool = false
    private(set) var isMutating: Bool = false
    private(set) var error: String?

    private let fineRepo: any FineRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "fines.review")

    init(event: Event, fineRepo: any FineRepository) {
        self.event = event
        self.fineRepo = fineRepo
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            fines = try await fineRepo.fines(forEventId: event.id)
        } catch {
            log.warning("review fines load failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    func officializeAll() async {
        for fine in fines where fine.status == .proposed {
            await officialize(fineId: fine.id)
        }
    }

    func officialize(fineId: UUID) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let updated = try await fineRepo.officialize(fineId: fineId)
            replaceLocal(updated)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func void(fineId: UUID, reason: String?) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let updated = try await fineRepo.void(fineId: fineId, reason: reason)
            replaceLocal(updated)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func replaceLocal(_ fine: Fine) {
        if let idx = fines.firstIndex(where: { $0.id == fine.id }) {
            fines[idx] = fine
        }
    }

    var proposed: [Fine] { fines.filter { $0.status == .proposed } }
    var resolved: [Fine] { fines.filter { $0.status != .proposed } }
}
