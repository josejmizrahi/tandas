import Foundation
import Observation

/// `@MainActor` store for Primitiva 4 (Rules). Holds active text
/// rules + the create draft so the View binds directly. Foundation
/// surface: no edit-existing-rule flow, no engine fields.
@MainActor
@Observable
public final class RulesStore {
    public private(set) var rules: [GroupRule] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    public var isCreatePresented: Bool = false
    public var draftTitle: String = ""
    public var draftBody: String = ""
    public var draftType: GroupRuleType = .norm
    public var draftSeverity: Int = 1

    private let repository: CanonicalRulesRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalRulesRepository) {
        self.repository = repository
    }

    // MARK: - Derived state

    public var hasRules: Bool { !rules.isEmpty }
    public var highSeverityRules: [GroupRule] { rules.filter(\.isHighSeverity) }

    /// Top 3 rules sorted by severity desc (used by the GroupHome card).
    public var topRules: [GroupRule] { Array(rules.prefix(3)) }

    public var canSaveDraft: Bool {
        let t = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !b.isEmpty && (0...5).contains(draftSeverity)
    }

    // MARK: - Intents

    public func refresh(groupId: UUID) async {
        if rules.isEmpty || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            let fetched = try await repository.activeRules(groupId: groupId)
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
        if loadedGroupId == groupId, !rules.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    /// Opens the create sheet with a fresh draft.
    public func beginCreating() {
        draftTitle = ""
        draftBody = ""
        draftType = .norm
        draftSeverity = 1
        errorMessage = nil
        isCreatePresented = true
    }

    @discardableResult
    public func createDraft(groupId: UUID) async -> Bool {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            errorMessage = "Escribe el título de la regla."
            return false
        }
        if body.isEmpty {
            errorMessage = "Escribe la regla."
            return false
        }
        if !(0...5).contains(draftSeverity) {
            errorMessage = "Severidad inválida (0–5)."
            return false
        }
        do {
            _ = try await repository.createTextRule(
                groupId: groupId,
                title: title,
                body: body,
                ruleType: draftType,
                severity: draftSeverity
            )
            // After a successful create, refetch so we get the canonical
            // row shape (with version + effective_from) instead of mocking
            // a local row from the create result.
            await refresh(groupId: groupId)
            isCreatePresented = false
            clearDraft()
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    @discardableResult
    public func archive(ruleId: UUID, reason: String? = nil, groupId: UUID) async -> Bool {
        do {
            try await repository.archiveRule(ruleId: ruleId, reason: reason)
            rules.removeAll(where: { $0.id == ruleId })
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearDraft() {
        draftTitle = ""
        draftBody = ""
        draftType = .norm
        draftSeverity = 1
        errorMessage = nil
    }

    public func clearError() { errorMessage = nil }
}
