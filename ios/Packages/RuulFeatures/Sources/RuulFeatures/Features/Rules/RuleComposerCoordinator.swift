import Foundation
import Observation
import OSLog
import RuulCore

/// State + I/O for the free-composition Rule Composer.
///
/// Unlike `RuleBuilderCoordinator` (template wizard), this coordinator
/// holds a single editable `RuleDraft` and lets the user freely
/// add/remove pieces in any order. No phases — one screen, sections
/// that the user iterates over until the draft is publishable.
///
/// Flow:
///   1. Caller constructs with `init(group:, shapeRegistry:, repo:, scope:, resourceType:)`
///      or `init(group:, shapeRegistry:, repo:, draft:)` to start from
///      a seed (template or copied rule).
///   2. UI binds to `coordinator.draft.*` for live state.
///   3. UI calls mutation methods (`setTrigger`, `addCondition`,
///      `removeCondition`, …) to modify the draft.
///   4. UI gates "Publicar" on `coordinator.canPublish`.
///   5. UI calls `publish()` on tap; result lands in
///      `coordinator.publishResult` (Success) or
///      `coordinator.error` (Failure).
///
/// Compatibility filtering is enforced at the picker level:
/// `availableTriggers`, `availableConditions`, `availableConsequences`
/// return only shapes the catalog (rule_shapes) declares compatible
/// with the current `draft.scope` + resolved resource type.
@Observable @MainActor
public final class RuleComposerCoordinator: Identifiable {
    public nonisolated let id = UUID()

    /// The mutable draft. Bound directly to the view; mutations go
    /// through the helper methods on this coordinator to keep
    /// validation + side effects consistent.
    public private(set) var draft: RuleDraft

    public let group: Group
    public let shapeRegistry: RuleShapeRegistry
    public let resourceType: String?

    public private(set) var isPublishing: Bool = false
    public private(set) var publishResult: RuleVersionPublishResult?
    public private(set) var error: String?

    private let repo: any RuleTemplateRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "rule-composer")

    // MARK: Init

    public init(
        group: Group,
        shapeRegistry: RuleShapeRegistry,
        repo: any RuleTemplateRepository,
        scope: RuleTemplateScope,
        resourceType: String? = nil
    ) {
        self.group = group
        self.shapeRegistry = shapeRegistry
        self.repo = repo
        self.resourceType = resourceType
        self.draft = RuleDraft(scope: scope)
    }

    /// Seed from a pre-populated draft (template-as-starting-point or
    /// copy-from-existing flow). The resource type comes from the
    /// caller because the draft itself only knows scope, not the
    /// underlying resource type.
    public init(
        group: Group,
        shapeRegistry: RuleShapeRegistry,
        repo: any RuleTemplateRepository,
        draft: RuleDraft,
        resourceType: String? = nil
    ) {
        self.group = group
        self.shapeRegistry = shapeRegistry
        self.repo = repo
        self.resourceType = resourceType
        self.draft = draft
    }

    // MARK: Catalog options

    /// Triggers the user may pick for the current scope + resource type.
    /// Sorted by `sortOrder` then label.
    public var availableTriggers: [RuleShape] {
        let scopeKey = scopeKey(for: draft.scope)
        return shapeRegistry
            .shapes(kind: .trigger, scope: scopeKey, resourceType: resourceType)
            .sorted { ($0.sortOrder, $0.labelES) < ($1.sortOrder, $1.labelES) }
    }

    /// Conditions the user may add. Conditions don't filter by scope/
    /// resource type at the catalog level (they operate on the rule
    /// target, not the scope), so we return all `condition` shapes.
    public var availableConditions: [RuleShape] {
        shapeRegistry.shapes(of: .condition)
            .sorted { ($0.sortOrder, $0.labelES) < ($1.sortOrder, $1.labelES) }
    }

    /// Consequences the user may add. Same rationale as conditions.
    public var availableConsequences: [RuleShape] {
        shapeRegistry.shapes(of: .consequence)
            .sorted { ($0.sortOrder, $0.labelES) < ($1.sortOrder, $1.labelES) }
    }

    public func shape(id: String) -> RuleShape? { shapeRegistry.shape(id: id) }

    public var canPublish: Bool {
        draft.isPublishable && !isPublishing
    }

    // MARK: Mutations

    public func setName(_ newValue: String) {
        draft.name = newValue
    }

    public func setChangeReason(_ newValue: String) {
        draft.changeReason = newValue
    }

    public func setTrigger(shapeId: String) {
        // Replacing the trigger drops the previous one's config; seed
        // defaults for the new shape so the form opens with sensible
        // numbers.
        var seeded = ShapeInstance(shapeId: shapeId, config: defaultConfig(for: shapeId))
        seeded.id = draft.trigger?.id ?? seeded.id
        draft.trigger = seeded
    }

    public func clearTrigger() {
        draft.trigger = nil
    }

    public func addCondition(shapeId: String) {
        draft.addCondition(shapeId, config: defaultConfig(for: shapeId))
    }

    public func removeCondition(id: UUID) {
        draft.removeCondition(id: id)
    }

    public func addConsequence(shapeId: String) {
        draft.addConsequence(shapeId, config: defaultConfig(for: shapeId))
    }

    public func removeConsequence(id: UUID) {
        draft.removeConsequence(id: id)
    }

    public func updateConfig(forShapeInstanceId instanceId: UUID, key: String, value: JSONConfig) {
        draft.updateConfig(forShapeInstanceId: instanceId, key: key, value: value)
    }

    // MARK: Publish

    @discardableResult
    public func publish() async -> RuleVersionPublishResult? {
        guard canPublish else { return nil }
        isPublishing = true
        error = nil
        defer { isPublishing = false }
        do {
            let result = try await repo.publishRuleComposition(groupId: group.id, draft: draft)
            publishResult = result
            return result
        } catch {
            self.error = humanize(error: error)
            log.warning("composer publish failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Helpers

    /// Builds the default config for a freshly-picked shape by walking
    /// its `configFields` and using each field's `defaultValue` when
    /// present. Returns `.object([:])` when the shape has no defaults
    /// (the user fills everything by hand).
    private func defaultConfig(for shapeId: String) -> JSONConfig {
        guard let shape = shapeRegistry.shape(id: shapeId) else { return .object([:]) }
        var values: [String: JSONConfig] = [:]
        for field in shape.configFields {
            if let v = field.defaultValue {
                values[field.key] = v
            }
        }
        return .object(values)
    }

    private func scopeKey(for scope: RuleTemplateScope) -> String {
        switch scope {
        case .group:       return "group"
        case .resource:    return "resource"
        case .series:      return "series"
        }
    }

    private func humanize(error: Error) -> String {
        let raw = (error as NSError).localizedDescription.lowercased()
        if raw.contains("modifyrules") {
            return "No tienes permisos para crear reglas en este grupo."
        }
        if raw.contains("at least 2 characters") {
            return "El nombre debe tener al menos 2 caracteres."
        }
        if raw.contains("at least one consequence") {
            return "Agrega al menos una consecuencia."
        }
        if raw.contains("does not support scope") {
            return "El disparador elegido no aplica a este nivel (grupo / serie / instancia)."
        }
        if raw.contains("does not support resource_type") {
            return "El disparador elegido no aplica a este tipo de recurso."
        }
        if raw.contains("not found") {
            return "Una pieza de la regla ya no está disponible en el catálogo."
        }
        return "No pudimos crear la regla. Intenta de nuevo."
    }
}
