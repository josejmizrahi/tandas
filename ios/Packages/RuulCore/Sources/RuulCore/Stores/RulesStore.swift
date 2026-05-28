import Foundation
import Observation

/// `@MainActor` store for Primitiva 4 (Rules). Holds active text rules
/// + the text create draft so the view binds directly.
///
/// V2-G3.1 — extended with engine-rule surface: the catalog of
/// institutional atoms (triggers / conditions / consequences), the
/// active engine rules and the template-only shape-builder draft
/// (single trigger + optional condition + single consequence in this
/// slice). Server-side `validate_rule_shape` is the source of truth;
/// the iOS dry-run is advisory.
@MainActor
@Observable
public final class RulesStore {
    public private(set) var rules: [GroupRule] = []
    public private(set) var engineRules: [EngineRule] = []
    public private(set) var availableShapes: [RuleShape] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    // Shared create-sheet draft.
    public var isCreatePresented: Bool = false
    public var draftMode: RuleDraftMode = .text
    public var draftTitle: String = ""
    public var draftType: GroupRuleType = .norm
    public var draftSeverity: Int = 1

    // Text-only draft.
    public var draftBody: String = ""

    // Engine draft (V2-G3.1: single-consequence per rule).
    public var draftTriggerKey: String?
    public var draftConditionKey: String?
    public var draftConditionFields: [String: RPCJSONValue] = [:]
    public var draftConsequenceKey: String?
    public var draftConsequenceFields: [String: RPCJSONValue] = [:]

    /// Last `validate_rule_shape(...)` result for the current engine
    /// draft. `nil` = no dry-run was performed yet.
    public private(set) var draftValidation: RuleShapeValidationResult?

    private let repository: CanonicalRulesRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalRulesRepository) {
        self.repository = repository
    }

    // MARK: - Derived state

    public var hasRules: Bool { !rules.isEmpty }
    public var hasEngineRules: Bool { !engineRules.isEmpty }
    public var highSeverityRules: [GroupRule] { rules.filter(\.isHighSeverity) }

    /// Top 3 rules sorted by severity desc (used by the GroupHome card).
    public var topRules: [GroupRule] { Array(rules.prefix(3)) }

    public var triggerShapes: [RuleShape] {
        availableShapes.filter { $0.category == .trigger }
    }

    public var selectedTrigger: RuleShape? {
        guard let key = draftTriggerKey else { return nil }
        return availableShapes.first(where: { $0.shapeKey == key })
    }

    public var selectedCondition: RuleShape? {
        guard let key = draftConditionKey else { return nil }
        return availableShapes.first(where: { $0.shapeKey == key })
    }

    public var selectedConsequence: RuleShape? {
        guard let key = draftConsequenceKey else { return nil }
        return availableShapes.first(where: { $0.shapeKey == key })
    }

    /// Conditions the user may pick for the currently selected trigger.
    /// Driven by `schema.compatible_conditions` (soft hint on the
    /// catalog); empty array = any condition is allowed.
    public var compatibleConditions: [RuleShape] {
        guard let trigger = selectedTrigger else { return [] }
        let keys = Set(trigger.compatibleConditionKeys)
        let pool = availableShapes.filter { $0.category == .condition }
        return keys.isEmpty ? pool : pool.filter { keys.contains($0.shapeKey) }
    }

    public var compatibleConsequences: [RuleShape] {
        guard let trigger = selectedTrigger else { return [] }
        let keys = Set(trigger.compatibleConsequenceKeys)
        let pool = availableShapes.filter { $0.category == .consequence }
        return keys.isEmpty ? pool : pool.filter { keys.contains($0.shapeKey) }
    }

    public var canSaveDraft: Bool {
        let t = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, (0...5).contains(draftSeverity) else { return false }
        switch draftMode {
        case .text:
            return !draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .engine:
            return draftTriggerKey != nil && draftConsequenceKey != nil
        }
    }

    // MARK: - Intents (read)

    public func refresh(groupId: UUID) async {
        if rules.isEmpty || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            async let text = repository.activeRules(groupId: groupId)
            async let engine = repository.engineRules(groupId: groupId)
            let (textRules, engineRulesFetched) = try await (text, engine)
            self.rules = textRules
            self.engineRules = engineRulesFetched
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

    /// Lazy-fetch the atom catalog (`rule_shapes_catalog`). Called once
    /// per store lifetime; the catalog is global + small.
    public func loadShapesIfNeeded() async {
        guard availableShapes.isEmpty else { return }
        do {
            availableShapes = try await repository.listRuleShapes()
        } catch {
            errorMessage = UserFacingError.from(error).message
        }
    }

    // MARK: - Intents (draft)

    /// Opens the create sheet with a fresh draft in the chosen mode.
    /// Engine mode triggers a catalog load if it hasn't happened yet.
    public func beginCreating(mode: RuleDraftMode = .text) {
        clearDraft()
        draftMode = mode
        isCreatePresented = true
        if mode == .engine {
            Task { await loadShapesIfNeeded() }
        }
    }

    public func switchDraftMode(to newMode: RuleDraftMode) {
        guard newMode != draftMode else { return }
        draftMode = newMode
        // Switching modes resets the mode-specific payload but keeps
        // the title/type/severity the user already typed.
        if newMode == .engine {
            draftBody = ""
            Task { await loadShapesIfNeeded() }
        } else {
            resetEngineDraft()
        }
        draftValidation = nil
    }

    public func selectTrigger(key: String?) {
        draftTriggerKey = key
        // Clear downstream state — different trigger → different
        // compatible conditions/consequences.
        draftConditionKey = nil
        draftConditionFields = [:]
        draftConsequenceKey = nil
        draftConsequenceFields = [:]
        draftValidation = nil
    }

    public func selectCondition(key: String?) {
        draftConditionKey = key
        draftConditionFields = key.flatMap { defaultFields(forShapeKey: $0) } ?? [:]
        draftValidation = nil
    }

    public func selectConsequence(key: String?) {
        draftConsequenceKey = key
        draftConsequenceFields = key.flatMap { defaultFields(forShapeKey: $0) } ?? [:]
        draftValidation = nil
    }

    public func setConditionField(_ field: String, _ value: RPCJSONValue?) {
        if let value { draftConditionFields[field] = value }
        else { draftConditionFields.removeValue(forKey: field) }
        draftValidation = nil
    }

    public func setConsequenceField(_ field: String, _ value: RPCJSONValue?) {
        if let value { draftConsequenceFields[field] = value }
        else { draftConsequenceFields.removeValue(forKey: field) }
        draftValidation = nil
    }

    /// Builds the engine-rule payload from the current draft. Returns
    /// `nil` if the draft is missing required pieces (trigger or
    /// consequence). Visible so views and tests can inspect what would
    /// be sent.
    public func currentEngineDraftPayload() -> RuleShapePayload? {
        guard let trigger = draftTriggerKey, let conseqKey = draftConsequenceKey else {
            return nil
        }
        let condition: EngineRuleCondition? = draftConditionKey.map {
            EngineRuleCondition(kind: $0, fields: draftConditionFields)
        }
        let consequence = EngineRuleConsequence(
            kind: conseqKey,
            fields: draftConsequenceFields
        )
        return RuleShapePayload(
            shapeKey: trigger,
            conditionTree: condition,
            consequences: [consequence]
        )
    }

    /// Server-side dry-run for the current engine draft. Updates
    /// `draftValidation` so the view can render inline errors.
    @discardableResult
    public func dryRunValidate() async -> RuleShapeValidationResult? {
        guard draftMode == .engine, let payload = currentEngineDraftPayload() else {
            return nil
        }
        do {
            let result = try await repository.validateRuleShape(payload)
            draftValidation = result
            return result
        } catch {
            errorMessage = UserFacingError.from(error).message
            return nil
        }
    }

    @discardableResult
    public func createDraft(groupId: UUID) async -> Bool {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            errorMessage = "Escribe el título de la regla."
            return false
        }
        if !(0...5).contains(draftSeverity) {
            errorMessage = "Severidad inválida (0–5)."
            return false
        }

        switch draftMode {
        case .text:
            return await createTextDraft(groupId: groupId, title: title)
        case .engine:
            return await createEngineDraft(groupId: groupId, title: title)
        }
    }

    private func createTextDraft(groupId: UUID, title: String) async -> Bool {
        let body = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            errorMessage = "Escribe la regla."
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
            await refresh(groupId: groupId)
            isCreatePresented = false
            clearDraft()
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    private func createEngineDraft(groupId: UUID, title: String) async -> Bool {
        guard let trigger = draftTriggerKey, let conseqKey = draftConsequenceKey else {
            errorMessage = "Elige un disparador y una consecuencia."
            return false
        }
        let condition: EngineRuleCondition? = draftConditionKey.map {
            EngineRuleCondition(kind: $0, fields: draftConditionFields)
        }
        let consequences = [
            EngineRuleConsequence(kind: conseqKey, fields: draftConsequenceFields)
        ]
        do {
            _ = try await repository.createEngineRule(
                groupId: groupId,
                title: title,
                shapeKey: trigger,
                condition: condition,
                consequences: consequences,
                ruleType: draftType,
                severity: draftSeverity
            )
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
            engineRules.removeAll(where: { $0.id == ruleId })
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearDraft() {
        draftMode = .text
        draftTitle = ""
        draftBody = ""
        draftType = .norm
        draftSeverity = 1
        resetEngineDraft()
        errorMessage = nil
    }

    public func clearError() { errorMessage = nil }

    // MARK: - Helpers

    private func resetEngineDraft() {
        draftTriggerKey = nil
        draftConditionKey = nil
        draftConditionFields = [:]
        draftConsequenceKey = nil
        draftConsequenceFields = [:]
        draftValidation = nil
    }

    private func defaultFields(forShapeKey key: String) -> [String: RPCJSONValue] {
        guard let shape = availableShapes.first(where: { $0.shapeKey == key }) else {
            return [:]
        }
        var seeded: [String: RPCJSONValue] = [:]
        for field in shape.fields {
            if let value = field.default {
                seeded[field.key] = value
            }
        }
        return seeded
    }
}

/// Mode the user is composing a rule in. `.engine` activates the
/// template-only shape builder (V2-G3.1).
public enum RuleDraftMode: String, Sendable, Hashable, CaseIterable {
    case text
    case engine
}
