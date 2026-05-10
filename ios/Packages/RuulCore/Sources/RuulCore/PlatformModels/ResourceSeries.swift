import Foundation

/// Recurrence container per OpenPlatform Taxonomy §1.3.
///
/// Holds the pattern (frequency, dayOfWeek, startTime, …) that drives
/// occurrence generation. Generated occurrences live in `public.resources`
/// with `series_id` pointing back to the series row.
///
/// Schema source: mig 00078. Decodes from `public.resource_series`.
public struct ResourceSeries: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let resourceType: String
    public let pattern: JSONConfig
    public let metadata: JSONConfig
    public let active: Bool
    public let createdBy: UUID?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        groupId: UUID,
        resourceType: String,
        pattern: JSONConfig = .object([:]),
        metadata: JSONConfig = .object([:]),
        active: Bool = true,
        createdBy: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.groupId = groupId
        self.resourceType = resourceType
        self.pattern = pattern
        self.metadata = metadata
        self.active = active
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case groupId      = "group_id"
        case resourceType = "resource_type"
        case pattern
        case metadata
        case active
        case createdBy    = "created_by"
        case createdAt    = "created_at"
        case updatedAt    = "updated_at"
    }
}
