import Foundation

/// Primitiva 5 (Resources / Property). Mirrors the envelope
/// `public.group_resources` row plus the projection returned by
/// `group_resource_detail(...)` (which denormalizes `unit`, `metadata`,
/// `series_id`, `archived_at`, `ownership_metadata` and the per-type
/// `subtype` jsonb).
///
/// All per-type rendering metadata (icon, subtitle, supported
/// coordination sub-blocks, valuation/custody/booking/assignment
/// switches, lifecycle whitelist, editable metadata schema) lives in
/// `ResourceTypeRegistry` / `ResourceTypeDescriptor`. Views, stores
/// and tests should resolve those via the registry instead of branching
/// on the raw enum.
public enum GroupResourceType: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case event
    case fund
    case slot
    case space
    case asset
    case right
    case money
    case time
    case points
    case document
    case data
    case access
    case other
    case vehicle
    case tool
    case inventory
    case realEstate           = "real_estate"
    case intellectualProperty = "intellectual_property"

    public var id: String { rawValue }

    /// Routing helper — pulls the descriptor from the registry.
    public var descriptor: ResourceTypeDescriptor {
        ResourceTypeRegistry.descriptor(for: self)
    }

    public var label: LocalizedStringResource    { descriptor.label }
    public var systemImageName: String           { descriptor.icon }
    public var subtitle: LocalizedStringResource { descriptor.subtitle }

    /// Canonical picker / grouped-list order, owned by the registry so
    /// the source of truth stays in one place.
    public static var displayOrder: [GroupResourceType] {
        ResourceTypeRegistry.displayOrder
    }
}

public enum ResourceVisibility: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case `private`
    case members
    case `public`

    public var id: String { rawValue }

    public var label: LocalizedStringResource {
        switch self {
        case .private: return L10n.Resources.privateLabel
        case .members: return L10n.Resources.membersLabel
        case .public:  return L10n.Resources.publicLabel
        }
    }
}

/// Wire tokens are `group | individual | shared | custodial | external`
/// (see `group_resources_ownership_kind_check`). `.member` is the
/// iOS-facing alias for `individual` so the UI reads naturally; the
/// other four match the wire 1:1.
public enum ResourceOwnershipKind: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case group
    case member     = "individual"
    case shared
    case custodial
    case external

    public var id: String { rawValue }

    public var label: LocalizedStringResource {
        switch self {
        case .group:     return L10n.Resources.groupOwnedLabel
        case .member:    return L10n.Resources.memberOwnedLabel
        case .shared:    return L10n.Resources.sharedOwnedLabel
        case .custodial: return L10n.Resources.custodialOwnedLabel
        case .external:  return L10n.Resources.externalOwnedLabel
        }
    }
}

public struct GroupResource: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let resourceType: GroupResourceType
    public let name: String
    public let description: String?
    public let status: String
    public let visibility: ResourceVisibility
    public let ownershipKind: ResourceOwnershipKind
    public let ownerMembershipId: UUID?
    public let ownershipMetadata: [String: RPCJSONValue]?
    public let unit: String?
    public let metadata: [String: RPCJSONValue]?
    public let seriesId: UUID?
    public let createdBy: UUID?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let archivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id                = "resource_id"
        case groupId           = "group_id"
        case resourceType      = "resource_type"
        case name
        case description
        case status
        case visibility
        case ownershipKind     = "ownership_kind"
        case ownerMembershipId = "owner_membership_id"
        case ownershipMetadata = "ownership_metadata"
        case unit
        case metadata
        case seriesId          = "series_id"
        case createdBy         = "created_by"
        case createdAt         = "created_at"
        case updatedAt         = "updated_at"
        case archivedAt        = "archived_at"
    }

    public init(
        id: UUID,
        groupId: UUID,
        resourceType: GroupResourceType,
        name: String,
        description: String? = nil,
        status: String = "active",
        visibility: ResourceVisibility = .members,
        ownershipKind: ResourceOwnershipKind = .group,
        ownerMembershipId: UUID? = nil,
        ownershipMetadata: [String: RPCJSONValue]? = nil,
        unit: String? = nil,
        metadata: [String: RPCJSONValue]? = nil,
        seriesId: UUID? = nil,
        createdBy: UUID? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.resourceType = resourceType
        self.name = name
        self.description = description
        self.status = status
        self.visibility = visibility
        self.ownershipKind = ownershipKind
        self.ownerMembershipId = ownerMembershipId
        self.ownershipMetadata = ownershipMetadata
        self.unit = unit
        self.metadata = metadata
        self.seriesId = seriesId
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `group_resources_active` returns 'resource_id'; the raw
        // `group_resources` row (and `group_resource_detail`) returns
        // 'id'. Accept both.
        if let v = try c.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = v
        } else {
            let alt = try decoder.container(keyedBy: AltKeys.self)
            self.id = try alt.decode(UUID.self, forKey: .idAlt)
        }
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        let rawType = try c.decode(String.self, forKey: .resourceType)
        self.resourceType = GroupResourceType(rawValue: rawType) ?? .other
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.status = try c.decode(String.self, forKey: .status)
        let rawVis = try c.decode(String.self, forKey: .visibility)
        self.visibility = ResourceVisibility(rawValue: rawVis) ?? .members
        let rawOwn = try c.decode(String.self, forKey: .ownershipKind)
        self.ownershipKind = ResourceOwnershipKind(rawValue: rawOwn) ?? .group
        self.ownerMembershipId  = try c.decodeIfPresent(UUID.self, forKey: .ownerMembershipId)
        self.ownershipMetadata  = try c.decodeIfPresent([String: RPCJSONValue].self, forKey: .ownershipMetadata)
        self.unit               = try c.decodeIfPresent(String.self, forKey: .unit)
        self.metadata           = try c.decodeIfPresent([String: RPCJSONValue].self, forKey: .metadata)
        self.seriesId           = try c.decodeIfPresent(UUID.self, forKey: .seriesId)
        self.createdBy          = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.createdAt          = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt          = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.archivedAt         = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
    }

    private enum AltKeys: String, CodingKey { case idAlt = "id" }
}

public extension GroupResource {
    /// Compact subtitle for list rows: type · ownership. Per-type
    /// renderers may prepend a hint pulled from the descriptor metadata
    /// schema (e.g. condition, balance) — see `descriptorHint(in:)`.
    var subtitle: String {
        let parts: [String] = [String(localized: resourceType.label),
                               String(localized: ownershipKind.label)]
        return parts.joined(separator: " · ")
    }

    /// Trimmed body preview.
    var previewText: String {
        (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Best-effort leaf reader for the metadata jsonb. Returns nil for
    /// missing / null / blank values. Numbers render with their natural
    /// `String` form, bools as Sí/No; objects + arrays fall back to a
    /// JSON snippet so the surface can still show something. Used by
    /// the descriptor-driven row + detail renderers.
    func metadataString(forKey key: String) -> String? {
        guard let raw = metadata?[key] else { return nil }
        switch raw {
        case .string(let s): return s.isEmpty ? nil : s
        case .number(let n): return NSDecimalNumber(decimal: n).stringValue
        case .bool(let b):   return b ? "Sí" : "No"
        case .null:          return nil
        case .array, .object:
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(raw),
               let s = String(data: data, encoding: .utf8) { return s }
            return nil
        }
    }
}
