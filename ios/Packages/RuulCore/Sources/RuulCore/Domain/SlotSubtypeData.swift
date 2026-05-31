import Foundation

/// V3 Resources Deep — Fase B.5. Decodes the `subtype` jsonb returned
/// by `group_resource_detail(...)` when `resource_type='slot'`.
/// Mirrors `public.group_resource_slots` 1:1.
public struct SlotSubtypeData: Decodable, Sendable, Hashable {
    public let resourceId: UUID
    public let slotStartsAt: Date?
    public let slotEndsAt: Date?
    public let assignedMembershipId: UUID?
    public let releasedAt: Date?
    public let expiredAt: Date?
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case resourceId           = "resource_id"
        case slotStartsAt         = "slot_starts_at"
        case slotEndsAt           = "slot_ends_at"
        case assignedMembershipId = "assigned_membership_id"
        case releasedAt           = "released_at"
        case expiredAt            = "expired_at"
        case createdAt            = "created_at"
        case updatedAt            = "updated_at"
    }

    public init(
        resourceId: UUID,
        slotStartsAt: Date? = nil,
        slotEndsAt: Date? = nil,
        assignedMembershipId: UUID? = nil,
        releasedAt: Date? = nil,
        expiredAt: Date? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.resourceId = resourceId
        self.slotStartsAt = slotStartsAt
        self.slotEndsAt = slotEndsAt
        self.assignedMembershipId = assignedMembershipId
        self.releasedAt = releasedAt
        self.expiredAt = expiredAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resourceId           = try c.decode(UUID.self, forKey: .resourceId)
        self.slotStartsAt         = try c.decodeIfPresent(Date.self, forKey: .slotStartsAt)
        self.slotEndsAt           = try c.decodeIfPresent(Date.self, forKey: .slotEndsAt)
        self.assignedMembershipId = try c.decodeIfPresent(UUID.self, forKey: .assignedMembershipId)
        self.releasedAt           = try c.decodeIfPresent(Date.self, forKey: .releasedAt)
        self.expiredAt            = try c.decodeIfPresent(Date.self, forKey: .expiredAt)
        self.createdAt            = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt            = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public enum LifecycleState: Sendable, Hashable {
        case unassigned
        case assigned
        case released
        case expired
    }

    public var lifecycleState: LifecycleState {
        if expiredAt != nil { return .expired }
        if assignedMembershipId == nil {
            return releasedAt != nil ? .released : .unassigned
        }
        return .assigned
    }
}
