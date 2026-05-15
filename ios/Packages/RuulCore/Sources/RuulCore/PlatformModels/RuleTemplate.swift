import Foundation

/// A curated UX recipe that pre-composes shape pieces (from
/// `public.rule_shapes`) into a user-friendly, parameterized rule.
/// Templates are the Beta 1 Rule Builder surface — the user picks one
/// and fills 1-3 params; per-piece composition stays hidden.
///
/// Loaded from `public.rule_templates` via `list_rule_templates()` RPC
/// at app boot. Canonical source for additions = mig SQL (mig 00171 seeded
/// the Beta 1 catalog); a future codegen path may emit SQL from a TS file
/// in `supabase/functions/_shared/ruleTemplates/`.
///
/// Per Plans/Active/Governance.md §0.5 (hybrid doctrine 2026-05-14).
public struct RuleBuilderTemplate: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let displayNameES: String
    public let descriptionES: String
    public let category: String
    public let templateKind: String
    public let requiredCapabilities: [String]
    public let defaultParams: JSONConfig
    public let composition: Composition
    public let status: String
    public let sortOrder: Int

    public struct Composition: Codable, Sendable, Hashable {
        public let triggerShapeId: String
        public let conditionShapeIds: [String]
        public let consequenceShapeIds: [String]
        public let scopeHint: String?

        public enum CodingKeys: String, CodingKey {
            case triggerShapeId      = "trigger_shape_id"
            case conditionShapeIds   = "condition_shape_ids"
            case consequenceShapeIds = "consequence_shape_ids"
            case scopeHint           = "scope_hint"
        }

        public init(
            triggerShapeId: String,
            conditionShapeIds: [String] = [],
            consequenceShapeIds: [String] = [],
            scopeHint: String? = nil
        ) {
            self.triggerShapeId      = triggerShapeId
            self.conditionShapeIds   = conditionShapeIds
            self.consequenceShapeIds = consequenceShapeIds
            self.scopeHint           = scopeHint
        }
    }

    public enum CodingKeys: String, CodingKey {
        case id, category, composition, status
        case displayNameES        = "display_name_es"
        case descriptionES        = "description_es"
        case templateKind         = "template_kind"
        case requiredCapabilities = "required_capabilities"
        case defaultParams        = "default_params"
        case sortOrder            = "sort_order"
    }

    public init(
        id: String,
        displayNameES: String,
        descriptionES: String,
        category: String,
        templateKind: String,
        requiredCapabilities: [String] = [],
        defaultParams: JSONConfig = .object([:]),
        composition: Composition,
        status: String = "active",
        sortOrder: Int = 100
    ) {
        self.id                   = id
        self.displayNameES        = displayNameES
        self.descriptionES        = descriptionES
        self.category             = category
        self.templateKind         = templateKind
        self.requiredCapabilities = requiredCapabilities
        self.defaultParams        = defaultParams
        self.composition          = composition
        self.status               = status
        self.sortOrder            = sortOrder
    }
}

/// Scope envelope passed to `publish_rule_version`. Mirrors the server
/// `p_scope jsonb` argument — `{type: "group"}`, `{type: "resource", id}`,
/// or `{type: "series", id}`.
public enum RuleTemplateScope: Sendable, Hashable {
    case group
    case resource(UUID)
    case series(UUID)

    fileprivate func asJSON() -> JSONConfig {
        switch self {
        case .group:
            return .object(["type": .string("group")])
        case .resource(let id):
            return .object([
                "type": .string("resource"),
                "id":   .string(id.uuidString.lowercased())
            ])
        case .series(let id):
            return .object([
                "type": .string("series"),
                "id":   .string(id.uuidString.lowercased())
            ])
        }
    }
}

/// Conflict surfaced by `publish_rule_version`. Beta 1 only emits
/// `same_scope_overlapping` (severity=warning). Future: blocking conflicts
/// trigger a different UI flow.
public struct RuleVersionConflict: Codable, Sendable, Hashable {
    public let type: String
    public let severity: String
    public let againstRuleVersionId: UUID
    public let againstRuleTitle: String?

    public enum CodingKeys: String, CodingKey {
        case type, severity
        case againstRuleVersionId = "against_rule_version_id"
        case againstRuleTitle     = "against_rule_title"
    }

    public init(
        type: String,
        severity: String,
        againstRuleVersionId: UUID,
        againstRuleTitle: String? = nil
    ) {
        self.type                 = type
        self.severity             = severity
        self.againstRuleVersionId = againstRuleVersionId
        self.againstRuleTitle     = againstRuleTitle
    }
}

/// Result of `publish_rule_version`. The returned rule is already active
/// — the iOS layer can navigate to its detail view.
public struct RuleVersionPublishResult: Codable, Sendable, Hashable {
    public let ruleId: UUID
    public let ruleVersionId: UUID
    public let version: Int
    public let conflicts: [RuleVersionConflict]

    public enum CodingKeys: String, CodingKey {
        case ruleId        = "rule_id"
        case ruleVersionId = "rule_version_id"
        case version
        case conflicts
    }

    public init(
        ruleId: UUID,
        ruleVersionId: UUID,
        version: Int,
        conflicts: [RuleVersionConflict] = []
    ) {
        self.ruleId        = ruleId
        self.ruleVersionId = ruleVersionId
        self.version       = version
        self.conflicts     = conflicts
    }
}

extension RuleBuilderTemplate {
    /// JSON-encodes a scope value for the `publish_rule_version` RPC.
    /// Public so coordinators/tests can serialize scopes without
    /// constructing the JSONConfig manually.
    public static func scopeJSON(_ scope: RuleTemplateScope) -> JSONConfig {
        scope.asJSON()
    }
}
