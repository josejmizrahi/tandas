import Foundation
import OSLog

@Observable @MainActor
final class MyFinesCoordinator {
    private(set) var fines: [Fine] = []
    private(set) var isLoading: Bool = false
    private(set) var error: String?

    private let userId: UUID
    private let fineRepo: any FineRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "fines.mine")

    init(userId: UUID, fineRepo: any FineRepository) {
        self.userId = userId
        self.fineRepo = fineRepo
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            fines = try await fineRepo.myFines(userId: userId)
        } catch {
            log.warning("myFines load failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    var pending: [Fine] {
        fines.filter { $0.status == .proposed || $0.status == .officialized || $0.status == .inAppeal }
    }

    var resolved: [Fine] {
        fines.filter { $0.status == .paid || $0.status == .voided }
    }

    var totalOutstanding: Decimal {
        pending
            .filter { $0.status == .officialized }
            .reduce(Decimal(0)) { $0 + $1.amount }
    }
}
