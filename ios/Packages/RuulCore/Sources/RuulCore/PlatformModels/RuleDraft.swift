import Foundation

/// One use of a `RuleShape` inside a `RuleDraft`: the shape's id plus
/// the per-instance config the user filled in. The config conforms to
/// the shape's declared `config_fields` schema (validated server-side
/// by `publish_rule_composition`, mig 00245).
///
/// Pure value type — easy to diff, copy, persist, share. The composer
/// builds up a draft of these and the publish step serializes them
/// straight into the RPC payload.
public struct ShapeInstance: Codable, Sendable, Hashable, Identifiable {
    /// Stable instance id used for SwiftUI ForEach + drag-reorder.
    /// Server doesn't see this — it's only meaningful in-app.
    public var id: UUID
    public let shapeId: String
    public var config: JSONConfig

    public init(shapeId: String, config: JSONConfig = .object([:]), id: UUID = UUID()) {
        self.id = id
        self.shapeId = shapeId
        self.config = config
    }

    public enum CodingKeys: String, CodingKey {
        case shapeId = "shape_id"
        case config
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.shapeId = try c.decode(String.self, forKey: .shapeId)
        self.config  = try c.decodeIfPresent(JSONConfig.self, forKey: .config) ?? .object([:])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shapeId, forKey: .shapeId)
        try c.encode(config, forKey: .config)
    }
}

/// A rule under construction. The composer builds these from scratch
/// (free composition) or seeded from a template / existing rule
/// ("start from an example"). On publish, it's serialized into the
/// `publish_rule_composition` RPC (mig 00245).
///
/// Validation invariants (also enforced server-side):
///   - name: 2+ chars trimmed
///   - trigger: exactly one (nil = draft incomplete)
///   - conditions: 0..N, AND-chained
///   - consequences: 1+ (at least one effect — a rule with no effect
///     is just a comment)
public struct RuleDraft: Sendable, Hashable {
    public var name: String
    public var scope: RuleTemplateScope
    public var trigger: ShapeInstance?
    public var conditions: [ShapeInstance]
    public var consequences: [ShapeInstance]
    /// Condition-shaped predicates that BLOCK consequences when ANY
    /// evaluates true on the target. Engine evaluates exceptions
    /// AFTER conditions pass, BEFORE consequences fire (mig 00248).
    /// Honors Constitution §18 (Talmud "regla y excepción") and §22.2
    /// Governance.md. Empty = no exceptions = old behavior.
    public var exceptions: [ShapeInstance]
    public var changeReason: String

    /// Stable identifier for this rule. Honors Constitution §7 and
    /// Social-Primitives §7 — rules need IDs that don't change with
    /// copy localization. When nil, the server auto-derives
    /// `<trigger_snake>_<first_cons_snake>_<6hex>` and returns the
    /// final value in `RuleVersionPublishResult.slug`. When set, must
    /// match `[a-z][a-z0-9_]{0,63}` and be unique within the group
    /// (server enforces both, mig 00246).
    public var slug: String?

    public init(
        name: String = "",
        scope: RuleTemplateScope = .group,
        trigger: ShapeInstance? = nil,
        conditions: [ShapeInstance] = [],
        consequences: [ShapeInstance] = [],
        exceptions: [ShapeInstance] = [],
        changeReason: String = "",
        slug: String? = nil
    ) {
        self.name = name
        self.scope = scope
        self.trigger = trigger
        self.conditions = conditions
        self.consequences = consequences
        self.exceptions = exceptions
        self.changeReason = changeReason
        self.slug = slug
    }

    /// Preview of the slug the server would auto-derive if the draft
    /// publishes without an explicit one. Mirrors the SQL formula in
    /// mig 00246: `<trigger_snake>_<first_cons_snake>_…` (sans the
    /// random suffix — the random part is unknowable client-side).
    /// Returns nil when the draft has no trigger or no consequence yet.
    /// Used by the composer to show "tu acuerdo se guardará como X_…".
    public var suggestedSlugStem: String? {
        guard let triggerId = trigger?.shapeId else { return nil }
        guard let firstConsId = consequences.first?.shapeId else { return nil }
        return RuleDraft.slugifyCamel(triggerId) + "_" + RuleDraft.slugifyCamel(firstConsId)
    }

    /// Pure helper: camelCase → snake_case. Mirrors the SQL
    /// `slugify_camel` function so the iOS-side suggestion matches the
    /// server-side derivation exactly.
    public static func slugifyCamel(_ input: String) -> String {
        guard !input.isEmpty else { return "" }
        var result = ""
        for (i, ch) in input.enumerated() {
            if ch.isUppercase && i > 0 {
                result.append("_")
            }
            result.append(ch.lowercased())
        }
        return result
    }

    /// True when the draft satisfies the server's invariants — what the
    /// composer's "Publicar" button gates on.
    public var isPublishable: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.count >= 2 else { return false }
        guard trigger != nil else { return false }
        guard !consequences.isEmpty else { return false }
        return true
    }

    // MARK: Mutations

    public mutating func setTrigger(_ shapeId: String, config: JSONConfig = .object([:])) {
        if let existing = trigger, existing.shapeId == shapeId {
            // Same shape — preserve config.
            return
        }
        trigger = ShapeInstance(shapeId: shapeId, config: config)
    }

    public mutating func addCondition(_ shapeId: String, config: JSONConfig = .object([:])) {
        conditions.append(ShapeInstance(shapeId: shapeId, config: config))
    }

    public mutating func removeCondition(id: UUID) {
        conditions.removeAll { $0.id == id }
    }

    public mutating func addConsequence(_ shapeId: String, config: JSONConfig = .object([:])) {
        consequences.append(ShapeInstance(shapeId: shapeId, config: config))
    }

    public mutating func removeConsequence(id: UUID) {
        consequences.removeAll { $0.id == id }
    }

    public mutating func addException(_ shapeId: String, config: JSONConfig = .object([:])) {
        exceptions.append(ShapeInstance(shapeId: shapeId, config: config))
    }

    public mutating func removeException(id: UUID) {
        exceptions.removeAll { $0.id == id }
    }

    public mutating func updateConfig(forShapeInstanceId instanceId: UUID, key: String, value: JSONConfig) {
        func patch(_ instance: inout ShapeInstance) {
            guard case .object(var dict) = instance.config else {
                instance.config = .object([key: value])
                return
            }
            dict[key] = value
            instance.config = .object(dict)
        }
        if let i = conditions.firstIndex(where: { $0.id == instanceId }) {
            patch(&conditions[i])
            return
        }
        if let i = consequences.firstIndex(where: { $0.id == instanceId }) {
            patch(&consequences[i])
            return
        }
        if let i = exceptions.firstIndex(where: { $0.id == instanceId }) {
            patch(&exceptions[i])
            return
        }
        if var t = trigger, t.id == instanceId {
            patch(&t)
            trigger = t
        }
    }
}

// MARK: - Seeding from templates / existing rules

extension RuleDraft {
    /// Seed a draft from a curated template — the "start from an
    /// example" path. The user can freely edit / remove pieces after
    /// (the draft is no longer tied to the template).
    public static func from(
        template: RuleBuilderTemplate,
        scope: RuleTemplateScope
    ) -> RuleDraft {
        let triggerInstance = ShapeInstance(
            shapeId: template.composition.triggerShapeId,
            config: template.defaultParams
        )
        let conditions = template.composition.conditionShapeIds.map { id in
            ShapeInstance(shapeId: id, config: template.defaultParams)
        }
        let consequences = template.composition.consequenceShapeIds.map { id in
            ShapeInstance(shapeId: id, config: template.defaultParams)
        }
        return RuleDraft(
            name: template.displayNameES,
            scope: scope,
            trigger: triggerInstance,
            conditions: conditions,
            consequences: consequences
        )
    }

    /// Seed a draft from an existing published rule — the edit-in-place
    /// path. Preserves the rule's slug + scope + name + composition so
    /// `bumpRuleVersion` can publish the modified draft as version N+1
    /// of the SAME rule_id (closing §22.1 of Governance.md).
    ///
    /// Lossiness: `GroupRule.ConsequenceEnvelope.Config` is a typed
    /// view-model struct (amount / baseAmount / stepAmount / stepMinutes)
    /// — only the fine-shape's config fields are preserved through that
    /// type. For non-fine consequences whose extra config fields the
    /// view-model dropped, the composer will show the shape with its
    /// defaults; the user can re-set them before bumping. For Beta 1
    /// where the vast majority of consequences are `fine`, this is
    /// sufficient. A follow-up could fetch the canonical compiled jsonb
    /// from `rule_versions` to eliminate the lossiness.
    public static func from(rule: GroupRule) -> RuleDraft {
        let triggerInstance = ShapeInstance(
            shapeId: rule.trigger.eventType.rawString,
            config: rule.trigger.config
        )
        let conditions = rule.conditions.map { c in
            ShapeInstance(shapeId: c.type.rawString, config: c.config)
        }
        let consequences = rule.consequences.compactMap { env -> ShapeInstance? in
            guard let typeName = env.type else { return nil }
            return ShapeInstance(
                shapeId: typeName,
                config: reconstructConfig(from: env.config)
            )
        }
        let exceptions = rule.exceptions.map { c in
            ShapeInstance(shapeId: c.type.rawString, config: c.config)
        }
        let scope = scopeFrom(rule: rule)
        return RuleDraft(
            name: rule.name,
            scope: scope,
            trigger: triggerInstance,
            conditions: conditions,
            consequences: consequences,
            exceptions: exceptions,
            slug: rule.slug
        )
    }

    private static func reconstructConfig(from cfg: GroupRule.ConsequenceEnvelope.Config?) -> JSONConfig {
        guard let cfg else { return .object([:]) }
        var dict: [String: JSONConfig] = [:]
        if let amount = cfg.amount             { dict["amount"]      = .int(amount) }
        if let baseAmount = cfg.baseAmount     { dict["baseAmount"]  = .int(baseAmount) }
        if let stepAmount = cfg.stepAmount     { dict["stepAmount"]  = .int(stepAmount) }
        if let stepMinutes = cfg.stepMinutes   { dict["stepMinutes"] = .int(stepMinutes) }
        return .object(dict)
    }

    private static func scopeFrom(rule: GroupRule) -> RuleTemplateScope {
        if let resourceId = rule.resourceId { return .resource(resourceId) }
        if let seriesId   = rule.seriesId   { return .series(seriesId) }
        return .group
        // membership + module scopes are §22.5 follow-ups — the picker
        // doesn't surface them yet, so when bumping a membership- or
        // module-scoped rule we fall through to group. The bump RPC
        // preserves the actual scope from the active rule_version's
        // compiled jsonb, so this draft-side scope is just the editor
        // hint; the persisted scope stays correct.
    }
}
