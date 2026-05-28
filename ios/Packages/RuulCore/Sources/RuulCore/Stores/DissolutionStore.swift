import Foundation
import Observation

/// `@MainActor` store for Primitiva 25 (Disolución). Caches the active
/// dissolution row for a group, drives the propose sheet, and exposes
/// the finalize action when the linked vote has passed.
@MainActor
@Observable
public final class DissolutionStore {
    public private(set) var active: GroupDissolution?
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    // MARK: - Propose draft

    public var isProposePresented: Bool = false
    public var draftReason: String = ""
    public private(set) var draftErrorMessage: String?

    // MARK: - Finalize confirmation

    public var isFinalizeConfirmPresented: Bool = false

    private let repository: CanonicalDissolutionRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalDissolutionRepository) {
        self.repository = repository
    }

    // MARK: - Derived

    public var hasActive: Bool { active != nil }
    public var canFinalize: Bool { active?.canFinalize == true }
    public var canSaveDraft: Bool {
        !draftReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Intents

    public func refresh(groupId: UUID) async {
        if active == nil || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            active = try await repository.current(groupId: groupId)
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
        if loadedGroupId == groupId, active != nil {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    public func beginProposing() {
        draftReason = ""
        draftErrorMessage = nil
        isProposePresented = true
    }

    @discardableResult
    public func saveDraft(groupId: UUID) async -> Bool {
        let trimmed = draftReason.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draftErrorMessage = String(localized: L10n.Dissolution.reasonRequired)
            return false
        }
        do {
            _ = try await repository.propose(groupId: groupId, reason: trimmed)
            await refresh(groupId: groupId)
            isProposePresented = false
            draftErrorMessage = nil
            return true
        } catch {
            draftErrorMessage = UserFacingError.from(error).message
            return false
        }
    }

    @discardableResult
    public func finalize(groupId: UUID) async -> Bool {
        guard let id = active?.id else { return false }
        do {
            try await repository.finalize(dissolutionId: id)
            await refresh(groupId: groupId)
            isFinalizeConfirmPresented = false
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearError() {
        errorMessage = nil
        draftErrorMessage = nil
    }
}
