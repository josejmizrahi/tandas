import Foundation

/// Primitiva 20 (Culture) — declarative. Mirrors
/// `public.group_cultural_norms` 1:1 via `group_cultural_norms_active(...)`.
/// Foundation slice ships propose/endorse/retire — full lifecycle.
///
/// Doctrina: ranking cualitativo via `endorsed_count` (NO scoring per
/// member, NO RLP ranking). Status flips proposed → endorsed on first
/// endorsement; retired is terminal + invisible from the active list.
public enum CulturalNormType: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case value
    case taboo
    case symbol
    case story
    case language
    case ritual
    case custom
    case aesthetic
    case principle

    public var id: String { rawValue }

    public static let displayOrder: [CulturalNormType] = [
        .value, .principle, .taboo, .custom, .ritual,
        .symbol, .story, .language, .aesthetic
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .value:     return L10n.CulturalNorms.typeValue
        case .taboo:     return L10n.CulturalNorms.typeTaboo
        case .symbol:    return L10n.CulturalNorms.typeSymbol
        case .story:     return L10n.CulturalNorms.typeStory
        case .language:  return L10n.CulturalNorms.typeLanguage
        case .ritual:    return L10n.CulturalNorms.typeRitual
        case .custom:    return L10n.CulturalNorms.typeCustom
        case .aesthetic: return L10n.CulturalNorms.typeAesthetic
        case .principle: return L10n.CulturalNorms.typePrinciple
        }
    }

    public var systemImageName: String {
        switch self {
        case .value:     return "heart.circle"
        case .taboo:     return "hand.raised"
        case .symbol:    return "sparkle"
        case .story:     return "book.closed"
        case .language:  return "character.bubble"
        case .ritual:    return "sparkles"
        case .custom:    return "leaf"
        case .aesthetic: return "paintpalette"
        case .principle: return "scale.3d"
        }
    }
}

public enum CulturalNormStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case proposed
    case endorsed
    case retired

    public var label: LocalizedStringResource {
        switch self {
        case .proposed: return L10n.CulturalNorms.statusProposed
        case .endorsed: return L10n.CulturalNorms.statusEndorsed
        case .retired:  return L10n.CulturalNorms.statusRetired
        }
    }

    public var isActive: Bool { self != .retired }
}

public enum CulturalNormVisibility: String, Codable, CaseIterable, Sendable, Hashable {
    case `private`
    case members
    case `public`

    public var label: LocalizedStringResource {
        switch self {
        case .private: return L10n.CulturalNorms.visibilityPrivate
        case .members: return L10n.CulturalNorms.visibilityMembers
        case .public:  return L10n.CulturalNorms.visibilityPublic
        }
    }
}

public struct GroupCulturalNorm: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID                           // norm_id
    public let groupId: UUID
    public let type: CulturalNormType
    public let title: String
    public let body: String?
    public let visibility: CulturalNormVisibility
    public let status: CulturalNormStatus
    public let endorsedCount: Int
    public let proposedBy: UUID?
    public let proposedByDisplayName: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id                     = "norm_id"
        case groupId                = "group_id"
        case type                   = "norm_type"
        case title
        case body
        case visibility
        case status
        case endorsedCount          = "endorsed_count"
        case proposedBy             = "proposed_by"
        case proposedByDisplayName  = "proposed_by_display_name"
        case createdAt              = "created_at"
        case updatedAt              = "updated_at"
    }

    public init(
        id: UUID,
        groupId: UUID,
        type: CulturalNormType,
        title: String,
        body: String? = nil,
        visibility: CulturalNormVisibility = .members,
        status: CulturalNormStatus = .proposed,
        endorsedCount: Int = 0,
        proposedBy: UUID? = nil,
        proposedByDisplayName: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.type = type
        self.title = title
        self.body = body
        self.visibility = visibility
        self.status = status
        self.endorsedCount = endorsedCount
        self.proposedBy = proposedBy
        self.proposedByDisplayName = proposedByDisplayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Tolerant decode: unknown type/status/visibility fall back to
    /// safe defaults so a forward-compatible backend never crashes
    /// the client.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        let rawType = try c.decode(String.self, forKey: .type)
        self.type = CulturalNormType(rawValue: rawType) ?? .value
        self.title = try c.decode(String.self, forKey: .title)
        self.body = try c.decodeIfPresent(String.self, forKey: .body)
        let rawVis = try c.decodeIfPresent(String.self, forKey: .visibility) ?? "members"
        self.visibility = CulturalNormVisibility(rawValue: rawVis) ?? .members
        let rawStatus = try c.decodeIfPresent(String.self, forKey: .status) ?? "proposed"
        self.status = CulturalNormStatus(rawValue: rawStatus) ?? .proposed
        self.endorsedCount = (try c.decodeIfPresent(Int.self, forKey: .endorsedCount)) ?? 0
        self.proposedBy = try c.decodeIfPresent(UUID.self, forKey: .proposedBy)
        self.proposedByDisplayName = try c.decodeIfPresent(String.self, forKey: .proposedByDisplayName)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

public extension GroupCulturalNorm {
    var isEndorsed: Bool { status == .endorsed }
    var isProposed: Bool { status == .proposed }
}
