import Foundation

// MARK: - Actor

public enum ActorKind: String, Codable, Sendable, Hashable, CaseIterable {
    case person
    case collective
    case legalEntity = "legal_entity"
    case system
}

/// Fila de `actors` (la devuelven `create_context`, `context_candidates`,
/// `join_by_invite_code`, `ensure_person_actor`, … vía `to_jsonb(a)`).
public struct ActorRecord: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let actorKind: ActorKind
    public let actorSubtype: String
    public let displayName: String
    public let slug: String?
    public let status: String
    public let visibility: String
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case actorKind = "actor_kind"
        case actorSubtype = "actor_subtype"
        case displayName = "display_name"
        case slug
        case status
        case visibility
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        actorKind: ActorKind,
        actorSubtype: String,
        displayName: String,
        slug: String? = nil,
        status: String = "active",
        visibility: String = "private",
        createdAt: Date? = nil
    ) {
        self.id = id
        self.actorKind = actorKind
        self.actorSubtype = actorSubtype
        self.displayName = displayName
        self.slug = slug
        self.status = status
        self.visibility = visibility
        self.createdAt = createdAt
    }
}

// MARK: - Person profile

/// Fila de `person_profiles` (subset que iOS necesita).
public struct PersonProfile: Codable, Sendable, Equatable, Hashable {
    public let actorId: UUID
    public let fullName: String?
    public let preferredName: String?
    public let phone: String?
    public let email: String?
    public let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case actorId = "actor_id"
        case fullName = "full_name"
        case preferredName = "preferred_name"
        case phone
        case email
        case avatarUrl = "avatar_url"
    }

    public init(
        actorId: UUID,
        fullName: String? = nil,
        preferredName: String? = nil,
        phone: String? = nil,
        email: String? = nil,
        avatarUrl: String? = nil
    ) {
        self.actorId = actorId
        self.fullName = fullName
        self.preferredName = preferredName
        self.phone = phone
        self.email = email
        self.avatarUrl = avatarUrl
    }
}

// MARK: - Current actor

/// Resultado de `ensure_person_actor()` / `update_my_profile()`:
/// el actor person del usuario autenticado + su perfil.
public struct CurrentActor: Codable, Sendable, Equatable {
    public let actor: ActorRecord
    public let profile: PersonProfile?

    enum CodingKeys: String, CodingKey {
        case actor
        case profile
    }

    public init(actor: ActorRecord, profile: PersonProfile? = nil) {
        self.actor = actor
        self.profile = profile
    }

    public var id: UUID { actor.id }
    public var displayName: String { actor.displayName }
}
