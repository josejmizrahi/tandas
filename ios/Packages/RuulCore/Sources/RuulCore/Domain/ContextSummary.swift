import Foundation

/// Payload de `context_summary(p_context_actor_id)` — la fuente del
/// Context Home (F.4). Todas las listas defaultean a `[]`.
public struct ContextSummary: Sendable, Equatable {
    public let context: ActorRecord
    public let asOf: Date?
    public let membersCount: Int
    public let resourcesCount: Int
    public let pendingDecisions: Int
    public let openObligationsCount: Int
    public let members: [ContextMember]
    public let myPermissions: [String]
    public let resources: [SummaryResource]
    public let upcomingEvents: [SummaryEvent]
    public let openDecisions: [SummaryDecision]
    public let money: SummaryMoney
    public let activeRules: [SummaryRule]
    public let recentActivity: [SummaryActivity]
    /// F.2X.0 — Acciones canónicas a nivel contexto. El frontend renderiza la
    /// sección "⚡ Acciones rápidas" exclusivamente desde aquí (intent-first).
    public let availableActions: [AvailableAction]

    public init(
        context: ActorRecord,
        asOf: Date? = nil,
        membersCount: Int = 0,
        resourcesCount: Int = 0,
        pendingDecisions: Int = 0,
        openObligationsCount: Int = 0,
        members: [ContextMember] = [],
        myPermissions: [String] = [],
        resources: [SummaryResource] = [],
        upcomingEvents: [SummaryEvent] = [],
        openDecisions: [SummaryDecision] = [],
        money: SummaryMoney = SummaryMoney(openObligations: [], myBalance: 0),
        activeRules: [SummaryRule] = [],
        recentActivity: [SummaryActivity] = [],
        availableActions: [AvailableAction] = []
    ) {
        self.context = context
        self.asOf = asOf
        self.membersCount = membersCount
        self.resourcesCount = resourcesCount
        self.pendingDecisions = pendingDecisions
        self.openObligationsCount = openObligationsCount
        self.members = members
        self.myPermissions = myPermissions
        self.resources = resources
        self.upcomingEvents = upcomingEvents
        self.openDecisions = openDecisions
        self.money = money
        self.activeRules = activeRules
        self.recentActivity = recentActivity
        self.availableActions = availableActions
    }

    /// Resuelve el display name de un actor usando los miembros del contexto.
    /// `me` permite resolver "Tú" cuando el actor no está en members
    /// (contexto personal o alguien que ya salió del contexto).
    public func displayName(for actorId: UUID?, me: UUID? = nil) -> String {
        guard let actorId else { return "—" }
        if actorId == context.id { return context.displayName }
        if let member = members.first(where: { $0.actorId == actorId }) { return member.displayName }
        if actorId == me { return "Tú" }
        return "Alguien"
    }

    public func can(_ permission: String) -> Bool {
        // El contexto personal no tiene roles — el caller tiene autoridad total.
        context.actorKind == .person || myPermissions.contains(permission)
    }
}

extension ContextSummary: Decodable {
    enum CodingKeys: String, CodingKey {
        case context
        case asOf = "as_of"
        case membersCount = "members_count"
        case resourcesCount = "resources_count"
        case pendingDecisions = "pending_decisions"
        case openObligationsCount = "open_obligations"
        case members
        case myPermissions = "my_permissions"
        case resources
        case upcomingEvents = "upcoming_events"
        case openDecisions = "open_decisions"
        case money
        case activeRules = "active_rules"
        case recentActivity = "recent_activity"
        case availableActions = "available_actions"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.context = try c.decode(ActorRecord.self, forKey: .context)
        self.asOf = try c.decodeIfPresent(Date.self, forKey: .asOf)
        self.membersCount = try c.decodeIfPresent(Int.self, forKey: .membersCount) ?? 0
        self.resourcesCount = try c.decodeIfPresent(Int.self, forKey: .resourcesCount) ?? 0
        self.pendingDecisions = try c.decodeIfPresent(Int.self, forKey: .pendingDecisions) ?? 0
        self.openObligationsCount = try c.decodeIfPresent(Int.self, forKey: .openObligationsCount) ?? 0
        self.members = try c.decodeIfPresent([ContextMember].self, forKey: .members) ?? []
        self.myPermissions = try c.decodeIfPresent([String].self, forKey: .myPermissions) ?? []
        self.resources = try c.decodeIfPresent([SummaryResource].self, forKey: .resources) ?? []
        self.upcomingEvents = try c.decodeIfPresent([SummaryEvent].self, forKey: .upcomingEvents) ?? []
        self.openDecisions = try c.decodeIfPresent([SummaryDecision].self, forKey: .openDecisions) ?? []
        self.money = try c.decodeIfPresent(SummaryMoney.self, forKey: .money)
            ?? SummaryMoney(openObligations: [], myBalance: 0)
        self.activeRules = try c.decodeIfPresent([SummaryRule].self, forKey: .activeRules) ?? []
        self.recentActivity = try c.decodeIfPresent([SummaryActivity].self, forKey: .recentActivity) ?? []
        self.availableActions = try c.decodeIfPresent([AvailableAction].self, forKey: .availableActions) ?? []
    }
}

// MARK: - Secciones

/// Miembro del contexto (de `context_summary().members`). Incluye `active` Y
/// `invited` (R.5Z.fix.3 — backend mig 20260616060000 abrió el filter).
public struct ContextMember: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let actorId: UUID
    public let displayName: String
    public let membershipType: String?
    public let joinedAt: Date?
    public let roles: [String]
    /// R.5W — true cuando el miembro es un actor placeholder (creado por
    /// otro miembro porque la persona no usa la app). Default false para
    /// back-compat con descriptores que no mandan el campo.
    public let isPlaceholder: Bool
    /// R.5W — contacto opcional del placeholder (visible al member detail
    /// para que un admin pueda compartir el link de invitación).
    public let contactPhone: String?
    public let contactEmail: String?
    /// R.5Z.fix.3 — `'active'` o `'invited'`. Default `'active'` para
    /// back-compat con descriptores legacy que no mandan el campo (smokes,
    /// mocks, fixtures pre-2026-06-16).
    public let membershipStatus: String

    enum CodingKeys: String, CodingKey {
        case actorId = "actor_id"
        case displayName = "display_name"
        case membershipType = "membership_type"
        case joinedAt = "joined_at"
        case roles
        case isPlaceholder = "is_placeholder"
        case contactPhone = "contact_phone"
        case contactEmail = "contact_email"
        case membershipStatus = "membership_status"
    }

    public init(
        actorId: UUID,
        displayName: String,
        membershipType: String? = nil,
        joinedAt: Date? = nil,
        roles: [String] = [],
        isPlaceholder: Bool = false,
        contactPhone: String? = nil,
        contactEmail: String? = nil,
        membershipStatus: String = "active"
    ) {
        self.actorId = actorId
        self.displayName = displayName
        self.membershipType = membershipType
        self.joinedAt = joinedAt
        self.roles = roles
        self.isPlaceholder = isPlaceholder
        self.contactPhone = contactPhone
        self.contactEmail = contactEmail
        self.membershipStatus = membershipStatus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.actorId = try c.decode(UUID.self, forKey: .actorId)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.membershipType = try c.decodeIfPresent(String.self, forKey: .membershipType)
        self.joinedAt = try c.decodeIfPresent(Date.self, forKey: .joinedAt)
        self.roles = try c.decodeIfPresent([String].self, forKey: .roles) ?? []
        self.isPlaceholder = try c.decodeIfPresent(Bool.self, forKey: .isPlaceholder) ?? false
        self.contactPhone = try c.decodeIfPresent(String.self, forKey: .contactPhone)
        self.contactEmail = try c.decodeIfPresent(String.self, forKey: .contactEmail)
        self.membershipStatus = try c.decodeIfPresent(String.self, forKey: .membershipStatus) ?? "active"
    }

    public var id: UUID { actorId }
    public var isAdmin: Bool { roles.contains("admin") }
    public var isFounder: Bool { membershipType == "founder" }
    /// R.5Z.fix.3 — `true` si el miembro fue invitado y aún no aceptó.
    public var isInvited: Bool { membershipStatus == "invited" }
}

public struct SummaryResource: Codable, Sendable, Equatable, Identifiable {
    public let resourceId: UUID
    public let displayName: String
    public let resourceType: String
    public let estimatedValue: Double?
    public let currency: String?

    enum CodingKeys: String, CodingKey {
        case resourceId = "resource_id"
        case displayName = "display_name"
        case resourceType = "resource_type"
        case estimatedValue = "estimated_value"
        case currency
    }

    public init(
        resourceId: UUID,
        displayName: String,
        resourceType: String,
        estimatedValue: Double? = nil,
        currency: String? = nil
    ) {
        self.resourceId = resourceId
        self.displayName = displayName
        self.resourceType = resourceType
        self.estimatedValue = estimatedValue
        self.currency = currency
    }

    public var id: UUID { resourceId }
}

public struct SummaryEvent: Codable, Sendable, Equatable, Identifiable {
    public let eventId: UUID
    public let title: String
    public let eventType: String
    public let startsAt: Date?
    public let hostActorId: UUID?
    public let status: String

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case title
        case eventType = "event_type"
        case startsAt = "starts_at"
        case hostActorId = "host_actor_id"
        case status
    }

    public init(
        eventId: UUID,
        title: String,
        eventType: String,
        startsAt: Date? = nil,
        hostActorId: UUID? = nil,
        status: String = "scheduled"
    ) {
        self.eventId = eventId
        self.title = title
        self.eventType = eventType
        self.startsAt = startsAt
        self.hostActorId = hostActorId
        self.status = status
    }

    public var id: UUID { eventId }
}

public struct SummaryDecision: Codable, Sendable, Equatable, Identifiable {
    public let decisionId: UUID
    public let title: String
    public let decisionType: String
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case decisionId = "decision_id"
        case title
        case decisionType = "decision_type"
        case createdAt = "created_at"
    }

    public init(decisionId: UUID, title: String, decisionType: String, createdAt: Date? = nil) {
        self.decisionId = decisionId
        self.title = title
        self.decisionType = decisionType
        self.createdAt = createdAt
    }

    public var id: UUID { decisionId }
}

public struct SummaryMoney: Sendable, Equatable {
    public let openObligations: [SummaryObligation]
    /// Positivo = te deben; negativo = debes.
    public let myBalance: Double

    public init(openObligations: [SummaryObligation], myBalance: Double) {
        self.openObligations = openObligations
        self.myBalance = myBalance
    }
}

extension SummaryMoney: Codable {
    enum CodingKeys: String, CodingKey {
        case openObligations = "open_obligations"
        case myBalance = "my_balance"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.openObligations = try c.decodeIfPresent([SummaryObligation].self, forKey: .openObligations) ?? []
        self.myBalance = try c.decodeIfPresent(Double.self, forKey: .myBalance) ?? 0
    }
}

public struct SummaryObligation: Codable, Sendable, Equatable, Identifiable {
    public let obligationId: UUID
    public let debtorActorId: UUID
    public let creditorActorId: UUID
    public let obligationType: String
    public let amount: Double?
    public let currency: String?

    enum CodingKeys: String, CodingKey {
        case obligationId = "obligation_id"
        case debtorActorId = "debtor_actor_id"
        case creditorActorId = "creditor_actor_id"
        case obligationType = "obligation_type"
        case amount
        case currency
    }

    public init(
        obligationId: UUID,
        debtorActorId: UUID,
        creditorActorId: UUID,
        obligationType: String,
        amount: Double? = nil,
        currency: String? = nil
    ) {
        self.obligationId = obligationId
        self.debtorActorId = debtorActorId
        self.creditorActorId = creditorActorId
        self.obligationType = obligationType
        self.amount = amount
        self.currency = currency
    }

    public var id: UUID { obligationId }
}

public struct SummaryRule: Codable, Sendable, Equatable, Identifiable {
    public let ruleId: UUID
    public let title: String
    public let triggerEventType: String?

    enum CodingKeys: String, CodingKey {
        case ruleId = "rule_id"
        case title
        case triggerEventType = "trigger_event_type"
    }

    public init(ruleId: UUID, title: String, triggerEventType: String? = nil) {
        self.ruleId = ruleId
        self.title = title
        self.triggerEventType = triggerEventType
    }

    public var id: UUID { ruleId }
}

public struct SummaryActivity: Codable, Sendable, Equatable {
    public let eventType: String
    public let actorId: UUID?
    public let payload: JSONValue?
    public let occurredAt: Date?

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case actorId = "actor_id"
        case payload
        case occurredAt = "occurred_at"
    }

    public init(eventType: String, actorId: UUID? = nil, payload: JSONValue? = nil, occurredAt: Date? = nil) {
        self.eventType = eventType
        self.actorId = actorId
        self.payload = payload
        self.occurredAt = occurredAt
    }
}
