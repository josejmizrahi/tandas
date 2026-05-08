import Foundation
import Observation
import OSLog
import RuulCore

/// Coordinator backing `VoidFineSheet`. Resolves the target member's display
/// name, validates the reason, calls `FineRepository.void`, and humanizes
/// server errors. View is dumb: only renders this state and dispatches
/// `submit()`.
///
/// V1 entry: `FineDetailView` admin footer.
///
/// `onSubmitted` is the auto-refresh hook. It runs *before* `submit` returns
/// on success, so the parent `FineDetailCoordinator.refresh()` repaints
/// FineDetailView before the View dismisses the sheet — no flash of stale
/// state behind the closing sheet animation. Defaults to no-op so unit
/// tests don't have to wire it.
@Observable @MainActor
final class VoidFineCoordinator {
    let fine: Fine

    private(set) var targetMemberName: String = "el multado"
    var reason: String = ""
    private(set) var isSubmitting: Bool = false
    private(set) var error: String?

    private let fineRepo: any FineRepository
    private let groupsRepo: any GroupsRepository
    private let onSubmitted: () async -> Void
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "fines.void")

    init(
        fine: Fine,
        fineRepo: any FineRepository,
        groupsRepo: any GroupsRepository,
        onSubmitted: @escaping () async -> Void = {}
    ) {
        self.fine = fine
        self.fineRepo = fineRepo
        self.groupsRepo = groupsRepo
        self.onSubmitted = onSubmitted
    }

    // MARK: - Derived state

    var canSubmit: Bool {
        guard !isSubmitting else { return false }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2
    }

    // MARK: - Target name resolution

    /// Looks up the fined user's display name in the group. Falls back to
    /// "el multado" on any failure (logged warning, no UI error).
    func resolveTargetName() async {
        do {
            let rows = try await groupsRepo.membersWithProfiles(of: fine.groupId)
            if let mwp = rows.first(where: { $0.member.userId == fine.userId }) {
                targetMemberName = mwp.displayName
            }
        } catch {
            log.warning("resolveTargetName failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Submit

    /// Voids the fine via FineRepository. On success: calls `onSubmitted`
    /// (so the parent FineDetailCoordinator refreshes BEFORE the View
    /// dismisses the sheet) and returns the updated Fine. On failure: sets
    /// `error` via `humanize`, returns nil.
    @discardableResult
    func submit() async -> Fine? {
        guard canSubmit else { return nil }
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)

        isSubmitting = true
        error = nil
        defer { isSubmitting = false }

        do {
            let updated = try await fineRepo.void(fineId: fine.id, reason: trimmedReason)
            await onSubmitted()
            return updated
        } catch {
            self.error = humanize(error: error)
            return nil
        }
    }

    // MARK: - Error humanization

    private func humanize(error: Error) -> String {
        let raw = (error as NSError).localizedDescription.lowercased()
        if raw.contains("not authenticated") {
            return "Tu sesión expiró. Volvé a entrar."
        }
        if raw.contains("only admins") {
            return "Solo admins pueden anular multas."
        }
        if raw.contains("cannot void fine with status") {
            return "Esta multa ya no se puede anular (estado: \(fine.status.displayLabel))"
        }
        if raw.contains("reason required") {
            return "Escribe un motivo (al menos 2 caracteres)."
        }
        if raw.contains("fine not found") {
            return "Esta multa ya no existe."
        }
        return "No pudimos anular la multa. Intenta de nuevo."
    }
}
