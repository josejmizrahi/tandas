import Foundation
import Observation
import OSLog

/// Loads the data shown by `ProfileView`: the user's own Profile, group
/// memberships, and a thin slice of their fine stats. Reuses the existing
/// `MyFinesCoordinator.totalOutstanding` math, so the source of truth for
/// fine numbers stays a single coordinator — this one just re-exports the
/// stats the profile screen needs.
@Observable
@MainActor
final class ProfileCoordinator {
    let userId: UUID
    private let profileRepo: any ProfileRepository
    private let fineRepo: any FineRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "profile")

    var profile: Profile?
    var fines: [Fine] = []
    var isLoading: Bool = false
    var loadError: String?

    init(
        userId: UUID,
        profileRepo: any ProfileRepository,
        fineRepo: any FineRepository
    ) {
        self.userId = userId
        self.profileRepo = profileRepo
        self.fineRepo = fineRepo
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        loadError = nil
        do {
            async let profileTask = profileRepo.loadMine()
            async let finesTask = fineRepo.myFines(userId: userId)
            let (loadedProfile, loadedFines) = try await (profileTask, finesTask)
            self.profile = loadedProfile
            self.fines = loadedFines
        } catch {
            log.warning("profile refresh failed: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
    }

    // MARK: - Derived stats

    /// Sum of outstanding (officialized + unpaid + un-waived) fines.
    var totalOutstanding: Decimal {
        fines
            .filter { $0.status == .officialized && !$0.paid && !$0.waived }
            .reduce(Decimal(0)) { $0 + $1.amount }
    }

    /// Sum of fines paid this calendar month.
    var paidThisMonth: Decimal {
        let cal = Calendar.current
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: .now)) ?? .now
        return fines
            .filter { $0.paid && ($0.paidAt ?? .distantPast) >= startOfMonth }
            .reduce(Decimal(0)) { $0 + $1.amount }
    }

    /// Total number of fines ever issued to this member.
    var totalFineCount: Int { fines.count }

    /// True when there's nothing pending — celebratory hero state.
    var isAllClear: Bool { totalOutstanding == 0 }
}
