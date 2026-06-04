import Foundation

/// R.3A — Tipo de target de una suscripción.
public enum SubscriptionTargetType: String, Codable, Sendable, CaseIterable {
    case actor
    case context
    case resource
    case decision
    case event
    case obligation

    public var label: String {
        switch self {
        case .actor:      return "Persona"
        case .context:    return "Contexto"
        case .resource:   return "Recurso"
        case .decision:   return "Decisión"
        case .event:      return "Evento"
        case .obligation: return "Obligación"
        }
    }
}

/// R.3A — Tipo de suscripción. NO son followers ni likes.
public enum SubscriptionType: String, Codable, Sendable, CaseIterable {
    case watch
    case follow
    case stakeholder
    case audit
    case ownerInterest = "owner_interest"

    public var label: String {
        switch self {
        case .watch:         return "Vigilar"
        case .follow:        return "Seguir"
        case .stakeholder:   return "Parte interesada"
        case .audit:         return "Auditar"
        case .ownerInterest: return "Interés de dueño"
        }
    }

    public var rankWeight: Int {
        switch self {
        case .ownerInterest: return 100
        case .stakeholder:   return 80
        case .audit:         return 65
        case .watch:         return 50
        case .follow:        return 30
        }
    }
}

/// R.3A — fila de `subscriptions` (vía `list_my_subscriptions()`).
public struct Subscription: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let targetType: SubscriptionTargetType
    public let targetActorId: UUID?
    public let targetResourceId: UUID?
    public let targetDecisionId: UUID?
    public let targetEventId: UUID?
    public let targetObligationId: UUID?
    public let subscriptionType: SubscriptionType
    public let notes: String?
    public let createdAt: Date?
    public let targetDisplayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case targetType        = "target_type"
        case targetActorId     = "target_actor_id"
        case targetResourceId  = "target_resource_id"
        case targetDecisionId  = "target_decision_id"
        case targetEventId     = "target_event_id"
        case targetObligationId = "target_obligation_id"
        case subscriptionType  = "subscription_type"
        case notes
        case createdAt         = "created_at"
        case targetDisplayName = "target_display_name"
    }

    public init(
        id: UUID,
        targetType: SubscriptionTargetType,
        targetActorId: UUID? = nil,
        targetResourceId: UUID? = nil,
        targetDecisionId: UUID? = nil,
        targetEventId: UUID? = nil,
        targetObligationId: UUID? = nil,
        subscriptionType: SubscriptionType,
        notes: String? = nil,
        createdAt: Date? = nil,
        targetDisplayName: String? = nil
    ) {
        self.id = id
        self.targetType = targetType
        self.targetActorId = targetActorId
        self.targetResourceId = targetResourceId
        self.targetDecisionId = targetDecisionId
        self.targetEventId = targetEventId
        self.targetObligationId = targetObligationId
        self.subscriptionType = subscriptionType
        self.notes = notes
        self.createdAt = createdAt
        self.targetDisplayName = targetDisplayName
    }

    public var targetId: UUID? {
        switch targetType {
        case .actor, .context: return targetActorId
        case .resource:        return targetResourceId
        case .decision:        return targetDecisionId
        case .event:           return targetEventId
        case .obligation:      return targetObligationId
        }
    }
}

public struct SubscriptionList: Sendable, Equatable {
    public let subscriberActorId: UUID
    public let subscriptions: [Subscription]

    public init(subscriberActorId: UUID, subscriptions: [Subscription]) {
        self.subscriberActorId = subscriberActorId
        self.subscriptions = subscriptions
    }
}

extension SubscriptionList: Decodable {
    enum CodingKeys: String, CodingKey {
        case subscriberActorId = "subscriber_actor_id"
        case subscriptions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.subscriberActorId = try c.decode(UUID.self, forKey: .subscriberActorId)
        self.subscriptions = try c.decodeIfPresent([Subscription].self, forKey: .subscriptions) ?? []
    }
}

// MARK: - Activity feed

public enum FeedSource: String, Codable, Sendable {
    case subscription
    case ownership
    case membership

    public var label: String {
        switch self {
        case .subscription: return "Suscripción"
        case .ownership:    return "Dueño"
        case .membership:   return "Miembro"
        }
    }
}

public struct FeedItem: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let eventType: String
    public let actorId: UUID?
    public let contextActorId: UUID?
    public let subjectType: String?
    public let subjectId: UUID?
    public let payload: JSONValue?
    public let resourceId: UUID?
    public let decisionId: UUID?
    public let obligationId: UUID?
    public let occurredAt: Date?
    public let source: FeedSource
    public let subscriptionType: SubscriptionType?
    public let score: Int

    enum CodingKeys: String, CodingKey {
        case id
        case eventType        = "event_type"
        case actorId          = "actor_id"
        case contextActorId   = "context_actor_id"
        case subjectType      = "subject_type"
        case subjectId        = "subject_id"
        case payload
        case resourceId       = "resource_id"
        case decisionId       = "decision_id"
        case obligationId     = "obligation_id"
        case occurredAt       = "occurred_at"
        case source
        case subscriptionType = "subscription_type"
        case score
    }

    public init(
        id: UUID,
        eventType: String,
        actorId: UUID? = nil,
        contextActorId: UUID? = nil,
        subjectType: String? = nil,
        subjectId: UUID? = nil,
        payload: JSONValue? = nil,
        resourceId: UUID? = nil,
        decisionId: UUID? = nil,
        obligationId: UUID? = nil,
        occurredAt: Date? = nil,
        source: FeedSource,
        subscriptionType: SubscriptionType? = nil,
        score: Int
    ) {
        self.id = id
        self.eventType = eventType
        self.actorId = actorId
        self.contextActorId = contextActorId
        self.subjectType = subjectType
        self.subjectId = subjectId
        self.payload = payload
        self.resourceId = resourceId
        self.decisionId = decisionId
        self.obligationId = obligationId
        self.occurredAt = occurredAt
        self.source = source
        self.subscriptionType = subscriptionType
        self.score = score
    }

    public var asActivityEvent: ActivityEvent {
        ActivityEvent(
            id: id,
            eventType: eventType,
            actorId: actorId,
            subjectType: subjectType,
            subjectId: subjectId,
            payload: payload,
            resourceId: resourceId,
            decisionId: decisionId,
            obligationId: obligationId,
            occurredAt: occurredAt
        )
    }
}

public struct ActivityFeed: Sendable, Equatable {
    public let actorId: UUID
    public let limit: Int
    public let items: [FeedItem]

    public init(actorId: UUID, limit: Int, items: [FeedItem]) {
        self.actorId = actorId
        self.limit = limit
        self.items = items
    }
}

extension ActivityFeed: Decodable {
    enum CodingKeys: String, CodingKey {
        case actorId = "actor_id"
        case limit
        case feed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.actorId = try c.decode(UUID.self, forKey: .actorId)
        self.limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 50
        self.items = try c.decodeIfPresent([FeedItem].self, forKey: .feed) ?? []
    }
}
