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
    public let conditions: [RuleCondition]
    public let consequences: [ConsequenceEnvelope]
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

    public init(
        id: UUID,
        groupId: UUID,
        slug: String? = nil,
        name: String,
        isActive: Bool,
        trigger: RuleTrigger,
        conditions: [RuleCondition],
        consequences: [ConsequenceEnvelope],
        moduleKey: String? = nil,
        resourceId: UUID? = nil,
        seriesId: UUID? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.slug = slug
        self.name = name
        self.isActive = isActive
        self.trigger = trigger
        self.conditions = conditions
        self.consequences = consequences
        self.moduleKey = moduleKey
        self.resourceId = resourceId
        self.seriesId = seriesId
    }

    /// Computes the scope this rule lives at. More specific wins per
    /// Taxonomy §29 — callers ordering inherited rule lists should sort
    /// `resource > series > group` for display.
    public var scope: Scope {
        if resourceId != nil { return .resource }
        if seriesId   != nil { return .series   }
        return .group
    }

    public enum Scope: String, Sendable, Hashable {
        case resource, series, group
    }

    /// Loosely-typed envelope used to read `rules.consequences[].config`.
    /// Wraps the same fields the V1 fine evaluator understands so
    /// `fineShape` can classify the rule without round-tripping through
    /// `JSONConfig`.
    public struct ConsequenceEnvelope: Codable, Sendable, Hashable {
        public let type: String?
        public let config: Config?

        public init(type: String?, config: Config?) {
            self.type = type
            self.config = config
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

    /// Resolves the display amount (MXN) from the first `fine` consequence.
    /// Returns nil if the rule isn't a fine.
    public var amountMXN: Int? {
        guard let cons = consequences.first(where: { $0.type == "fine" }) else { return nil }
        if let flat = cons.config?.amount { return flat }
        if let base = cons.config?.baseAmount { return base }
        return nil
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
        case moduleKey    = "module_key"
        case resourceId   = "resource_id"
        case seriesId     = "series_id"
    }
}
