import Foundation

/// Resultado de `create_invite()`.
public struct InviteCreated: Decodable, Sendable, Equatable {
    public let inviteId: UUID
    /// Código compartible (8 chars hex).
    public let code: String

    enum CodingKeys: String, CodingKey {
        case inviteId = "invite_id"
        case code
    }

    public init(inviteId: UUID, code: String) {
        self.inviteId = inviteId
        self.code = code
    }
}

/// Resultado de `join_by_invite_code()`.
public struct JoinResult: Decodable, Sendable, Equatable {
    public let contextActorId: UUID
    public let membershipId: UUID
    public let context: ActorRecord

    enum CodingKeys: String, CodingKey {
        case contextActorId = "context_actor_id"
        case membershipId = "membership_id"
        case context
    }

    public init(contextActorId: UUID, membershipId: UUID, context: ActorRecord) {
        self.contextActorId = contextActorId
        self.membershipId = membershipId
        self.context = context
    }
}
