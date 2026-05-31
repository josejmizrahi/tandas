import Foundation

/// V3 Resources Deep — Fase B.3. Decodes the `subtype` jsonb returned
/// by `group_resource_detail(...)` when `resource_type='space'`.
/// Mirrors `public.group_resource_spaces` 1:1.
public struct SpaceSubtypeData: Decodable, Sendable, Hashable {
    public let resourceId: UUID
    public let address: String?
    public let capacity: Int?
    public let rules: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case resourceId = "resource_id"
        case address
        case capacity
        case rules
        case createdAt  = "created_at"
        case updatedAt  = "updated_at"
    }

    public init(
        resourceId: UUID,
        address: String? = nil,
        capacity: Int? = nil,
        rules: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.resourceId = resourceId
        self.address = address
        self.capacity = capacity
        self.rules = rules
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resourceId = try c.decode(UUID.self, forKey: .resourceId)
        self.address    = try c.decodeIfPresent(String.self, forKey: .address)
        self.capacity   = try c.decodeIfPresent(Int.self, forKey: .capacity)
        self.rules      = try c.decodeIfPresent(String.self, forKey: .rules)
        self.createdAt  = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt  = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}
