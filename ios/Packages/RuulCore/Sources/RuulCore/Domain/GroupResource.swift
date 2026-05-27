import Foundation

/// Primitiva 5: las cosas que el grupo tiene. Mirrors the envelope
/// `public.group_resources` row returned by
/// `group_resources_active(...)`. Subtype tables (fund/space/asset
/// specifics, bookings, transactions) are intentionally invisible at
/// the Foundation surface.
public enum GroupResourceType: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case fund
    case space
    case asset
    case document
    case other

    public var id: String { rawValue }

    public static let displayOrder: [GroupResourceType] = [
        .fund, .space, .asset, .document, .other
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .fund:     return L10n.Resources.fundLabel
        case .space:    return L10n.Resources.spaceLabel
        case .asset:    return L10n.Resources.assetLabel
        case .document: return L10n.Resources.documentLabel
        case .other:    return L10n.Resources.otherLabel
        }
    }

    public var systemImageName: String {
        switch self {
        case .fund:     return "banknote"
        case .space:    return "house"
        case .asset:    return "shippingbox"
        case .document: return "doc.text"
        case .other:    return "square.stack.3d.up"
        }
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

/// Wire tokens use `individual` for member-owned; `.member` is the
/// iOS-facing alias so the UI reads naturally. `rawValue` is what
/// the backend wants on the wire.
public enum ResourceOwnershipKind: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case group
    case member     = "individual"
    case external

    public var id: String { rawValue }

    public var label: LocalizedStringResource {
        switch self {
        case .group:    return L10n.Resources.groupOwnedLabel
        case .member:   return L10n.Resources.memberOwnedLabel
        case .external: return L10n.Resources.externalOwnedLabel
        }
    }
}

public struct GroupResource: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID                            // resource_id
    public let groupId: UUID
    public let resourceType: GroupResourceType
    public let name: String
    public let description: String?
    public let status: String
    public let visibility: ResourceVisibility
    public let ownershipKind: ResourceOwnershipKind
    public let ownerMembershipId: UUID?
    public let custodianMembershipId: UUID?
    public let createdBy: UUID?
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id                     = "resource_id"
        case groupId                = "group_id"
        case resourceType           = "resource_type"
        case name
        case description
        case status
        case visibility
        case ownershipKind          = "ownership_kind"
        case ownerMembershipId      = "owner_membership_id"
        case custodianMembershipId  = "custodian_membership_id"
        case createdBy              = "created_by"
        case createdAt              = "created_at"
        case updatedAt              = "updated_at"
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
        custodianMembershipId: UUID? = nil,
        createdBy: UUID? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
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
        self.custodianMembershipId = custodianMembershipId
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // group_resources_active returns 'resource_id'; the create RPC
        // returns the raw public.group_resources row with 'id'. Accept both.
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
        self.ownerMembershipId = try c.decodeIfPresent(UUID.self, forKey: .ownerMembershipId)
        self.custodianMembershipId = try c.decodeIfPresent(UUID.self, forKey: .custodianMembershipId)
        self.createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    private enum AltKeys: String, CodingKey { case idAlt = "id" }
}

public extension GroupResource {
    /// Compact subtitle for list rows: type + ownership.
    var subtitle: String {
        let parts: [String] = [String(localized: resourceType.label),
                               String(localized: ownershipKind.label)]
        return parts.joined(separator: " · ")
    }

    /// Trimmed body preview.
    var previewText: String {
        (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
