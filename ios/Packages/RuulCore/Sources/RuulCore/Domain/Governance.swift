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
