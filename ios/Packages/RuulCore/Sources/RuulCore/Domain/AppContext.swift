import Foundation

/// Un **contexto** es el actor desde el cual el usuario opera: su propia
/// persona, un colectivo (cena semanal, familia, viaje) o una entidad legal
/// (negocio, trust). Doctrina MVP2: Actor = dato, Contexto = experiencia.
public struct AppContext: Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let kind: ActorKind
    public let subtype: String
    public let displayName: String
    /// `founder` / `member` / `guest` / `observer` — nil para el contexto personal.
    public let membershipType: String?
    public let memberCount: Int
    /// Role keys del caller en este contexto (`admin`, `member`, …).
    public let roles: [String]
    /// F.NAV.3 — id del contexto padre cuando este contexto es hijo en
    /// `actor_relationships('contains')`. nil para raíces. Permite a
    /// `ContextsListView` mostrar sólo raíces; los hijos viven dentro del padre.
    public let parentContextActorId: UUID?

    public init(
        id: UUID,
        kind: ActorKind,
        subtype: String,
        displayName: String,
        membershipType: String? = nil,
        memberCount: Int = 0,
        roles: [String] = [],
        parentContextActorId: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.subtype = subtype
        self.displayName = displayName
        self.membershipType = membershipType
        self.memberCount = memberCount
        self.roles = roles
        self.parentContextActorId = parentContextActorId
    }

    /// F.NAV.3 — true si este contexto no es hijo de otro (raíz).
    public var isRoot: Bool { parentContextActorId == nil }

    public var isPersonal: Bool { kind == .person }
    public var isAdmin: Bool { isPersonal || roles.contains("admin") }

    /// SF Symbol según el tipo de contexto.
    public var symbolName: String {
        switch kind {
        case .person: return "person.crop.circle.fill"
        case .collective:
            switch subtype {
            case "family": return "figure.2.and.child.holdinghands"
            case "trip": return "airplane"
            case "community": return "person.3.fill"
            default: return "person.3.fill"
            }
        case .legalEntity:
            switch subtype {
            case "trust": return "building.columns.fill"
            default: return "building.2.fill"
            }
        case .system: return "gearshape.fill"
        }
    }
}

// MARK: - context_candidates() payload

/// Respuesta de `context_candidates()`.
public struct ContextCandidates: Sendable, Equatable {
    public let personalContext: ActorRecord
    public let contexts: [ContextCandidate]

    public init(personalContext: ActorRecord, contexts: [ContextCandidate]) {
        self.personalContext = personalContext
        self.contexts = contexts
    }

    /// Lista plana de contextos operables: persona primero, luego colectivos.
    public var appContexts: [AppContext] {
        var out: [AppContext] = [
            AppContext(
                id: personalContext.id,
                kind: .person,
                subtype: personalContext.actorSubtype,
                displayName: personalContext.displayName
            )
        ]
        for candidate in contexts where candidate.contextActorId != personalContext.id {
            out.append(candidate.appContext)
        }
        return out
    }
}

extension ContextCandidates: Decodable {
    enum CodingKeys: String, CodingKey {
        case personalContext = "personal_context"
        case contexts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.personalContext = try c.decode(ActorRecord.self, forKey: .personalContext)
        self.contexts = try c.decodeIfPresent([ContextCandidate].self, forKey: .contexts) ?? []
    }
}

/// Un elemento de `context_candidates().contexts`.
public struct ContextCandidate: Decodable, Sendable, Equatable, Identifiable {
    public let contextActorId: UUID
    public let displayName: String
    public let actorKind: ActorKind
    public let actorSubtype: String
    public let visibility: String?
    public let membershipType: String?
    public let memberCount: Int
    public let roles: [String]
    /// F.NAV.3 — id del contexto padre (null = raíz).
    public let parentContextActorId: UUID?

    enum CodingKeys: String, CodingKey {
        case contextActorId = "context_actor_id"
        case displayName = "display_name"
        case actorKind = "actor_kind"
        case actorSubtype = "actor_subtype"
        case visibility
        case membershipType = "membership_type"
        case memberCount = "member_count"
        case roles
        case parentContextActorId = "parent_context_actor_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.contextActorId = try c.decode(UUID.self, forKey: .contextActorId)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.actorKind = try c.decode(ActorKind.self, forKey: .actorKind)
        self.actorSubtype = try c.decode(String.self, forKey: .actorSubtype)
        self.visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
        self.membershipType = try c.decodeIfPresent(String.self, forKey: .membershipType)
        self.memberCount = try c.decodeIfPresent(Int.self, forKey: .memberCount) ?? 0
        self.roles = try c.decodeIfPresent([String].self, forKey: .roles) ?? []
        self.parentContextActorId = try c.decodeIfPresent(UUID.self, forKey: .parentContextActorId)
    }

    public init(
        contextActorId: UUID,
        displayName: String,
        actorKind: ActorKind,
        actorSubtype: String,
        visibility: String? = nil,
        membershipType: String? = nil,
        memberCount: Int = 0,
        roles: [String] = [],
        parentContextActorId: UUID? = nil
    ) {
        self.contextActorId = contextActorId
        self.displayName = displayName
        self.actorKind = actorKind
        self.actorSubtype = actorSubtype
        self.visibility = visibility
        self.membershipType = membershipType
        self.memberCount = memberCount
        self.roles = roles
        self.parentContextActorId = parentContextActorId
    }

    public var id: UUID { contextActorId }

    public var appContext: AppContext {
        AppContext(
            id: contextActorId,
            kind: actorKind,
            subtype: actorSubtype,
            displayName: displayName,
            membershipType: membershipType,
            memberCount: memberCount,
            roles: roles,
            parentContextActorId: parentContextActorId
        )
    }
}

/// Resultado de `create_context()`.
public struct CreatedContext: Decodable, Sendable, Equatable {
    public let contextActorId: UUID
    public let context: ActorRecord

    enum CodingKeys: String, CodingKey {
        case contextActorId = "context_actor_id"
        case context
    }
}

/// FE.7 — resultado de `archive_context(p_context_actor_id)`.
/// Backend retorna `{context_actor_id, archived, already_archived?}`. La RPC
/// solo procede directa si la policy `context_archive_requires_vote` está en
/// `false`; de lo contrario raise `governance_required` (42501) y el caller
/// debe pasar por `request_governance_action('context.archive')`.
public struct ContextArchivedResult: Decodable, Sendable, Equatable {
    public let contextActorId: UUID
    public let archived: Bool
    public let alreadyArchived: Bool

    enum CodingKeys: String, CodingKey {
        case contextActorId = "context_actor_id"
        case archived
        case alreadyArchived = "already_archived"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.contextActorId = try c.decode(UUID.self, forKey: .contextActorId)
        self.archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        self.alreadyArchived = try c.decodeIfPresent(Bool.self, forKey: .alreadyArchived) ?? false
    }

    public init(contextActorId: UUID, archived: Bool, alreadyArchived: Bool = false) {
        self.contextActorId = contextActorId
        self.archived = archived
        self.alreadyArchived = alreadyArchived
    }
}
