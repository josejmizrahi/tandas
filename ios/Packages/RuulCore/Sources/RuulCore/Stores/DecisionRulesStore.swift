import Foundation
import Observation

/// `@MainActor` store for Primitivas 6/16/22 (Decision rules).
/// Holds the current `GroupDecisionRules` for the active group plus
/// a small editing draft so the View binds directly. Refresh is
/// explicit + idempotent (mirrors PurposeStore semantics).
@MainActor
@Observable
public final class DecisionRulesStore {
    public private(set) var rules: GroupDecisionRules?
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    /// Drives a single `EditDecisionRulesView` sheet. Flipped by
    /// `beginEditing()` / `saveDraft(...)`.
    public var isEditPresented: Bool = false
    public var draftStyle: DecisionStyle = .majority
    public var draftQuorum: Int? = nil
    public var draftNotes: String = ""

    private let repository: CanonicalDecisionRulesRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalDecisionRulesRepository) {
        self.repository = repository
    }

    // MARK: - Derived

    public var hasExplicitRules: Bool {
        guard let rules else { return false }
        return !rules.isDefault
    }

    /// Useful for tighter UI copy ("Sin definir" vs el estilo elegido).
    public var resolvedStyle: DecisionStyle {
        rules?.defaultStyle ?? .majority
    }

    public var canSaveDraft: Bool {
        // Style is always valid (enum-typed); only quorum has a floor.
        guard let q = draftQuorum else { return true }
        return q >= 1
    }

    // MARK: - Intents

    public func refresh(groupId: UUID) async {
        if rules == nil || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            let fetched = try await repository.currentDecisionRules(groupId: groupId)
            rules = fetched
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
        if loadedGroupId == groupId, rules != nil {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    public func beginEditing() {
        if let rules {
            draftStyle = rules.defaultStyle
            draftQuorum = rules.quorumMin
            draftNotes = rules.trimmedNotes ?? ""
        } else {
            draftStyle = .majority
            draftQuorum = nil
            draftNotes = ""
        }
        errorMessage = nil
        isEditPresented = true
    }

    @discardableResult
    public func saveDraft(groupId: UUID) async -> Bool {
        if let q = draftQuorum, q < 1 {
            errorMessage = "El quórum mínimo debe ser al menos 1."
            return false
        }
        do {
            let saved = try await repository.setDecisionRules(
                groupId: groupId,
                defaultStyle: draftStyle,
                quorumMin: draftQuorum,
                notes: draftNotes
            )
            rules = saved
            phase = .loaded
            loadedGroupId = groupId
            errorMessage = nil
            isEditPresented = false
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearDraft() {
        draftStyle = .majority
        draftQuorum = nil
        draftNotes = ""
        errorMessage = nil
    }

    public func clearError() { errorMessage = nil }
}
