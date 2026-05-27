import Foundation
import Observation

/// `@MainActor` store for Primitiva 14 (Disputas). Caches the active
/// disputes list per group + drives the `DisputeSanctionSheet` via a
/// draft. Open path is currently scoped to sanction disputes; broader
/// open_dispute (rule/resource/member subjects) lands in a later slice.
@MainActor
@Observable
public final class DisputesStore {
    public private(set) var disputes: [GroupDispute] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    /// Drives the `DisputeSanctionSheet` from a SanctionRowView action.
    public var isDisputeSanctionPresented: Bool = false
    public var draftSanctionId: UUID?
    public var draftSummary: String = ""

    private let repository: CanonicalDisputesRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalDisputesRepository) {
        self.repository = repository
    }

    // MARK: - Derived

    public var hasDisputes: Bool { !disputes.isEmpty }
    public var activeCount: Int { disputes.count }
    public var sanctionDisputesCount: Int { disputes.filter(\.isSanctionDispute).count }

    public var canSaveDraft: Bool {
        guard draftSanctionId != nil else { return false }
        return !draftSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Intents

    public func refresh(groupId: UUID) async {
        if disputes.isEmpty || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            disputes = try await repository.activeDisputes(groupId: groupId)
            phase = .loaded
            loadedGroupId = groupId
            errorMessage = nil
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            phase = .failed(message: message)
        }
    }

    public func refreshIfNeeded(groupId: UUID) async {
        if loadedGroupId == groupId, !disputes.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    public func beginDisputingSanction(_ sanctionId: UUID) {
        draftSanctionId = sanctionId
        draftSummary = ""
        errorMessage = nil
        isDisputeSanctionPresented = true
    }

    @discardableResult
    public func saveDraft(groupId: UUID) async -> Bool {
        guard let sanctionId = draftSanctionId else {
            errorMessage = "No hay sanción seleccionada."
            return false
        }
        let trimmed = draftSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            errorMessage = "Escribe un resumen."
            return false
        }
        do {
            _ = try await repository.disputeSanction(sanctionId: sanctionId, summary: trimmed)
            await refresh(groupId: groupId)
            isDisputeSanctionPresented = false
            errorMessage = nil
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearDraft() {
        draftSanctionId = nil
        draftSummary = ""
        errorMessage = nil
    }

    public func clearError() { errorMessage = nil }
}
