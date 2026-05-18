import Foundation

/// Read-only view of a rule for display in `RulesView`. Decodes the platform
/// columns (`name`, `is_active`, `slug`, `trigger`, `conditions`,
/// `consequences`). Slice E.2 dropped the legacy columns
/// (`title`/`code`/`description`/`enabled`/`action`); platform fields are
/// the only persisted shape now.
public struct GroupRule: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let slug: String?
    public let name: String
    public let isActive: Bool
    public let trigger: RuleTrigger
    /// Flat pre-order list of every condition leaf in the rule. Pre-§22.4
    /// rules persisted a JSON array; §22.4 (mig 00251) lets the column
    /// also hold a `{op,children}` AND/OR/NOT tree. For back-compat
    /// every consumer that doesn't care about the structure (capability
    /// checks, param extraction, summary renders) keeps reading this
    /// flat view — the decoder unwraps trees into their leaves here. The
    /// full structure (when non-trivial) lives in `conditionsTree`.
    public let conditions: [RuleCondition]
    public let consequences: [ConsequenceEnvelope]
    /// AND/OR/NOT tree of the rule's conditions, when the wire shape is
    /// a tree (§22.4 / mig 00251). Nil when the wire shape is a flat
    /// array — in that case `conditions` IS the full picture (implicit
    /// AND of leaves). When non-nil, this is the source of truth; the
    /// flat `conditions` is a derived view of the leaves.
    public let conditionsTree: ConditionNode?
    /// Condition-shaped predicates that BLOCK consequences when ANY
    /// evaluates true (mig 00248, §22.2 Governance.md). Decoded from
    /// `rules.exceptions` jsonb column. Defaults to empty for rules
    /// published before exceptions landed.
    public let exceptions: [RuleCondition]
    /// Module that owns this rule. Set when seeded via module activation
    /// (mig 00073 `seed_module_rules`). Null = group-level rule with no
    /// module affinity.
    public let moduleKey: String?
    /// Resource instance this rule overrides, if any. Null for module-
    /// or group-scoped rules. Mig 00071.
    public let resourceId: UUID?
    /// ResourceSeries this rule overrides, if any. Set when the rule
    /// applies to every occurrence of a recurring resource (e.g. all
    /// future dinners). Mig 00078.
    public let seriesId: UUID?
    /// Member this rule deviates for, if any. Orthogonal axis — may
    /// coexist with any other scope (e.g. "this member has 2x grace
    /// period on every dinner"). Mig 00078.
    public let membershipId: UUID?

    public init(
        id: UUID,
        groupId: UUID,
        slug: String? = nil,
        name: String,
        isActive: Bool,
        trigger: RuleTrigger,
        conditions: [RuleCondition],
        consequences: [ConsequenceEnvelope],
        exceptions: [RuleCondition] = [],
        conditionsTree: ConditionNode? = nil,
        moduleKey: String? = nil,
        resourceId: UUID? = nil,
        seriesId: UUID? = nil,
        membershipId: UUID? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.slug = slug
        self.name = name
        self.isActive = isActive
        self.trigger = trigger
        self.conditions = conditions
        self.consequences = consequences
        self.exceptions = exceptions
        self.conditionsTree = conditionsTree
        self.moduleKey = moduleKey
        self.resourceId = resourceId
        self.seriesId = seriesId
        self.membershipId = membershipId
    }

    /// Computes the scope label this rule lives at, picking the most
    /// specific axis when more than one is set. Precedence per Taxonomy
    /// §29: membership > resource (occurrence) > series > module > group.
    public var scope: Scope {
        if membershipId != nil { return .membership }
        if resourceId   != nil { return .resource }
        if seriesId     != nil { return .series   }
        if moduleKey    != nil { return .module   }
        return .group
    }

    public enum Scope: String, Sendable, Hashable {
        case membership, resource, series, module, group
    }

    /// Loosely-typed envelope used to read `rules.consequences[].config`.
    /// Wraps the same fields the V1 fine evaluator understands so
    /// `fineShape` can classify the rule without round-tripping through
    /// `JSONConfig`.
    public struct ConsequenceEnvelope: Codable, Sendable, Hashable {
        public let type: String?
        public let config: Config?
        /// Optional target selector (§22.3 / mig 00249). Re-routes
        /// the consequence to a member different from the trigger's
        /// actor. nil / "$trigger.actor" → default behavior.
        public let target: String?

        public init(type: String?, config: Config?, target: String? = nil) {
            self.type = type
            self.config = config
            self.target = target
        }

        public enum CodingKeys: String, CodingKey {
            case type, config, target
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.type   = try c.decodeIfPresent(String.self, forKey: .type)
            self.config = try c.decodeIfPresent(Config.self, forKey: .config)
            self.target = try c.decodeIfPresent(String.self, forKey: .target)
        }

        public struct Config: Codable, Sendable, Hashable {
            public let amount: Int?
            public let baseAmount: Int?
            public let stepAmount: Int?
            public let stepMinutes: Int?

            public init(amount: Int?, baseAmount: Int?, stepAmount: Int?, stepMinutes: Int?) {
                self.amount = amount
                self.baseAmount = baseAmount
                self.stepAmount = stepAmount
                self.stepMinutes = stepMinutes
            }
        }
    }

    /// True when the rule is active. Slice E.1 collapsed the previous
    /// `enabled && isActive` AND once both columns stayed in lockstep;
    /// E.2 dropped `enabled` entirely so `isActive` is the lone signal.
    public var isLive: Bool { isActive }

    public enum CodingKeys: String, CodingKey {
        case id
        case groupId      = "group_id"
        case slug
        case name
        case isActive     = "is_active"
        case trigger
        case conditions
        case consequences
        case exceptions
        case moduleKey    = "module_key"
        case resourceId   = "resource_id"
        case seriesId     = "series_id"
        case membershipId = "membership_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id            = try c.decode(UUID.self, forKey: .id)
        self.groupId       = try c.decode(UUID.self, forKey: .groupId)
        self.slug          = try c.decodeIfPresent(String.self, forKey: .slug)
        self.name          = try c.decode(String.self, forKey: .name)
        self.isActive      = try c.decode(Bool.self, forKey: .isActive)
        self.trigger       = try c.decode(RuleTrigger.self, forKey: .trigger)
        // §22.4 (mig 00251): the wire shape under `conditions` is now
        // EITHER a flat array (legacy implicit AND) OR a `{op,children}`
        // AND/OR/NOT tree. Decode through `ConditionNode` so both shapes
        // work; collapse to `allLeaves` for the back-compat flat view.
        let tree           = try c.decode(ConditionNode.self, forKey: .conditions)
        self.conditions    = tree.allLeaves
        // Preserve the tree only when it carries structure richer than
        // the legacy AND-of-leaves (which `flatLeaves != nil` detects).
        // Nil for legacy rows means callers can keep ignoring the field.
        self.conditionsTree = (tree.flatLeaves == nil) ? tree : nil
        self.consequences  = try c.decode([ConsequenceEnvelope].self, forKey: .consequences)
        // Pre-00248 rows don't have an `exceptions` column; defensively
        // decode as missing-or-non-array → empty.
        self.exceptions    = (try? c.decodeIfPresent([RuleCondition].self, forKey: .exceptions)) ?? []
        self.moduleKey     = try c.decodeIfPresent(String.self, forKey: .moduleKey)
        self.resourceId    = try c.decodeIfPresent(UUID.self, forKey: .resourceId)
        self.seriesId      = try c.decodeIfPresent(UUID.self, forKey: .seriesId)
        self.membershipId  = try c.decodeIfPresent(UUID.self, forKey: .membershipId)
    }

    /// Custom encoder so the §22.4 tree, when present, round-trips back
    /// to the wire as `{op,children}` instead of the lossy flat list of
    /// leaves. Pre-§22.4 rows (no `conditionsTree`) encode the flat
    /// array exactly as before.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(groupId, forKey: .groupId)
        try c.encodeIfPresent(slug, forKey: .slug)
        try c.encode(name, forKey: .name)
        try c.encode(isActive, forKey: .isActive)
        try c.encode(trigger, forKey: .trigger)
        if let tree = conditionsTree {
            try c.encode(tree, forKey: .conditions)
        } else {
            try c.encode(conditions, forKey: .conditions)
        }
        try c.encode(consequences, forKey: .consequences)
        try c.encode(exceptions, forKey: .exceptions)
        try c.encodeIfPresent(moduleKey, forKey: .moduleKey)
        try c.encodeIfPresent(resourceId, forKey: .resourceId)
        try c.encodeIfPresent(seriesId, forKey: .seriesId)
        try c.encodeIfPresent(membershipId, forKey: .membershipId)
    }
}
