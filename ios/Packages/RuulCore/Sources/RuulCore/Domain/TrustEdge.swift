import Foundation

/// R.3A — Tipo de confianza declarada.
public enum TrustType: String, Codable, Sendable, CaseIterable {
    case personal
    case professional
    case financial
    case governance
    case advisory

    public var label: String {
        switch self {
        case .personal:     return "Personal"
        case .professional: return "Profesional"
        case .financial:    return "Financiera"
        case .governance:   return "Gobernanza"
        case .advisory:     return "Asesoría"
        }
    }
}

/// R.3A — Un edge OUTGOING de `trust_edges` (caller → target).
public struct TrustEdgeOutgoing: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let targetActorId: UUID
    public let targetDisplayName: String?
    public let trustLevel: Int
    public let trustType: TrustType
    public let notes: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case targetActorId      = "target_actor_id"
        case targetDisplayName  = "target_display_name"
        case trustLevel         = "trust_level"
        case trustType          = "trust_type"
        case notes
        case createdAt          = "created_at"
        case updatedAt          = "updated_at"
    }

    public init(
        id: UUID,
        targetActorId: UUID,
        targetDisplayName: String? = nil,
        trustLevel: Int,
        trustType: TrustType,
        notes: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.targetActorId = targetActorId
        self.targetDisplayName = targetDisplayName
        self.trustLevel = trustLevel
        self.trustType = trustType
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// R.3A — Un edge INCOMING de `trust_edges` (source → caller).
public struct TrustEdgeIncoming: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceActorId: UUID
    public let sourceDisplayName: String?
    public let trustLevel: Int
    public let trustType: TrustType
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case sourceActorId      = "source_actor_id"
        case sourceDisplayName  = "source_display_name"
        case trustLevel         = "trust_level"
        case trustType          = "trust_type"
        case createdAt          = "created_at"
    }

    public init(
        id: UUID,
        sourceActorId: UUID,
        sourceDisplayName: String? = nil,
        trustLevel: Int,
        trustType: TrustType,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.sourceActorId = sourceActorId
        self.sourceDisplayName = sourceDisplayName
        self.trustLevel = trustLevel
        self.trustType = trustType
        self.createdAt = createdAt
    }
}

/// R.3A — Respuesta de `list_trust_network(p_actor_id?)`.
public struct TrustNetwork: Sendable, Equatable {
    public let actorId: UUID
    public let outgoing: [TrustEdgeOutgoing]
    public let incoming: [TrustEdgeIncoming]

    public init(actorId: UUID, outgoing: [TrustEdgeOutgoing], incoming: [TrustEdgeIncoming]) {
        self.actorId = actorId
        self.outgoing = outgoing
        self.incoming = incoming
    }
}

extension TrustNetwork: Decodable {
    enum CodingKeys: String, CodingKey {
        case actorId = "actor_id"
        case outgoing
        case incoming
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.actorId = try c.decode(UUID.self, forKey: .actorId)
        self.outgoing = try c.decodeIfPresent([TrustEdgeOutgoing].self, forKey: .outgoing) ?? []
        self.incoming = try c.decodeIfPresent([TrustEdgeIncoming].self, forKey: .incoming) ?? []
    }
}
