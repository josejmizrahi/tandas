import Foundation
import OSLog

@Observable @MainActor
final class FineDetailCoordinator {
    private(set) var fine: Fine
    private(set) var existingAppeal: Appeal?
    private(set) var voteCounts: AppealVoteCounts?
    private(set) var isMutating: Bool = false
    private(set) var error: String?

    let userId: UUID
    let isMine: Bool

    private let fineRepo: any FineRepository
    private let appealRepo: any AppealRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "fines.detail")

    init(
        fine: Fine,
        userId: UUID,
        fineRepo: any FineRepository,
        appealRepo: any AppealRepository
    ) {
        self.fine = fine
        self.userId = userId
        self.isMine = fine.userId == userId
        self.fineRepo = fineRepo
        self.appealRepo = appealRepo
    }

    func refresh() async {
        do {
            if let updated = try await fineRepo.fine(id: fine.id) {
                fine = updated
            }
            existingAppeal = try await appealRepo.appealForFine(fineId: fine.id)
            if let appeal = existingAppeal {
                voteCounts = try await appealRepo.voteCounts(appealId: appeal.id)
            }
        } catch {
            log.warning("fine refresh failed: \(error.localizedDescription)")
        }
    }

    func startAppeal(reason: String) async {
        guard !isMutating, isMine else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            _ = try await appealRepo.startAppeal(fineId: fine.id, reason: reason)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func payFine() async {
        guard !isMutating, isMine, fine.status == .officialized else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            fine = try await fineRepo.pay(fineId: fine.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
