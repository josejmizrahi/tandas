import Foundation

/// R.2U — Context Hierarchy.
///
/// Doctrina: la jerarquía es organizacional, NO transfiere autoridad.
/// Memberships, rights, rules y money NO heredan vía `contains`.
/// Se construye sobre `actor_relationships.contains` (cero primitiva nueva).

/// Nodo plano devuelto por `context_children` / `context_parents` /
/// `context_ancestors` / `context_descendants`. Campos opcionales según RPC:
/// - `visibility` sólo en children
/// - `linkedAt` en children y parents
/// - `depth` en ancestors y descendants
public struct ContextHierarchyNode: Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let actorKind: ActorKind
    public let actorSubtype: String
    public let visibility: String?
    public let linkedAt: Date?
    public let depth: Int?

    public init(
        id: UUID,
        name: String,
        actorKind: ActorKind,
        actorSubtype: String,
        visibility: String? = nil,
        linkedAt: Date? = nil,
        depth: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.actorKind = actorKind
        self.actorSubtype = actorSubtype
        self.visibility = visibility
        self.linkedAt = linkedAt
        self.depth = depth
    }

    public var appContext: AppContext {
        AppContext(
            id: id,
            kind: actorKind,
            subtype: actorSubtype,
            displayName: name
        )
    }
}

extension ContextHierarchyNode: Decodable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case actorKind = "actor_kind"
        case actorSubtype = "actor_subtype"
        case visibility
        case linkedAt = "linked_at"
        case depth
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.actorKind = try c.decode(ActorKind.self, forKey: .actorKind)
        self.actorSubtype = try c.decode(String.self, forKey: .actorSubtype)
        self.visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
        self.linkedAt = try c.decodeIfPresent(Date.self, forKey: .linkedAt)
        self.depth = try c.decodeIfPresent(Int.self, forKey: .depth)
    }
}

/// Árbol recursivo devuelto por `context_tree(p_root_context_actor_id)`.
/// `children = nil + restricted = true` cuando el caller no es miembro de un
/// subárbol — el backend revela la presencia pero no el contenido.
public struct ContextTreeNode: Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let actorKind: ActorKind
    public let actorSubtype: String
    public let restricted: Bool
    public let children: [ContextTreeNode]?

    public init(
        id: UUID,
        name: String,
        actorKind: ActorKind,
        actorSubtype: String,
        restricted: Bool = false,
        children: [ContextTreeNode]? = nil
    ) {
        self.id = id
        self.name = name
        self.actorKind = actorKind
        self.actorSubtype = actorSubtype
        self.restricted = restricted
        self.children = children
    }

    public var appContext: AppContext {
        AppContext(id: id, kind: actorKind, subtype: actorSubtype, displayName: name)
    }
}

extension ContextTreeNode: Decodable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case actorKind = "actor_kind"
        case actorSubtype = "actor_subtype"
        case restricted
        case children
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.actorKind = try c.decode(ActorKind.self, forKey: .actorKind)
        self.actorSubtype = try c.decode(String.self, forKey: .actorSubtype)
        self.restricted = try c.decodeIfPresent(Bool.self, forKey: .restricted) ?? false
        self.children = try c.decodeIfPresent([ContextTreeNode].self, forKey: .children)
    }
}

/// Input para `create_child_context(p_parent, p_display_name, p_actor_kind,
/// p_actor_subtype, p_visibility, p_metadata)`.
public struct CreateChildContextInput: Sendable, Equatable {
    public let parentContextActorId: UUID
    public let displayName: String
    public let actorKind: ActorKind
    public let actorSubtype: String
    public let visibility: String

    public init(
        parentContextActorId: UUID,
        displayName: String,
        actorKind: ActorKind = .collective,
        actorSubtype: String = "friend_group",
        visibility: String = "private"
    ) {
        self.parentContextActorId = parentContextActorId
        self.displayName = displayName
        self.actorKind = actorKind
        self.actorSubtype = actorSubtype
        self.visibility = visibility
    }
}

/// Resultado de `create_child_context(...)`. Incluye el child como ActorRecord
/// para refresh inmediato del switcher sin segunda lectura.
public struct CreatedChildContext: Decodable, Sendable, Equatable {
    public let parentContextActorId: UUID
    public let childContextActorId: UUID
    public let relationshipId: UUID
    public let context: ActorRecord

    enum CodingKeys: String, CodingKey {
        case parentContextActorId = "parent_context_actor_id"
        case childContextActorId = "child_context_actor_id"
        case relationshipId = "relationship_id"
        case context
    }
}

/// Resultado de `link_child_context(p_parent, p_child)`. `alreadyLinked=true`
/// indica idempotencia (la relación ya estaba activa).
public struct LinkChildContextResult: Decodable, Sendable, Equatable {
    public let parentContextActorId: UUID
    public let childContextActorId: UUID
    public let relationshipId: UUID
    public let alreadyLinked: Bool

    enum CodingKeys: String, CodingKey {
        case parentContextActorId = "parent_context_actor_id"
        case childContextActorId = "child_context_actor_id"
        case relationshipId = "relationship_id"
        case alreadyLinked = "already_linked"
    }

    public init(
        parentContextActorId: UUID,
        childContextActorId: UUID,
        relationshipId: UUID,
        alreadyLinked: Bool
    ) {
        self.parentContextActorId = parentContextActorId
        self.childContextActorId = childContextActorId
        self.relationshipId = relationshipId
        self.alreadyLinked = alreadyLinked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.parentContextActorId = try c.decode(UUID.self, forKey: .parentContextActorId)
        self.childContextActorId = try c.decode(UUID.self, forKey: .childContextActorId)
        self.relationshipId = try c.decode(UUID.self, forKey: .relationshipId)
        self.alreadyLinked = try c.decodeIfPresent(Bool.self, forKey: .alreadyLinked) ?? false
    }
}

/// Resultado de `unlink_child_context(p_parent, p_child)`. `unlinked=false`
/// indica idempotencia (no había vínculo activo).
public struct UnlinkChildContextResult: Decodable, Sendable, Equatable {
    public let parentContextActorId: UUID
    public let childContextActorId: UUID
    public let relationshipId: UUID?
    public let unlinked: Bool

    enum CodingKeys: String, CodingKey {
        case parentContextActorId = "parent_context_actor_id"
        case childContextActorId = "child_context_actor_id"
        case relationshipId = "relationship_id"
        case unlinked
    }

    public init(
        parentContextActorId: UUID,
        childContextActorId: UUID,
        relationshipId: UUID?,
        unlinked: Bool
    ) {
        self.parentContextActorId = parentContextActorId
        self.childContextActorId = childContextActorId
        self.relationshipId = relationshipId
        self.unlinked = unlinked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.parentContextActorId = try c.decode(UUID.self, forKey: .parentContextActorId)
        self.childContextActorId = try c.decode(UUID.self, forKey: .childContextActorId)
        self.relationshipId = try c.decodeIfPresent(UUID.self, forKey: .relationshipId)
        self.unlinked = try c.decodeIfPresent(Bool.self, forKey: .unlinked) ?? false
    }
}
