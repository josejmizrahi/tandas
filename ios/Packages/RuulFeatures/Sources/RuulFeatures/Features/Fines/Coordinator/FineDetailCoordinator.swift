import Foundation
import OSLog
import RuulUI
import RuulCore

@Observable @MainActor
public final class FineDetailCoordinator {
    public private(set) var fine: Fine
    public private(set) var existingAppeal: Appeal?
    public private(set) var voteCounts: AppealVoteCounts?
    public private(set) var isMutating: Bool = false
    public private(set) var isRefreshing: Bool = false
    /// Surfaces inline above las acciones cuando un mutating op (apelar /
    /// pagar) o el refresh fallan. View consume vía `RuulInlineMessage`.
    /// Per DS v3 §11.4 (CoordinatorError canonical pattern).
    public var error: CoordinatorError?

    public func clearError() { error = nil }

    public let userId: UUID
    public let isMine: Bool

    private let fineRepo: any FineRepository
    private let appealRepo: any AppealRepository
    private let analytics: (any AnalyticsService)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "fines.detail")

    public init(
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
    public func trackSeen() async {
        guard let analytics else { return }
        let beta = BetaAnalytics(analytics: analytics)
        await beta.fineSeen(
            fineId: fine.id,
            ruleSlug: nil,
            isMine: isMine,
            status: fine.status.rawValue
        )
    }

    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
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
            // Refresh-only failures no entran al banner — el detalle sigue
            // mostrando data cacheada. Mutating ops sí surface al banner.
        }
    }

    public func startAppeal(reason: String) async {
        guard !isMutating, isMine else { return }
        isMutating = true
        error = nil
        defer { isMutating = false }
        do {
            _ = try await appealRepo.startAppeal(fineId: fine.id, reason: reason)
            if let analytics {
                let beta = BetaAnalytics(analytics: analytics)
                await beta.fineAppealStarted(fineId: fine.id, ruleSlug: nil)
            }
            await refresh()
        } catch {
            self.error = CoordinatorError.from(error, fallback: "No pudimos abrir tu apelación")
        }
    }

    public func payFine() async {
        guard !isMutating, isMine, fine.status == .officialized else { return }
        isMutating = true
        error = nil
        defer { isMutating = false }
        do {
            fine = try await fineRepo.pay(fineId: fine.id)
            if let analytics {
                let beta = BetaAnalytics(analytics: analytics)
                let amountInt = NSDecimalNumber(decimal: fine.amount).intValue
                await beta.finePaid(fineId: fine.id, amountMxn: amountInt)
            }
        } catch {
            self.error = CoordinatorError.from(error, fallback: "No pudimos marcar como pagada")
        }
    }
}
