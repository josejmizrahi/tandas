import Foundation

// MARK: - AttentionItem

/// F.NAV.0 — Item del `attention_inbox()` cross-context. Shape canónico:
/// {kind, subject_id, context_actor_id, context_display_name, title, reason,
///  cta_action_key, cta_scope_kind, cta_scope_id, occurred_at}.
///
/// El `cta_action_key` es compatible con `ActionRouter` (F.2X). Cada
/// `cta_scope_kind` mapea a un `ActionScope` (`reservation`/`decision`/
/// `obligation`/`context`).
public struct AttentionItem: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let kind: String
    public let subjectId: UUID
    public let contextActorId: UUID
    public let contextDisplayName: String
    public let title: String
    public let reason: String
    public let ctaActionKey: String
    public let ctaScopeKind: String
    public let ctaScopeId: UUID
    public let occurredAt: Date?

    enum CodingKeys: String, CodingKey {
        case kind
        case subjectId = "subject_id"
        case contextActorId = "context_actor_id"
        case contextDisplayName = "context_display_name"
        case title
        case reason
        case ctaActionKey = "cta_action_key"
        case ctaScopeKind = "cta_scope_kind"
        case ctaScopeId = "cta_scope_id"
        case occurredAt = "occurred_at"
    }

    public init(
        kind: String,
        subjectId: UUID,
        contextActorId: UUID,
        contextDisplayName: String,
        title: String,
        reason: String,
        ctaActionKey: String,
        ctaScopeKind: String,
        ctaScopeId: UUID,
        occurredAt: Date? = nil
    ) {
        self.kind = kind
        self.subjectId = subjectId
        self.contextActorId = contextActorId
        self.contextDisplayName = contextDisplayName
        self.title = title
        self.reason = reason
        self.ctaActionKey = ctaActionKey
        self.ctaScopeKind = ctaScopeKind
        self.ctaScopeId = ctaScopeId
        self.occurredAt = occurredAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decode(String.self, forKey: .kind)
        self.subjectId = try c.decode(UUID.self, forKey: .subjectId)
        self.contextActorId = try c.decode(UUID.self, forKey: .contextActorId)
        self.contextDisplayName = try c.decode(String.self, forKey: .contextDisplayName)
        self.title = try c.decode(String.self, forKey: .title)
        self.reason = try c.decode(String.self, forKey: .reason)
        self.ctaActionKey = try c.decode(String.self, forKey: .ctaActionKey)
        self.ctaScopeKind = try c.decode(String.self, forKey: .ctaScopeKind)
        self.ctaScopeId = try c.decode(UUID.self, forKey: .ctaScopeId)
        self.occurredAt = try c.decodeIfPresent(Date.self, forKey: .occurredAt)
    }

    public var id: UUID { subjectId }
}

// MARK: - ContextPreference

/// F.NAV.0 — Fila de `actor_context_preferences` unida a `actors`. Se entrega
/// desde `list_context_favorites()` y `list_recent_contexts()`.
public struct ContextPreference: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let contextActorId: UUID
    public let displayName: String
    public let actorKind: String
    public let actorSubtype: String?
    public let isFavorite: Bool
    public let favoritedAt: Date?
    public let lastVisitedAt: Date?

    enum CodingKeys: String, CodingKey {
        case contextActorId = "context_actor_id"
        case displayName = "display_name"
        case actorKind = "actor_kind"
        case actorSubtype = "actor_subtype"
        case isFavorite = "is_favorite"
        case favoritedAt = "favorited_at"
        case lastVisitedAt = "last_visited_at"
    }

    public init(
        contextActorId: UUID,
        displayName: String,
        actorKind: String,
        actorSubtype: String? = nil,
        isFavorite: Bool = false,
        favoritedAt: Date? = nil,
        lastVisitedAt: Date? = nil
    ) {
        self.contextActorId = contextActorId
        self.displayName = displayName
        self.actorKind = actorKind
        self.actorSubtype = actorSubtype
        self.isFavorite = isFavorite
        self.favoritedAt = favoritedAt
        self.lastVisitedAt = lastVisitedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.contextActorId = try c.decode(UUID.self, forKey: .contextActorId)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.actorKind = try c.decode(String.self, forKey: .actorKind)
        self.actorSubtype = try c.decodeIfPresent(String.self, forKey: .actorSubtype)
        self.isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        self.favoritedAt = try c.decodeIfPresent(Date.self, forKey: .favoritedAt)
        self.lastVisitedAt = try c.decodeIfPresent(Date.self, forKey: .lastVisitedAt)
    }

    public var id: UUID { contextActorId }
}
