import Foundation

/// A platform rule with WHEN / IF / THEN shape:
///   trigger     → which SystemEventType makes the engine consider this rule
///   conditions  → all must match (logical AND)
///   consequences → all execute when conditions match
///
/// Persisted in `public.rules`. The legacy columns (`code`, `title`,
/// `trigger`, `action`, `enabled`, `status`) are kept for backwards compat
/// and dropped in a posterior sprint after migration paridad.
///
/// `slug` is the stable cross-group identifier inherited from the
/// originating template rule (e.g. `dinner_late_arrival`). It survives
/// rename of `name` (display copy) and i18n. Modules reference rules
/// by slug in `GroupModule.providedRules`. Per-group user-authored rules
/// have `slug = nil`.
///
/// Three-level scope (mig 00071):
///   - `moduleKey == nil && resourceId == nil` → group-level / template-seeded
///   - `moduleKey != nil && resourceId == nil` → seeded by module activation;
///     lifecycle bound to `set_group_module(slug, true/false)`
///   - `resourceId != nil` → per-instance override (may also carry moduleKey)
public struct Rule: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public let groupId: UUID
    public var slug: String?
    public var name: String
    public var isActive: Bool
    public var trigger: RuleTrigger
    public var conditions: [RuleCondition]
    public var consequences: [RuleConsequence]
    public var moduleKey: String?
    public var resourceId: UUID?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        groupId: UUID,
        slug: String? = nil,
        name: String,
        isActive: Bool,
        trigger: RuleTrigger,
        conditions: [RuleCondition],
        consequences: [RuleConsequence],
        moduleKey: String? = nil,
        resourceId: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

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
        case createdAt    = "created_at"
        case updatedAt    = "updated_at"
    }
}
