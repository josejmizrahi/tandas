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

/// Resultado de `invite_member(p_context_actor_id, p_member_actor_id, p_membership_type?)`.
/// Crea/reactiva una `actor_memberships` con `status='invited'` (queda pendiente
/// hasta que el invitado llame `accept_invitation`).
public struct InviteMemberResult: Decodable, Sendable, Equatable {
    public let membershipId: UUID
    /// `invited` (recién creada) o el status previo si ya existía.
    public let status: String

    enum CodingKeys: String, CodingKey {
        case membershipId = "membership_id"
        case status
    }

    public init(membershipId: UUID, status: String) {
        self.membershipId = membershipId
        self.status = status
    }
}

/// R.5W — Resultado de `create_placeholder_person(...)`. La persona queda
/// como `actor_kind='person'` con `is_placeholder=true` + membership activa
/// en el contexto. Aparece en members list inmediato y puede recibir
/// splits/obligaciones/RSVPs.
public struct PlaceholderPersonResult: Decodable, Sendable, Equatable {
    public let actorId: UUID
    public let membershipId: UUID
    public let displayName: String
    public let isPlaceholder: Bool
    public let contactPhone: String?
    public let contactEmail: String?

    enum CodingKeys: String, CodingKey {
        case actorId = "actor_id"
        case membershipId = "membership_id"
        case displayName = "display_name"
        case isPlaceholder = "is_placeholder"
        case contactPhone = "contact_phone"
        case contactEmail = "contact_email"
    }

    public init(
        actorId: UUID,
        membershipId: UUID,
        displayName: String,
        isPlaceholder: Bool = true,
        contactPhone: String? = nil,
        contactEmail: String? = nil
    ) {
        self.actorId = actorId
        self.membershipId = membershipId
        self.displayName = displayName
        self.isPlaceholder = isPlaceholder
        self.contactPhone = contactPhone
        self.contactEmail = contactEmail
    }
}

/// Resultado de `accept_invitation(p_context_actor_id)` — la membresía
/// pendiente del caller pasa a `status='active'`.
public struct AcceptInvitationResult: Decodable, Sendable, Equatable {
    public let membershipId: UUID
    public let status: String
    /// Backend marca true si ya éramos miembros activos (idempotente).
    public let alreadyMember: Bool

    enum CodingKeys: String, CodingKey {
        case membershipId = "membership_id"
        case status
        case alreadyMember = "already_member"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.membershipId = try c.decode(UUID.self, forKey: .membershipId)
        self.status = try c.decode(String.self, forKey: .status)
        self.alreadyMember = try c.decodeIfPresent(Bool.self, forKey: .alreadyMember) ?? false
    }

    public init(membershipId: UUID, status: String, alreadyMember: Bool = false) {
        self.membershipId = membershipId
        self.status = status
        self.alreadyMember = alreadyMember
    }
}

/// Una invitación pendiente que el actor actual recibió a un contexto.
/// Lectura PostgREST: `actor_memberships` filtrado por `member_actor_id = current
/// actor AND membership_status = 'invited'`, embebido con `actors` para el nombre
/// del contexto.
public struct PendingInvitation: Decodable, Sendable, Equatable, Identifiable {
    public let membershipId: UUID
    public let contextActorId: UUID
    public let contextDisplayName: String
    public let contextActorKind: ActorKind
    public let contextActorSubtype: String?
    public let invitedAt: Date?

    public var id: UUID { membershipId }

    enum CodingKeys: String, CodingKey {
        case membershipId = "id"
        case contextActorId = "context_actor_id"
        case context
        case createdAt = "created_at"
    }

    enum ContextKeys: String, CodingKey {
        case displayName = "display_name"
        case actorKind = "actor_kind"
        case actorSubtype = "actor_subtype"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.membershipId = try c.decode(UUID.self, forKey: .membershipId)
        self.contextActorId = try c.decode(UUID.self, forKey: .contextActorId)
        self.invitedAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)

        let ctx = try c.nestedContainer(keyedBy: ContextKeys.self, forKey: .context)
        self.contextDisplayName = try ctx.decode(String.self, forKey: .displayName)
        self.contextActorKind = try ctx.decode(ActorKind.self, forKey: .actorKind)
        self.contextActorSubtype = try ctx.decodeIfPresent(String.self, forKey: .actorSubtype)
    }

    public init(
        membershipId: UUID,
        contextActorId: UUID,
        contextDisplayName: String,
        contextActorKind: ActorKind,
        contextActorSubtype: String? = nil,
        invitedAt: Date? = nil
    ) {
        self.membershipId = membershipId
        self.contextActorId = contextActorId
        self.contextDisplayName = contextDisplayName
        self.contextActorKind = contextActorKind
        self.contextActorSubtype = contextActorSubtype
        self.invitedAt = invitedAt
    }
}
