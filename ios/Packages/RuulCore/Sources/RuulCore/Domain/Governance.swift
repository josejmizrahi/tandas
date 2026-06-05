import Foundation

/// R.5 — Política de gobierno asociada a un context_actor. Doctrina: el valor
/// es `JSONValue` arbitrario (el backend define la forma por policy_key), pero
/// el frontend sólo presenta — no interpreta business logic ni hace switch
/// por policy_key.
public struct GovernancePolicy: Decodable, Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let contextActorId: UUID
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
        self.id = try c.decode(UUID.self, forKey: .id)
        self.contextActorId = try c.decode(UUID.self, forKey: .contextActorId)
        self.policyKey = try c.decode(String.self, forKey: .policyKey)
        self.policyValue = try c.decode(JSONValue.self, forKey: .policyValue)
        self.createdByActorId = try c.decodeIfPresent(UUID.self, forKey: .createdByActorId)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public init(
        id: UUID,
        contextActorId: UUID,
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
}
