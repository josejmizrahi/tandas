import Foundation

/// R.0E.2 — payload of `my_world_summary()` RPC. Auth-scoped: resuelve
/// `auth.uid()` → actor (D2 R.0A: `actors.id = auth.users.id` para person)
/// y compone 10 secciones en un solo jsonb.
///
/// Founder rules (R.0H.1 doctrine):
/// - Arrays default `[]` (decodeIfPresent ?? [])
/// - `metadata` como `[String: RPCJSONValue]?` (jsonb tolerante)
/// - Fechas opcionales (formato puede cambiar)
/// - Unknown fields ignorados (default Codable)
///
/// R.0H.2 consume esta estructura desde `PersonalHomeView`. Cero UI en R.0H.1.
public struct MyWorldSummary: Sendable, Equatable, Hashable {
    public let actor: MyWorldActor
    public let asOf: Date?
    public let netWorth: MyWorldNetWorth?
    public let ownedResources: [MyWorldValuedResource]
    public let managedResources: [MyWorldResourceRef]
    public let usedResources: [MyWorldResourceRef]
    public let beneficiaryResources: [MyWorldValuedResource]
    public let groups: [MyWorldGroup]
    public let controlledEntities: [MyWorldControlledEntity]
    public let obligations: [MyWorldObligation]
    public let recentActivity: [MyWorldActivityEvent]
    public let pendingDecisions: [MyWorldPendingDecision]
    public let notes: [String: RPCJSONValue]?
}

extension MyWorldSummary: Decodable {
    enum CodingKeys: String, CodingKey {
        case actor
        case asOf                  = "as_of"
        case netWorth              = "net_worth"
        case ownedResources        = "owned_resources"
        case managedResources      = "managed_resources"
        case usedResources         = "used_resources"
        case beneficiaryResources  = "beneficiary_resources"
        case groups
        case controlledEntities    = "controlled_entities"
        case obligations
        case recentActivity        = "recent_activity"
        case pendingDecisions      = "pending_decisions"
        case notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.actor                = try c.decode(MyWorldActor.self, forKey: .actor)
        self.asOf                 = try c.decodeIfPresent(Date.self, forKey: .asOf)
        self.netWorth             = try c.decodeIfPresent(MyWorldNetWorth.self, forKey: .netWorth)
        self.ownedResources       = try c.decodeIfPresent([MyWorldValuedResource].self, forKey: .ownedResources) ?? []
        self.managedResources     = try c.decodeIfPresent([MyWorldResourceRef].self, forKey: .managedResources) ?? []
        self.usedResources        = try c.decodeIfPresent([MyWorldResourceRef].self, forKey: .usedResources) ?? []
        self.beneficiaryResources = try c.decodeIfPresent([MyWorldValuedResource].self, forKey: .beneficiaryResources) ?? []
        self.groups               = try c.decodeIfPresent([MyWorldGroup].self, forKey: .groups) ?? []
        self.controlledEntities   = try c.decodeIfPresent([MyWorldControlledEntity].self, forKey: .controlledEntities) ?? []
        self.obligations          = try c.decodeIfPresent([MyWorldObligation].self, forKey: .obligations) ?? []
        self.recentActivity       = try c.decodeIfPresent([MyWorldActivityEvent].self, forKey: .recentActivity) ?? []
        self.pendingDecisions     = try c.decodeIfPresent([MyWorldPendingDecision].self, forKey: .pendingDecisions) ?? []
        self.notes                = try c.decodeIfPresent([String: RPCJSONValue].self, forKey: .notes)
    }
}

// MARK: - Actor

public struct MyWorldActor: Codable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let actorKind: String
    public let displayName: String
    public let metadata: [String: RPCJSONValue]?

    enum CodingKeys: String, CodingKey {
        case id
        case actorKind   = "actor_kind"
        case displayName = "display_name"
        case metadata
    }
}

// MARK: - Net worth (delegated to actor_net_worth jsonb shape)

public struct MyWorldNetWorth: Sendable, Equatable, Hashable {
    public let actorId: UUID?
    public let asOf: Date?
    public let ownedByCurrency: [MyWorldNetWorthOwned]
    public let beneficiaryByCurrency: [MyWorldNetWorthBeneficiary]
    public let notes: [String: RPCJSONValue]?
}

extension MyWorldNetWorth: Decodable {
    enum CodingKeys: String, CodingKey {
        case actorId               = "actor_id"
        case asOf                  = "as_of"
        case ownedByCurrency       = "owned_by_currency"
        case beneficiaryByCurrency = "beneficiary_by_currency"
        case notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.actorId               = try c.decodeIfPresent(UUID.self, forKey: .actorId)
        self.asOf                  = try c.decodeIfPresent(Date.self, forKey: .asOf)
        self.ownedByCurrency       = try c.decodeIfPresent([MyWorldNetWorthOwned].self, forKey: .ownedByCurrency) ?? []
        self.beneficiaryByCurrency = try c.decodeIfPresent([MyWorldNetWorthBeneficiary].self, forKey: .beneficiaryByCurrency) ?? []
        self.notes                 = try c.decodeIfPresent([String: RPCJSONValue].self, forKey: .notes)
    }
}

public struct MyWorldNetWorthOwned: Codable, Sendable, Equatable, Hashable {
    public let currency: String
    public let ownedValue: Decimal
    public let ownedCount: Int
    public let resourceIds: [UUID]

    enum CodingKeys: String, CodingKey {
        case currency
        case ownedValue   = "owned_value"
        case ownedCount   = "owned_count"
        case resourceIds  = "resource_ids"
    }
}

public struct MyWorldNetWorthBeneficiary: Codable, Sendable, Equatable, Hashable {
    public let currency: String
    public let value: Decimal
    public let count: Int
    public let resourceIds: [UUID]

    enum CodingKeys: String, CodingKey {
        case currency
        case value
        case count
        case resourceIds  = "resource_ids"
    }
}

// MARK: - Resource refs

public struct MyWorldResourceRef: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let resourceId: UUID
    public let name: String
    public let resourceType: String
    public let groupId: UUID?

    public var id: UUID { resourceId }

    enum CodingKeys: String, CodingKey {
        case resourceId    = "resource_id"
        case name
        case resourceType  = "resource_type"
        case groupId       = "group_id"
    }
}

public struct MyWorldValuedResource: Sendable, Equatable, Hashable, Identifiable {
    public let resourceId: UUID
    public let name: String
    public let resourceType: String
    public let groupId: UUID?
    public let percent: Decimal?
    public let currency: String
    public let estimatedValue: Decimal

    public var id: UUID { resourceId }
}

extension MyWorldValuedResource: Decodable {
    enum CodingKeys: String, CodingKey {
        case resourceId      = "resource_id"
        case name
        case resourceType    = "resource_type"
        case groupId         = "group_id"
        case percent
        case currency
        case estimatedValue  = "estimated_value"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resourceId     = try c.decode(UUID.self, forKey: .resourceId)
        self.name           = try c.decode(String.self, forKey: .name)
        self.resourceType   = try c.decode(String.self, forKey: .resourceType)
        self.groupId        = try c.decodeIfPresent(UUID.self, forKey: .groupId)
        self.percent        = try c.decodeIfPresent(Decimal.self, forKey: .percent)
        self.currency       = try c.decodeIfPresent(String.self, forKey: .currency) ?? "unknown"
        self.estimatedValue = try c.decodeIfPresent(Decimal.self, forKey: .estimatedValue) ?? 0
    }
}

// MARK: - Groups

public struct MyWorldGroup: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let groupId: UUID
    public let name: String
    public let membershipType: String?
    public let joinedVia: String?

    public var id: UUID { groupId }

    enum CodingKeys: String, CodingKey {
        case groupId         = "group_id"
        case name
        case membershipType  = "membership_type"
        case joinedVia       = "joined_via"
    }
}

// MARK: - Controlled entities

public struct MyWorldControlledEntity: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let actorId: UUID
    public let displayName: String?
    public let actorKind: String?
    public let relationshipType: String
    public let metadata: [String: RPCJSONValue]?

    public var id: UUID { actorId }

    enum CodingKeys: String, CodingKey {
        case actorId           = "actor_id"
        case displayName       = "display_name"
        case actorKind         = "actor_kind"
        case relationshipType  = "relationship_type"
        case metadata
    }
}

// MARK: - Obligations

public struct MyWorldObligation: Sendable, Equatable, Hashable, Identifiable {
    public let relationshipId: UUID
    public let relationshipType: String
    public let direction: String
    public let subjectActorId: UUID?
    public let objectActorId: UUID?
    public let objectResourceId: UUID?
    public let metadata: [String: RPCJSONValue]?

    public var id: UUID { relationshipId }
}

extension MyWorldObligation: Decodable {
    enum CodingKeys: String, CodingKey {
        case relationshipId    = "relationship_id"
        case relationshipType  = "relationship_type"
        case direction
        case subjectActorId    = "subject_actor_id"
        case objectActorId     = "object_actor_id"
        case objectResourceId  = "object_resource_id"
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.relationshipId   = try c.decode(UUID.self, forKey: .relationshipId)
        self.relationshipType = try c.decode(String.self, forKey: .relationshipType)
        self.direction        = try c.decodeIfPresent(String.self, forKey: .direction) ?? "both"
        self.subjectActorId   = try c.decodeIfPresent(UUID.self, forKey: .subjectActorId)
        self.objectActorId    = try c.decodeIfPresent(UUID.self, forKey: .objectActorId)
        self.objectResourceId = try c.decodeIfPresent(UUID.self, forKey: .objectResourceId)
        self.metadata         = try c.decodeIfPresent([String: RPCJSONValue].self, forKey: .metadata)
    }
}

// MARK: - Recent activity

public struct MyWorldActivityEvent: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let eventId: UUID
    public let eventType: String
    public let groupId: UUID?
    public let entityKind: String?
    public let entityId: UUID?
    public let actorUserId: UUID?
    public let payload: [String: RPCJSONValue]?
    public let createdAt: Date?

    public var id: UUID { eventId }

    enum CodingKeys: String, CodingKey {
        case eventId      = "event_id"
        case eventType    = "event_type"
        case groupId      = "group_id"
        case entityKind   = "entity_kind"
        case entityId     = "entity_id"
        case actorUserId  = "actor_user_id"
        case payload
        case createdAt    = "created_at"
    }
}

// MARK: - Pending decisions

public struct MyWorldPendingDecision: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let decisionId: UUID
    public let title: String?
    public let groupId: UUID
    public let status: String
    public let createdAt: Date?

    public var id: UUID { decisionId }

    enum CodingKeys: String, CodingKey {
        case decisionId  = "decision_id"
        case title
        case groupId     = "group_id"
        case status
        case createdAt   = "created_at"
    }
}
