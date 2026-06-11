import Foundation

/// R.5 — Política de gobierno asociada a un context_actor. Doctrina: el valor
/// es `JSONValue` arbitrario (el backend define la forma por policy_key), pero
/// el frontend sólo presenta — no interpreta business logic ni hace switch
/// por policy_key.
///
/// Nota shape: `list_governance_policies` devuelve sólo `policy_key`,
/// `policy_value`, `updated_at`. `id` y `contextActorId` se exponen como
/// opcionales para soportar shapes futuros (RPC de detalle/creación).
public struct GovernancePolicy: Decodable, Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let contextActorId: UUID?
    public let policyKey: String
    public let policyValue: JSONValue
    public let createdByActorId: UUID?
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case contextActorId = "context_actor_id"
        case policyKey = "policy_key"
        case policyValue = "policy_value"
        case createdByActorId = "created_by_actor_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Si el RPC no devuelve id, generamos uno local estable basado en
        // policy_key para satisfacer Identifiable (no colisiona entre keys).
        let decodedId = try c.decodeIfPresent(UUID.self, forKey: .id)
        self.policyKey = try c.decode(String.self, forKey: .policyKey)
        self.id = decodedId ?? GovernancePolicy.derivedId(for: policyKey)
        self.contextActorId = try c.decodeIfPresent(UUID.self, forKey: .contextActorId)
        self.policyValue = try c.decode(JSONValue.self, forKey: .policyValue)
        self.createdByActorId = try c.decodeIfPresent(UUID.self, forKey: .createdByActorId)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public init(
        id: UUID,
        contextActorId: UUID? = nil,
        policyKey: String,
        policyValue: JSONValue,
        createdByActorId: UUID? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.contextActorId = contextActorId
        self.policyKey = policyKey
        self.policyValue = policyValue
        self.createdByActorId = createdByActorId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// UUID derivado del policy_key (namespace fijo) para usar como id local
    /// cuando el backend no lo devuelve. Mismo policy_key → mismo UUID.
    private static func derivedId(for policyKey: String) -> UUID {
        let bytes = Array(policyKey.utf8.prefix(16))
        var padded = bytes + Array(repeating: UInt8(0), count: 16 - bytes.count)
        return UUID(uuid: (
            padded[0], padded[1], padded[2], padded[3],
            padded[4], padded[5], padded[6], padded[7],
            padded[8], padded[9], padded[10], padded[11],
            padded[12], padded[13], padded[14], padded[15]
        ))
    }
}

/// R.5 — Delegación de voto dentro de un contexto. Mientras la delegación esté
/// activa (`revokedAt == nil` y `endsAt > now`), los votos del delegate cuentan
/// también el peso del delegator.
public struct VoteDelegation: Decodable, Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let contextActorId: UUID
    public let delegatorActorId: UUID
    public let delegateActorId: UUID
    public let startsAt: Date
    public let endsAt: Date?
    public let revokedAt: Date?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case contextActorId = "context_actor_id"
        case delegatorActorId = "delegator_actor_id"
        case delegateActorId = "delegate_actor_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case revokedAt = "revoked_at"
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        contextActorId: UUID,
        delegatorActorId: UUID,
        delegateActorId: UUID,
        startsAt: Date,
        endsAt: Date? = nil,
        revokedAt: Date? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.contextActorId = contextActorId
        self.delegatorActorId = delegatorActorId
        self.delegateActorId = delegateActorId
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.revokedAt = revokedAt
        self.createdAt = createdAt
    }

    /// La delegación está vigente AHORA.
    public var isActive: Bool {
        guard revokedAt == nil else { return false }
        if let ends = endsAt, ends <= Date() { return false }
        return true
    }
}

/// P1.8 — fila del catálogo declarativo R.7 (`governance_action_catalog`).
/// Solo informativa: la fuente de UI sigue siendo `available_actions[]`.
public struct GovernanceCatalogEntry: Codable, Sendable, Equatable, Identifiable {
    public let actionKey: String
    public let displayName: String
    public let domain: String
    public let defaultRequiresDecision: Bool
    public let dangerous: Bool

    public var id: String { actionKey }

    enum CodingKeys: String, CodingKey {
        case actionKey = "action_key"
        case displayName = "display_name"
        case domain
        case defaultRequiresDecision = "default_requires_decision"
        case dangerous
    }

    public init(actionKey: String, displayName: String, domain: String,
                defaultRequiresDecision: Bool, dangerous: Bool = false) {
        self.actionKey = actionKey
        self.displayName = displayName
        self.domain = domain
        self.defaultRequiresDecision = defaultRequiresDecision
        self.dangerous = dangerous
    }
}
