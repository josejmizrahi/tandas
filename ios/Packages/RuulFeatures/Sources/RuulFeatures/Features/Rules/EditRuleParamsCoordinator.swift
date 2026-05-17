import Foundation
import Observation
import OSLog
import RuulCore

/// Coordinator for the "Editar parámetros" flow. Hydrates `paramValues`
/// from the rule's existing trigger/conditions/consequences configs, then
/// saves by calling `publishRuleVersion` (new `rule_versions` row supersedes).
///
/// Param extraction mirrors what `RuleBuilderCoordinator.selectTemplate`
/// seeds from `template.defaultParams`: we flatten all `JSONConfig.object`
/// configs (trigger + conditions + consequences) into a single
/// `[String: JSONConfig]` dict keyed by their JSON keys. The same
/// `ParamField` widget the builder uses interprets those keys for display
/// and stepping.
@Observable
@MainActor
public final class EditRuleParamsCoordinator: Identifiable {
    public nonisolated let id = UUID()
    public let rule: GroupRule
    public let template: RuleBuilderTemplate

    private let ruleTemplateRepo: any RuleTemplateRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "rule.edit-params")

    /// Flat param dict keyed by JSON field name, e.g. `["amount": .int(200)]`.
    /// Seeded from the rule's existing configs; updated by the param form.
    public var paramValues: [String: JSONConfig]
    public var isSaving: Bool = false
    public var error: CoordinatorError?
    /// True once save succeeds; the presenting view should dismiss + refresh.
    public var didSave: Bool = false

    public init(
        rule: GroupRule,
        template: RuleBuilderTemplate,
        ruleTemplateRepo: any RuleTemplateRepository
    ) {
        self.rule = rule
        self.template = template
        self.ruleTemplateRepo = ruleTemplateRepo
        // Seed from the rule's existing configs. Fall back to `defaultParams`
        // for any key the rule's configs don't carry (e.g. a new field added
        // to the template after the rule was created).
        var out = Self.extractDefaultParams(from: template)
        for (k, v) in Self.extractRuleParams(from: rule) {
            out[k] = v
        }
        self.paramValues = out
    }

    // MARK: - Save

    public func save(scope: RuleTemplateScope) async {
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            _ = try await ruleTemplateRepo.publishRuleVersion(
                groupId: rule.groupId,
                templateId: template.id,
                shapeParams: .object(paramValues),
                scope: scope,
                title: nil,
                changeReason: "Editar parámetros"
            )
            didSave = true
            log.info("saved rule params for rule \(self.rule.id) via template \(self.template.id)")
        } catch {
            log.warning("rule params save failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos guardar los cambios")
        }
    }

    public func clearError() { error = nil }

    // MARK: - Param extraction

    /// Walks the rule's trigger.config + every condition leaf's config
    /// (anywhere in the AND/OR/NOT tree, since `GroupRule.conditions`
    /// is the flat pre-order leaf view of `conditionsTree` per §22.4)
    /// + consequences[].config and flattens all object entries into a
    /// single [String: JSONConfig] dict.
    private static func extractRuleParams(from rule: GroupRule) -> [String: JSONConfig] {
        var out: [String: JSONConfig] = [:]
        // Trigger config
        if case .object(let dict) = rule.trigger.config {
            for (k, v) in dict { out[k] = v }
        }
        // Conditions — `rule.conditions` is already the flat leaves view
        // (the decoder unwraps trees via `ConditionNode.allLeaves`), so
        // a tree-shaped rule surfaces every config key its leaves
        // reference regardless of where in the tree they sit.
        for cond in rule.conditions {
            if case .object(let dict) = cond.config {
                for (k, v) in dict { out[k] = v }
            }
        }
        // Consequences — GroupRule.ConsequenceEnvelope carries a typed Config,
        // not a JSONConfig, so we re-map the known fields to the canonical
        // param keys the ParamField widget understands.
        for cons in rule.consequences {
            guard let cfg = cons.config else { continue }
            if let amount = cfg.amount { out["amount"] = .int(amount) }
            if let base = cfg.baseAmount { out["base_amount"] = .int(base) }
            if let step = cfg.stepAmount { out["step_amount"] = .int(step) }
            if let stepMins = cfg.stepMinutes { out["step_minutes"] = .int(stepMins) }
        }
        return out
    }

    /// Fallback seeds from `template.defaultParams` so unknown keys still
    /// show a sensible starting value rather than being absent.
    private static func extractDefaultParams(from template: RuleBuilderTemplate) -> [String: JSONConfig] {
        if case .object(let dict) = template.defaultParams { return dict }
        return [:]
    }

    // MARK: - Param helpers (mirrors RuleBuilderCoordinator)

    public func setParam(_ key: String, intValue: Int) {
        paramValues[key] = .int(intValue)
    }

    public func paramInt(_ key: String) -> Int? {
        paramValues[key]?.intValue
    }

    /// Sorted list of param keys for deterministic form rendering.
    /// Mirrors `ParamFormView.paramKeys()` in `RuleBuilderView`.
    public var sortedParamKeys: [String] {
        let ranks: [String: Int] = [
            "amount": 0, "threshold_cents": 0,
            "minutes": 1, "hours": 2,
            "duration_hours": 10, "quorum_percent": 11, "threshold_percent": 12,
        ]
        return paramValues.keys.sorted { lhs, rhs in
            (ranks[lhs] ?? 99, lhs) < (ranks[rhs] ?? 99, rhs)
        }
    }
}
