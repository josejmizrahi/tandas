import Foundation

// MARK: - Rule shape catalog (V2-G3.1)
//
// `rule_shapes_catalog` is the institutional vocabulary for engine rules.
// One row per atom — a trigger (WHEN), a condition (IF) or a consequence
// (THEN). Atoms are versionable + auditable + explainable; iOS never
// invents them, it only picks from the catalog and fills in schema-driven
// field values. Templates-only in G3.1; freeform jsonb is V3.

public enum RuleAtomCategory: String, Codable, Sendable, Hashable, CaseIterable {
    case trigger
    case condition
    case consequence
}

/// Sync = canonical consequence that mutates state in the same transaction
/// as the trigger event (e.g. `issue_sanction`, `set_membership_state`).
/// Async = derived side effect that enqueues an outbox row and is not
/// part of the canonical decision (e.g. `send_notification`).
/// V2-G3.4 dispatcher reads this tag to route consequences correctly.
public enum ConsequenceExecution: String, Codable, Sendable, Hashable {
    case sync
    case async
}

/// Trigger-level scope hint. Informational in G3.1; G3.3 evaluator uses
/// it to filter rules by subject context (group-wide vs member-specific
/// vs resource-specific).
public enum RuleAtomScope: String, Codable, Sendable, Hashable {
    case group
    case member
    case resource
}

/// One field declaration inside an atom's `schema.fields[]`. Drives the
/// iOS shape-builder form (label, type, required, enum constraints) and
/// is the same shape `validate_rule_shape(...)` enforces server-side.
public struct RuleShapeField: Codable, Sendable, Hashable, Equatable {
    public let key: String
    public let type: String   // number | integer | string | enum | boolean | string_array
    public let required: Bool?
    public let label: String?
    public let min: Decimal?
    public let max: Decimal?
    public let `default`: RPCJSONValue?
    public let `enum`: [String]?

    enum CodingKeys: String, CodingKey {
        case key, type, required, label, min, max
        case `default`
        case `enum`
    }

    public var isRequired: Bool { required ?? false }
}

/// Shape-specific schema payload. Atom rows live in `rule_shapes_catalog`
/// with category-specific keys — triggers describe an event_type +
/// compatibility hints, conditions/consequences describe their `kind`/
/// `action` plus the field list. Everything is optional at this layer
/// because the same struct round-trips all three categories.
public struct RuleShapeSchema: Codable, Sendable, Hashable, Equatable {
    // Trigger-specific
    public let eventType: String?
    public let payloadKeys: [String]?
    public let compatibleConditions: [String]?
    public let compatibleConsequences: [String]?
    public let scope: RuleAtomScope?

    // Condition-specific
    public let kind: String?

    // Consequence-specific
    public let action: String?
    public let execution: ConsequenceExecution?
    public let authorityRequired: String?

    // Conditions + consequences share this shape.
    public let fields: [RuleShapeField]?

    enum CodingKeys: String, CodingKey {
        case eventType              = "event_type"
        case payloadKeys            = "payload_keys"
        case compatibleConditions   = "compatible_conditions"
        case compatibleConsequences = "compatible_consequences"
        case scope
        case kind
        case action
        case execution
        case authorityRequired      = "authority_required"
        case fields
    }
}

/// One row in `rule_shapes_catalog`, surfaced via `list_rule_shapes()`.
public struct RuleShape: Codable, Sendable, Hashable, Equatable, Identifiable {
    public let shapeKey: String
    public let category: RuleAtomCategory
    public let displayName: String
    public let description: String?
    public let schema: RuleShapeSchema
    public let resourceTypes: [String]
    public let metadata: [String: RPCJSONValue]?

    public var id: String { shapeKey }

    enum CodingKeys: String, CodingKey {
        case shapeKey      = "shape_key"
        case category
        case displayName   = "display_name"
        case description
        case schema
        case resourceTypes = "resource_types"
        case metadata
    }
}

public extension RuleShape {
    var fields: [RuleShapeField] { schema.fields ?? [] }
    var triggerEventType: String? { schema.eventType }
    var compatibleConditionKeys: [String] { schema.compatibleConditions ?? [] }
    var compatibleConsequenceKeys: [String] { schema.compatibleConsequences ?? [] }
    var execution: ConsequenceExecution? { schema.execution }
    var authorityRequired: String? { schema.authorityRequired }
    var iconSystemName: String? {
        if case .string(let s)? = metadata?["icon"] { return s }
        return nil
    }
}

// MARK: - Validation result (validate_rule_shape RPC)

public struct RuleShapeValidationError: Codable, Sendable, Hashable, Equatable {
    public let path: String
    public let code: String
    public let message: String

    public init(path: String, code: String, message: String) {
        self.path = path
        self.code = code
        self.message = message
    }
}

public struct RuleShapeValidationResult: Codable, Sendable, Hashable, Equatable {
    public let valid: Bool
    public let errors: [RuleShapeValidationError]
    public let shapeKey: String?
    public let triggerEventType: String?

    enum CodingKeys: String, CodingKey {
        case valid, errors
        case shapeKey         = "shape_key"
        case triggerEventType = "trigger_event_type"
    }

    public init(
        valid: Bool,
        errors: [RuleShapeValidationError] = [],
        shapeKey: String? = nil,
        triggerEventType: String? = nil
    ) {
        self.valid = valid
        self.errors = errors
        self.shapeKey = shapeKey
        self.triggerEventType = triggerEventType
    }
}

// MARK: - Engine rule wire payload (create_engine_rule + group_rules_engine)

/// In-flight predicate pick. `kind` references a `condition.*` atom key;
/// `fields` carries the user-supplied values keyed by the atom's field
/// `key`. Server re-validates so iOS doesn't gate.
public struct EngineRuleCondition: Codable, Sendable, Hashable, Equatable {
    public let kind: String
    public let fields: [String: RPCJSONValue]

    public init(kind: String, fields: [String: RPCJSONValue]) {
        self.kind = kind
        self.fields = fields
    }
}

/// In-flight consequence pick. `kind` references a `consequence.*` atom
/// key; `fields` carries user-supplied values per the atom's `fields[]`.
public struct EngineRuleConsequence: Codable, Sendable, Hashable, Equatable {
    public let kind: String
    public let fields: [String: RPCJSONValue]

    public init(kind: String, fields: [String: RPCJSONValue]) {
        self.kind = kind
        self.fields = fields
    }
}

/// Result of `create_engine_rule(...)`: the new rule id + the first
/// published version id (mirrors `CreateTextRuleResult`).
public struct CreateEngineRuleResult: Codable, Sendable, Hashable, Equatable {
    public let ruleId: UUID
    public let versionId: UUID

    enum CodingKeys: String, CodingKey {
        case ruleId    = "rule_id"
        case versionId = "version_id"
    }

    public init(ruleId: UUID, versionId: UUID) {
        self.ruleId = ruleId
        self.versionId = versionId
    }
}

/// One row from `group_rules_engine(p_group_id)`. Carries the shape +
/// trigger + condition_tree + consequences so iOS can render the rule
/// explicably (which atoms it's wired to, not just its title).
public struct EngineRule: Codable, Sendable, Hashable, Equatable, Identifiable {
    public let id: UUID                           // rule_id
    public let currentVersionId: UUID?
    public let groupId: UUID
    public let title: String
    public let ruleType: GroupRuleType
    public let severity: Int
    public let status: String
    public let createdBy: UUID?
    public let effectiveFrom: Date?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let shapeKey: String?
    public let triggerEventType: String?
    public let condition: EngineRuleCondition?
    public let consequences: [EngineRuleConsequence]

    enum CodingKeys: String, CodingKey {
        case id                = "rule_id"
        case currentVersionId  = "current_version_id"
        case groupId           = "group_id"
        case title
        case ruleType          = "rule_type"
        case severity
        case status
        case createdBy         = "created_by"
        case effectiveFrom     = "effective_from"
        case createdAt         = "created_at"
        case updatedAt         = "updated_at"
        case shapeKey          = "shape_key"
        case triggerEventType  = "trigger_event_type"
        case condition         = "condition_tree"
        case consequences
    }

    public init(
        id: UUID,
        currentVersionId: UUID? = nil,
        groupId: UUID,
        title: String,
        ruleType: GroupRuleType = .norm,
        severity: Int = 1,
        status: String = "active",
        createdBy: UUID? = nil,
        effectiveFrom: Date? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        shapeKey: String? = nil,
        triggerEventType: String? = nil,
        condition: EngineRuleCondition? = nil,
        consequences: [EngineRuleConsequence] = []
    ) {
        self.id = id
        self.currentVersionId = currentVersionId
        self.groupId = groupId
        self.title = title
        self.ruleType = ruleType
        self.severity = severity
        self.status = status
        self.createdBy = createdBy
        self.effectiveFrom = effectiveFrom
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.shapeKey = shapeKey
        self.triggerEventType = triggerEventType
        self.condition = condition
        self.consequences = consequences
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.currentVersionId = try c.decodeIfPresent(UUID.self, forKey: .currentVersionId)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.title = try c.decode(String.self, forKey: .title)
        let rawType = try c.decodeIfPresent(String.self, forKey: .ruleType) ?? "norm"
        self.ruleType = GroupRuleType(rawValue: rawType) ?? .norm
        self.severity = try c.decodeIfPresent(Int.self, forKey: .severity) ?? 1
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "active"
        self.createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.effectiveFrom = try c.decodeIfPresent(Date.self, forKey: .effectiveFrom)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.shapeKey = try c.decodeIfPresent(String.self, forKey: .shapeKey)
        self.triggerEventType = try c.decodeIfPresent(String.self, forKey: .triggerEventType)
        self.condition = try c.decodeIfPresent(EngineRuleCondition.self, forKey: .condition)
        self.consequences = (try c.decodeIfPresent([EngineRuleConsequence].self, forKey: .consequences)) ?? []
    }
}
