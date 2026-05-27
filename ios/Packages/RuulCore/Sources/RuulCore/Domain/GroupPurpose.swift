import Foundation

/// Primitiva 3: el grupo declara qué es. Mirrors `public.group_purposes`
/// 1:1. Backed by `group_purposes_active(...)` for reads and
/// `set_group_purpose(...)` for upserts (no version history exposed
/// in Foundation).
public enum GroupPurposeKind: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case declared
    case operative
    case emotional

    public var id: String { rawValue }

    /// Fixed render order. Use this to traverse `GroupPurposeKind.allCases`
    /// in the UI so the three kinds always sit in the same column.
    public static let displayOrder: [GroupPurposeKind] = [.declared, .operative, .emotional]

    public var label: LocalizedStringResource {
        switch self {
        case .declared:  return L10n.Purpose.declaredLabel
        case .operative: return L10n.Purpose.operativeLabel
        case .emotional: return L10n.Purpose.emotionalLabel
        }
    }

    public var subtitle: LocalizedStringResource {
        switch self {
        case .declared:  return L10n.Purpose.declaredSubtitle
        case .operative: return L10n.Purpose.operativeSubtitle
        case .emotional: return L10n.Purpose.emotionalSubtitle
        }
    }

    public var systemImageName: String {
        switch self {
        case .declared:  return "flag"
        case .operative: return "gearshape"
        case .emotional: return "heart"
        }
    }
}

public enum PurposeVisibility: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case `private`
    case members
    case `public`

    public var id: String { rawValue }

    public var label: LocalizedStringResource {
        switch self {
        case .private: return LocalizedStringResource("purpose.visibility.private", defaultValue: "Privado")
        case .members: return LocalizedStringResource("purpose.visibility.members", defaultValue: "Miembros")
        case .public:  return LocalizedStringResource("purpose.visibility.public",  defaultValue: "Público")
        }
    }
}

public struct GroupPurpose: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID                            // purpose_id
    public let groupId: UUID
    public let kind: GroupPurposeKind
    public let body: String
    public let visibility: PurposeVisibility
    public let status: String
    public let createdBy: UUID?
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id         = "purpose_id"
        case groupId    = "group_id"
        case kind
        case body
        case visibility
        case status
        case createdBy  = "created_by"
        case createdAt  = "created_at"
        case updatedAt  = "updated_at"
    }

    public init(
        id: UUID,
        groupId: UUID,
        kind: GroupPurposeKind,
        body: String,
        visibility: PurposeVisibility = .members,
        status: String = "active",
        createdBy: UUID? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.kind = kind
        self.body = body
        self.visibility = visibility
        self.status = status
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Tolerant decode: unknown enum values fall back to safe defaults
    /// so a forward-compatible backend row never crashes the client.
    /// The RPC `set_group_purpose` already returns a clean public.group_purposes
    /// row; either codepath uses this initializer.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The set RPC returns the row with `id` (not `purpose_id`).
        // Accept either key so callers can decode both shapes.
        if let v = try c.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = v
        } else {
            // Fallback path: try the alt key by re-decoding via a dynamic
            // container. Should not happen with current backend.
            let alt = try decoder.container(keyedBy: AltKeys.self)
            self.id = try alt.decode(UUID.self, forKey: .idAlt)
        }
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        let rawKind = try c.decode(String.self, forKey: .kind)
        self.kind = GroupPurposeKind(rawValue: rawKind) ?? .declared
        self.body = try c.decode(String.self, forKey: .body)
        let rawVis = try c.decode(String.self, forKey: .visibility)
        self.visibility = PurposeVisibility(rawValue: rawVis) ?? .members
        self.status = try c.decode(String.self, forKey: .status)
        self.createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    private enum AltKeys: String, CodingKey { case idAlt = "id" }
}

public extension GroupPurpose {
    var trimmedBody: String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
