import Foundation

/// Payload de `my_world()` — la vista personal: mis contextos, los recursos
/// que puedo ver (con la razón: qué derecho me los hace visibles) y mis
/// obligaciones abiertas en todos los contextos.
public struct MyWorld: Sendable, Equatable {
    public let actorId: UUID
    public let contexts: [MyWorldContext]
    public let resources: [MyWorldResource]
    public let openObligations: [MyWorldObligation]

    public init(
        actorId: UUID,
        contexts: [MyWorldContext] = [],
        resources: [MyWorldResource] = [],
        openObligations: [MyWorldObligation] = []
    ) {
        self.actorId = actorId
        self.contexts = contexts
        self.resources = resources
        self.openObligations = openObligations
    }
}

extension MyWorld: Decodable {
    enum CodingKeys: String, CodingKey {
        case actorId = "actor_id"
        case contexts
        case resources
        case openObligations = "open_obligations"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.actorId = try c.decode(UUID.self, forKey: .actorId)
        self.contexts = try c.decodeIfPresent([MyWorldContext].self, forKey: .contexts) ?? []
        self.resources = try c.decodeIfPresent([MyWorldResource].self, forKey: .resources) ?? []
        self.openObligations = try c.decodeIfPresent([MyWorldObligation].self, forKey: .openObligations) ?? []
    }
}

public struct MyWorldContext: Codable, Sendable, Equatable, Identifiable {
    public let contextActorId: UUID
    public let displayName: String
    public let actorKind: ActorKind
    public let actorSubtype: String?
    public let membershipType: String?

    enum CodingKeys: String, CodingKey {
        case contextActorId = "context_actor_id"
        case displayName = "display_name"
        case actorKind = "actor_kind"
        case actorSubtype = "actor_subtype"
        case membershipType = "membership_type"
    }

    public init(
        contextActorId: UUID,
        displayName: String,
        actorKind: ActorKind,
        actorSubtype: String? = nil,
        membershipType: String? = nil
    ) {
        self.contextActorId = contextActorId
        self.displayName = displayName
        self.actorKind = actorKind
        self.actorSubtype = actorSubtype
        self.membershipType = membershipType
    }

    public var id: UUID { contextActorId }
}

/// Recurso visible para mí + las razones (right kinds, directos o vía otro actor).
public struct MyWorldResource: Codable, Sendable, Equatable, Identifiable {
    public let resourceId: UUID
    public let displayName: String
    public let resourceType: String
    /// p. ej. `["USE", "GOVERN via Familia Mizrahi"]`
    public let reasons: [String]
    /// R.9.I — contexto dueño del recurso (canonical owner colectivo, o el
    /// person actor del caller para recursos personales). `nil` si el dueño
    /// es otra persona (recurso visible solo vía un right directo).
    public let contextActorId: UUID?
    public let contextDisplayName: String?

    enum CodingKeys: String, CodingKey {
        case resourceId = "resource_id"
        case displayName = "display_name"
        case resourceType = "resource_type"
        case reasons
        case contextActorId = "context_actor_id"
        case contextDisplayName = "context_display_name"
    }

    public init(
        resourceId: UUID,
        displayName: String,
        resourceType: String,
        reasons: [String] = [],
        contextActorId: UUID? = nil,
        contextDisplayName: String? = nil
    ) {
        self.resourceId = resourceId
        self.displayName = displayName
        self.resourceType = resourceType
        self.reasons = reasons
        self.contextActorId = contextActorId
        self.contextDisplayName = contextDisplayName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resourceId = try c.decode(UUID.self, forKey: .resourceId)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.resourceType = try c.decode(String.self, forKey: .resourceType)
        self.reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        self.contextActorId = try c.decodeIfPresent(UUID.self, forKey: .contextActorId)
        self.contextDisplayName = try c.decodeIfPresent(String.self, forKey: .contextDisplayName)
    }

    public var id: UUID { resourceId }
}

public struct MyWorldObligation: Codable, Sendable, Equatable, Identifiable {
    public let obligationId: UUID
    public let contextActorId: UUID?
    public let contextName: String?
    /// `debtor` (debo) o `creditor` (me deben).
    public let role: String
    public let obligationType: String
    public let amount: Double?
    public let currency: String?

    enum CodingKeys: String, CodingKey {
        case obligationId = "obligation_id"
        case contextActorId = "context_actor_id"
        case contextName = "context_name"
        case role
        case obligationType = "obligation_type"
        case amount
        case currency
    }

    public init(
        obligationId: UUID,
        contextActorId: UUID? = nil,
        contextName: String? = nil,
        role: String,
        obligationType: String,
        amount: Double? = nil,
        currency: String? = nil
    ) {
        self.obligationId = obligationId
        self.contextActorId = contextActorId
        self.contextName = contextName
        self.role = role
        self.obligationType = obligationType
        self.amount = amount
        self.currency = currency
    }

    public var id: UUID { obligationId }
    public var iOwe: Bool { role == "debtor" }
}
