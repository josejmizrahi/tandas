import Foundation

/// D.22 — Search MVP. One unified result row across the 4 entity types
/// the search RPC covers in V1 (members, resources, decisions, rules).
/// Backend returns a `jsonb` array with these exact keys; iOS decodes
/// directly. UX layer derives icon + deep link from `entityType`.
public enum SearchEntityType: String, Codable, Sendable, Hashable, CaseIterable {
    case member
    case resource
    case decision
    case rule

    /// SF Symbol used by `SearchResultRowView`. Mirrors the section icons
    /// used elsewhere in the shell so search feels consistent.
    public var iconKey: String {
        switch self {
        case .member:   return "person.circle"
        case .resource: return "square.stack.3d.up"
        case .decision: return "checkmark.seal"
        case .rule:     return "list.bullet.rectangle"
        }
    }

    /// Localised section header used by `SearchView`.
    public var sectionTitle: String {
        switch self {
        case .member:   return "Miembros"
        case .resource: return "Recursos"
        case .decision: return "Decisiones"
        case .rule:     return "Reglas"
        }
    }
}

public struct SearchResult: Identifiable, Sendable, Hashable, Codable {
    public let entityType: SearchEntityType
    public let entityId: UUID
    public let groupId: UUID
    public let title: String
    public let subtitle: String?

    public var id: String { "\(entityType.rawValue):\(entityId.uuidString)" }

    public init(
        entityType: SearchEntityType,
        entityId: UUID,
        groupId: UUID,
        title: String,
        subtitle: String?
    ) {
        self.entityType = entityType
        self.entityId = entityId
        self.groupId = groupId
        self.title = title
        self.subtitle = subtitle
    }

    enum CodingKeys: String, CodingKey {
        case entityType = "entity_type"
        case entityId   = "entity_id"
        case groupId    = "group_id"
        case title
        case subtitle
    }
}
