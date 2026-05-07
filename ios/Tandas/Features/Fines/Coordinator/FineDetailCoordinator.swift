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
    private let analytics: (any AnalyticsService)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "fines.detail")

    init(
        fine: Fine,
        userId: UUID,
        fineRepo: any FineRepository,
        appealRepo: any AppealRepository,
        analytics: (any AnalyticsService)? = nil
    ) {
        self.fine = fine
        self.userId = userId
        self.isMine = fine.userId == userId
        self.fineRepo = fineRepo
        self.appealRepo = appealRepo
        self.analytics = analytics
    }

    /// Beta 1 instrumentation (Plans/Active/Beta1.md §4): emit fine_seen
    /// the first time the detail surface renders for this fine. View
    /// callers invoke once on `.task {}` / `.onAppear`.
    func trackSeen() async {
        guard let analytics else { return }
        let beta = BetaAnalytics(analytics: analytics)
        await beta.fineSeen(
            fineId: fine.id,
            ruleSlug: nil,
            isMine: isMine,
            status: fine.status.rawValue
        )
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
            if let analytics {
                let beta = BetaAnalytics(analytics: analytics)
                await beta.fineAppealStarted(fineId: fine.id, ruleSlug: nil)
            }
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
            if let analytics {
                let beta = BetaAnalytics(analytics: analytics)
                let amountInt = NSDecimalNumber(decimal: fine.amount).intValue
                await beta.finePaid(fineId: fine.id, amountMxn: amountInt)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
