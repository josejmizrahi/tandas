import Foundation

/// Typed view of `public.resources WHERE resource_type='space'` (mig 00203).
///
/// `Space` is a `Resource` conformer that surfaces the metadata jsonb
/// fields as typed properties. The wire row is a `ResourceRow` envelope;
/// `Space` is the decoded projection.
///
/// Doctrine: there is no `spaces` table — space lives polymorphically
/// in `resources.metadata`. This struct exists for ergonomics, not
/// schema parallelism.
public struct Space: Resource, Codable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let name: String
    public let capacity: Int?
    public let locationName: String?
    public let locationLat: Double?
    public let locationLng: Double?
    public let description: String?
    public let status: String
    public let createdBy: UUID?
    public let createdAt: Date
    public let updatedAt: Date
    public let archivedAt: Date?

    public var resourceType: ResourceType { .space }
    public var resourceStatus: String { status }
    public var isArchived: Bool { archivedAt != nil }

    public init(
        id: UUID,
        groupId: UUID,
        name: String,
        capacity: Int? = nil,
        locationName: String? = nil,
        locationLat: Double? = nil,
        locationLng: Double? = nil,
        description: String? = nil,
        status: String = "active",
        createdBy: UUID? = nil,
        createdAt: Date,
        updatedAt: Date,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.name = name
        self.capacity = capacity
        self.locationName = locationName
        self.locationLat = locationLat
        self.locationLng = locationLng
        self.description = description
        self.status = status
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }
}

public extension ResourceRow {
    /// Decodes a `ResourceRow` with `resource_type == .space` into a typed
    /// `Space`. Mirrors `decodeAsEvent()` — throws on type mismatch or
    /// missing required metadata.
    func decodeAsSpace() throws -> Space {
        guard resourceType == .space else {
            throw ResourceRowError.typeMismatch(expected: .space, got: resourceType)
        }
        guard let name = metadata["name"]?.stringValue, !name.isEmpty else {
            throw ResourceRowError.missingMetadataKey("name")
        }

        let capacity = metadata["capacity"]?.intValue
        let locationName = metadata["location_name"]?.stringValue
        let locationLat = metadata["location_lat"].flatMap { v -> Double? in
            if case .double(let d) = v { return d }
            if case .int(let i) = v { return Double(i) }
            return nil
        }
        let locationLng = metadata["location_lng"].flatMap { v -> Double? in
            if case .double(let d) = v { return d }
            if case .int(let i) = v { return Double(i) }
            return nil
        }
        let description = metadata["description"]?.stringValue

        return Space(
            id: id,
            groupId: groupId,
            name: name,
            capacity: capacity,
            locationName: locationName,
            locationLat: locationLat,
            locationLng: locationLng,
            description: description,
            status: status,
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            archivedAt: archivedAt
        )
    }
}
