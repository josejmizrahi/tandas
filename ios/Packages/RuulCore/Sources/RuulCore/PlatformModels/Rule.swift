import Foundation

/// A platform rule with WHEN / IF / THEN shape:
///   trigger     → which SystemEventType makes the engine consider this rule
///   conditions  → tree of leaves combined with AND/OR/NOT (§22.4).
///                 A flat list is `.and(leaves)`, the legacy semantics.
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
/// Five-axis scope (mig 00071 + 00078). Resolution precedence — most specific
/// wins when more than one matches the same trigger:
///
///   membership > resource (occurrence) > series > module > group/default
///
///   - `moduleKey == nil && resourceId == nil && seriesId == nil && membershipId == nil`
///     → group-level / template-seeded
///   - `moduleKey != nil` (others nil) → seeded by module activation; lifecycle
///     bound to `set_group_module(slug, true/false)`
///   - `seriesId != nil` → applies to every occurrence of a ResourceSeries
///     unless overridden at occurrence level
///   - `resourceId != nil` → per-instance override (occurrences ARE resources
///     per taxonomy §1.4; may carry moduleKey too)
///   - `membershipId != nil` → per-member deviation; orthogonal axis that may
///     coexist with any of the above
public struct Rule: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public let groupId: UUID
    public var slug: String?
    public var name: String
    public var isActive: Bool
    public var trigger: RuleTrigger
    public var conditions: ConditionNode
    public var consequences: [RuleConsequence]
    public var moduleKey: String?
    public var resourceId: UUID?
    public var seriesId: UUID?
    public var membershipId: UUID?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        groupId: UUID,
        slug: String? = nil,
        name: String,
        isActive: Bool,
        trigger: RuleTrigger,
        conditions: ConditionNode,
        consequences: [RuleConsequence],
        moduleKey: String? = nil,
        resourceId: UUID? = nil,
        seriesId: UUID? = nil,
        membershipId: UUID? = nil,
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
        self.seriesId = seriesId
        self.membershipId = membershipId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Convenience init that accepts a flat leaf list (legacy callers).
    /// Wraps the list as `.and(leaves)` — same semantics as before §22.4.
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
        seriesId: UUID? = nil,
        membershipId: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.init(
            id: id, groupId: groupId, slug: slug, name: name,
            isActive: isActive, trigger: trigger,
            conditions: ConditionNode(leaves: conditions),
            consequences: consequences,
            moduleKey: moduleKey, resourceId: resourceId,
            seriesId: seriesId, membershipId: membershipId,
            createdAt: createdAt, updatedAt: updatedAt
        )
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
        case seriesId     = "series_id"
        case membershipId = "membership_id"
        case createdAt    = "created_at"
        case updatedAt    = "updated_at"
    }
}
