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
    var error: CoordinatorError?

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
        error = nil
        defer { isLoading = false }
        do {
            async let profileTask = profileRepo.loadMine()
            async let finesTask = fineRepo.myFines(userId: userId)
            let (loadedProfile, loadedFines) = try await (profileTask, finesTask)
            self.profile = loadedProfile
            self.fines = loadedFines
        } catch {
            log.warning("profile refresh failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar tu perfil")
        }
    }

    func clearError() { error = nil }

    /// Saves the new display name. On success refreshes profile to surface
    /// the updated display name in dependent views (Home greeting, etc.).
    /// Throws are caught — error surfaces via `error: CoordinatorError?`.
    func updateDisplayName(_ newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            error = CoordinatorError(
                title: "Nombre vacío",
                message: "Tu nombre no puede estar vacío.",
                isRetryable: false
            )
            return
        }
        guard trimmed != profile?.displayName else { return }  // no-op if unchanged
        do {
            try await profileRepo.updateDisplayName(trimmed)
            await refresh()
        } catch {
            log.warning("updateDisplayName failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos guardar tu nombre")
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
