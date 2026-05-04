import Foundation

/// A platform rule with WHEN / IF / THEN shape:
///   trigger     → which SystemEventType makes the engine consider this rule
///   conditions  → all must match (logical AND)
///   consequences → all execute when conditions match
///
/// Persisted in `public.rules`. The legacy columns (`code`, `title`,
/// `trigger`, `action`, `enabled`, `status`) are kept for backwards compat
/// and dropped in a posterior sprint after migration paridad.
public struct Rule: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public let groupId: UUID
    public var name: String
    public var isActive: Bool
    public var trigger: RuleTrigger
    public var conditions: [RuleCondition]
    public var consequences: [RuleConsequence]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        groupId: UUID,
        name: String,
        isActive: Bool,
        trigger: RuleTrigger,
        conditions: [RuleCondition],
        consequences: [RuleConsequence],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.groupId = groupId
        self.name = name
        self.isActive = isActive
        self.trigger = trigger
        self.conditions = conditions
        self.consequences = consequences
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case groupId      = "group_id"
        case name
        case isActive     = "is_active"
        case trigger
        case conditions
        case consequences
        case createdAt    = "created_at"
        case updatedAt    = "updated_at"
    }
}
