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
    /// V3 PARTE 7c — historial append-only de snapshots. Vacío hasta
    /// que `refreshHistory(groupId:)` lo hidrate. Nunca causa fail del
    /// store principal.
    public private(set) var history: [GroupGovernanceVersion] = []
    public private(set) var isHistoryLoading: Bool = false

    /// Drives a single `EditDecisionRulesView` sheet. Flipped by
    /// `beginEditing()` / `saveDraft(...)`.
    public var isEditPresented: Bool = false
    /// V2-G2 sub-slice 8 — canonical pair (`DecisionMethod`,
    /// `LegitimacySource`). Legitimacy auto-syncs to the method's
    /// canonical default until the founder touches the legitimacy
    /// picker explicitly; mirrors `DecisionsStore`'s propose-draft
    /// behavior so the surface feels consistent.
    public var draftMethod: DecisionMethod = .majority {
        didSet {
            if draftLegitimacyAutoSync {
                isInternallySettingLegitimacy = true
                draftLegitimacySource = LegitimacySource.defaultFor(method: draftMethod)
                isInternallySettingLegitimacy = false
            }
        }
    }
    public var draftLegitimacySource: LegitimacySource = .majority {
        didSet {
            if !isInternallySettingLegitimacy {
                draftLegitimacyAutoSync = false
            }
        }
    }
    private var draftLegitimacyAutoSync: Bool = true
    private var isInternallySettingLegitimacy: Bool = false
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

    /// V2-G2 sub-slice 8 — surface label uses the canonical method.
    public var resolvedMethod: DecisionMethod {
        rules?.defaultMethod ?? .majority
    }

    /// Useful for legacy displays that still render by `DecisionStyle`.
    public var resolvedStyle: DecisionStyle {
        rules?.defaultStyle ?? .majority
    }

    public var canSaveDraft: Bool {
        // Method + legitimacy are always valid (enum-typed); only quorum has a floor.
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

    /// V3 PARTE 7c — fetch historial. Silent on error: el sheet no se
    /// rompe si la RPC falla, simplemente la sección queda vacía.
    public func refreshHistory(groupId: UUID, limit: Int = 20) async {
        isHistoryLoading = true
        defer { isHistoryLoading = false }
        do {
            history = try await repository.history(groupId: groupId, limit: limit)
        } catch {
            history = []
        }
    }

    public func beginEditing() {
        // Initialize the pair *before* flipping auto-sync on. The didSet
        // observers on both properties turn auto-sync off on every
        // assignment, so we set the values first and re-enable tracking
        // last (mirrors `DecisionsStore.beginProposing`).
        if let rules {
            draftMethod = rules.defaultMethod
            draftLegitimacySource = rules.defaultLegitimacySource
            draftQuorum = rules.quorumMin
            draftNotes = rules.trimmedNotes ?? ""
        } else {
            draftMethod = .majority
            draftLegitimacySource = LegitimacySource.defaultFor(method: .majority)
            draftQuorum = nil
            draftNotes = ""
        }
        draftLegitimacyAutoSync = true
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
                defaultMethod: draftMethod,
                defaultLegitimacySource: draftLegitimacySource,
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
        draftMethod = .majority
        draftLegitimacySource = LegitimacySource.defaultFor(method: .majority)
        draftLegitimacyAutoSync = true
        draftQuorum = nil
        draftNotes = ""
        errorMessage = nil
    }

    public func clearError() { errorMessage = nil }
}
