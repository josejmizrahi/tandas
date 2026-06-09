import Foundation

// MARK: - R.5A.B.7 — Context Detail Descriptor
//
// Shape canónico devuelto por `context_detail_descriptor(p_context_actor_id)`.
// Une membership + my_permissions + roles + sections (filtradas) + widgets +
// actions (F.2X canonical) + metrics + 8 previews.
//
// iOS F.3 renderiza ContextDetailView con tabs desde aquí — el shape sustituye
// gradualmente a `context_summary` legacy.

public struct ContextRole: Codable, Sendable, Equatable, Identifiable {
    public let roleKey: String
    public let displayName: String
    public let description: String?
    public let memberCount: Int

    enum CodingKeys: String, CodingKey {
        case roleKey = "role_key"
        case displayName = "display_name"
        case description
        case memberCount = "member_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.roleKey = try c.decode(String.self, forKey: .roleKey)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? c.decode(String.self, forKey: .roleKey)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.memberCount = try c.decodeIfPresent(Int.self, forKey: .memberCount) ?? 0
    }

    public init(roleKey: String, displayName: String, description: String? = nil, memberCount: Int = 0) {
        self.roleKey = roleKey
        self.displayName = displayName
        self.description = description
        self.memberCount = memberCount
    }

    public var id: String { roleKey }
}

public struct ContextSection: Codable, Sendable, Equatable, Identifiable {
    public let sectionKey: String
    public let displayName: String
    public let icon: String?
    public let sortOrder: Int
    public let visible: Bool
    public let requiredPermission: String?
    public let visibleWhenStatus: [String]

    enum CodingKeys: String, CodingKey {
        case sectionKey = "section_key"
        case displayName = "display_name"
        case icon
        case sortOrder = "sort_order"
        case visible
        case requiredPermission = "required_permission"
        case visibleWhenStatus = "visible_when_status"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sectionKey = try c.decode(String.self, forKey: .sectionKey)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
        self.sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 100
        self.visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        self.requiredPermission = try c.decodeIfPresent(String.self, forKey: .requiredPermission)
        self.visibleWhenStatus = try c.decodeIfPresent([String].self, forKey: .visibleWhenStatus) ?? []
    }

    public init(
        sectionKey: String,
        displayName: String,
        icon: String? = nil,
        sortOrder: Int = 100,
        visible: Bool = true,
        requiredPermission: String? = nil,
        visibleWhenStatus: [String] = []
    ) {
        self.sectionKey = sectionKey
        self.displayName = displayName
        self.icon = icon
        self.sortOrder = sortOrder
        self.visible = visible
        self.requiredPermission = requiredPermission
        self.visibleWhenStatus = visibleWhenStatus
    }

    public var id: String { sectionKey }
}

public struct ContextWidget: Codable, Sendable, Equatable, Identifiable {
    public let widgetKey: String
    public let displayName: String
    public let icon: String?
    public let dataSourceKey: String?
    public let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case widgetKey = "widget_key"
        case displayName = "display_name"
        case icon
        case dataSourceKey = "data_source_key"
        case sortOrder = "sort_order"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.widgetKey = try c.decode(String.self, forKey: .widgetKey)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
        self.dataSourceKey = try c.decodeIfPresent(String.self, forKey: .dataSourceKey)
        self.sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 100
    }

    public init(
        widgetKey: String,
        displayName: String,
        icon: String? = nil,
        dataSourceKey: String? = nil,
        sortOrder: Int = 100
    ) {
        self.widgetKey = widgetKey
        self.displayName = displayName
        self.icon = icon
        self.dataSourceKey = dataSourceKey
        self.sortOrder = sortOrder
    }

    public var id: String { widgetKey }
}

public struct ContextMetrics: Codable, Sendable, Equatable {
    public let memberCount: Int
    public let resourceCountByClass: [String: Int]
    public let pendingDecisions: Int
    public let openObligations: Int
    public let balanceByCurrency: [String: Double]

    enum CodingKeys: String, CodingKey {
        case memberCount = "member_count"
        case resourceCountByClass = "resource_count_by_class"
        case pendingDecisions = "pending_decisions"
        case openObligations = "open_obligations"
        case balanceByCurrency = "balance_by_currency"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.memberCount = try c.decodeIfPresent(Int.self, forKey: .memberCount) ?? 0
        self.resourceCountByClass = try c.decodeIfPresent([String: Int].self, forKey: .resourceCountByClass) ?? [:]
        self.pendingDecisions = try c.decodeIfPresent(Int.self, forKey: .pendingDecisions) ?? 0
        self.openObligations = try c.decodeIfPresent(Int.self, forKey: .openObligations) ?? 0
        self.balanceByCurrency = try c.decodeIfPresent([String: Double].self, forKey: .balanceByCurrency) ?? [:]
    }

    public init(
        memberCount: Int = 0,
        resourceCountByClass: [String: Int] = [:],
        pendingDecisions: Int = 0,
        openObligations: Int = 0,
        balanceByCurrency: [String: Double] = [:]
    ) {
        self.memberCount = memberCount
        self.resourceCountByClass = resourceCountByClass
        self.pendingDecisions = pendingDecisions
        self.openObligations = openObligations
        self.balanceByCurrency = balanceByCurrency
    }
}

// MARK: - Previews

public struct ContextMemberPreview: Codable, Sendable, Equatable, Identifiable {
    public let actorId: UUID
    public let displayName: String
    public let membershipType: String
    public let joinedAt: Date?
    /// R.5W — true cuando el miembro es un placeholder actor (sin app).
    public let isPlaceholder: Bool

    enum CodingKeys: String, CodingKey {
        case actorId = "actor_id"
        case displayName = "display_name"
        case membershipType = "membership_type"
        case joinedAt = "joined_at"
        case isPlaceholder = "is_placeholder"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.actorId = try c.decode(UUID.self, forKey: .actorId)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Miembro"
        self.membershipType = try c.decodeIfPresent(String.self, forKey: .membershipType) ?? "member"
        self.joinedAt = try c.decodeIfPresent(Date.self, forKey: .joinedAt)
        self.isPlaceholder = try c.decodeIfPresent(Bool.self, forKey: .isPlaceholder) ?? false
    }

    public var id: UUID { actorId }
}

public struct ContextResourcePreview: Codable, Sendable, Equatable, Identifiable {
    public let resourceId: UUID
    public let displayName: String
    public let classKey: String?
    public let subtypeKey: String?
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case resourceId = "resource_id"
        case displayName = "display_name"
        case classKey = "class_key"
        case subtypeKey = "subtype_key"
        case status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resourceId = try c.decode(UUID.self, forKey: .resourceId)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.classKey = try c.decodeIfPresent(String.self, forKey: .classKey)
        self.subtypeKey = try c.decodeIfPresent(String.self, forKey: .subtypeKey)
        self.status = try c.decodeIfPresent(String.self, forKey: .status)
    }

    public var id: UUID { resourceId }
}

public struct ContextEventPreview: Codable, Sendable, Equatable, Identifiable {
    public let eventId: UUID
    public let title: String
    public let eventType: String?
    public let startsAt: Date?
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case title
        case eventType = "event_type"
        case startsAt = "starts_at"
        case status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.eventId = try c.decode(UUID.self, forKey: .eventId)
        self.title = try c.decode(String.self, forKey: .title)
        self.eventType = try c.decodeIfPresent(String.self, forKey: .eventType)
        self.startsAt = try c.decodeIfPresent(Date.self, forKey: .startsAt)
        self.status = try c.decodeIfPresent(String.self, forKey: .status)
    }

    public var id: UUID { eventId }
}

public struct ContextMoneyPreview: Codable, Sendable, Equatable {
    public let myBalance: Double?
    public let openSettlements: Int
    /// R.5A.B.7.1 — net balance del caller agrupado por currency (e.g. {"MXN": 250.0, "USD": -10.0}).
    public let myBalanceByCurrency: [String: Double]

    enum CodingKeys: String, CodingKey {
        case myBalance = "my_balance"
        case openSettlements = "open_settlements"
        case myBalanceByCurrency = "my_balance_by_currency"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.myBalance = try c.decodeIfPresent(Double.self, forKey: .myBalance)
        self.openSettlements = try c.decodeIfPresent(Int.self, forKey: .openSettlements) ?? 0
        self.myBalanceByCurrency = try c.decodeIfPresent([String: Double].self, forKey: .myBalanceByCurrency) ?? [:]
    }

    public init(myBalance: Double? = nil, openSettlements: Int = 0, myBalanceByCurrency: [String: Double] = [:]) {
        self.myBalance = myBalance
        self.openSettlements = openSettlements
        self.myBalanceByCurrency = myBalanceByCurrency
    }
}

/// R.5A.B.7.1 — subcontext entry del descriptor (collective/legal_entity con `contains` relationship).
public struct ContextChildPreview: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let actorKind: String
    public let actorSubtype: String?
    public let visibility: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case actorKind = "actor_kind"
        case actorSubtype = "actor_subtype"
        case visibility
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.actorKind = try c.decode(String.self, forKey: .actorKind)
        self.actorSubtype = try c.decodeIfPresent(String.self, forKey: .actorSubtype)
        self.visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
    }

    public init(id: UUID, displayName: String, actorKind: String, actorSubtype: String? = nil, visibility: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.actorKind = actorKind
        self.actorSubtype = actorSubtype
        self.visibility = visibility
    }
}

/// R.5A.B.7.1 — invite activo no expirado de `context_invites`.
public struct ContextInvitePreview: Codable, Sendable, Equatable, Identifiable {
    public let inviteId: UUID
    public let code: String
    public let maxUses: Int?
    public let usedCount: Int
    public let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case inviteId = "invite_id"
        case code
        case maxUses = "max_uses"
        case usedCount = "used_count"
        case expiresAt = "expires_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.inviteId = try c.decode(UUID.self, forKey: .inviteId)
        self.code = try c.decode(String.self, forKey: .code)
        self.maxUses = try c.decodeIfPresent(Int.self, forKey: .maxUses)
        self.usedCount = try c.decodeIfPresent(Int.self, forKey: .usedCount) ?? 0
        self.expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
    }

    public init(inviteId: UUID, code: String, maxUses: Int? = nil, usedCount: Int = 0, expiresAt: Date? = nil) {
        self.inviteId = inviteId
        self.code = code
        self.maxUses = maxUses
        self.usedCount = usedCount
        self.expiresAt = expiresAt
    }

    public var id: UUID { inviteId }
}

public struct ContextObligationPreview: Codable, Sendable, Equatable, Identifiable {
    public let obligationId: UUID
    public let kind: String?
    public let amount: Double?
    public let currency: String?
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case obligationId = "obligation_id"
        case kind
        case amount
        case currency
        case status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.obligationId = try c.decode(UUID.self, forKey: .obligationId)
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind)
        self.amount = try c.decodeIfPresent(Double.self, forKey: .amount)
        self.currency = try c.decodeIfPresent(String.self, forKey: .currency)
        self.status = try c.decodeIfPresent(String.self, forKey: .status)
    }

    public var id: UUID { obligationId }
}

public struct ContextDecisionPreview: Codable, Sendable, Equatable, Identifiable {
    public let decisionId: UUID
    public let title: String
    public let decisionType: String?
    public let status: String?
    public let closesAt: Date?

    enum CodingKeys: String, CodingKey {
        case decisionId = "decision_id"
        case title
        case decisionType = "decision_type"
        case status
        case closesAt = "closes_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.decisionId = try c.decode(UUID.self, forKey: .decisionId)
        self.title = try c.decode(String.self, forKey: .title)
        self.decisionType = try c.decodeIfPresent(String.self, forKey: .decisionType)
        self.status = try c.decodeIfPresent(String.self, forKey: .status)
        self.closesAt = try c.decodeIfPresent(Date.self, forKey: .closesAt)
    }

    public var id: UUID { decisionId }
}

public struct ContextDocumentPreview: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let documentType: String?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case documentType = "document_type"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.documentType = try c.decodeIfPresent(String.self, forKey: .documentType)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

// MARK: - ContextDetailDescriptor (R.5A.B.7)

public struct ContextDetailDescriptor: Decodable, Sendable, Equatable {
    /// Row de `actors` con is_context=true. Opaco (JSONValue) — iOS lee actor_subtype/visibility/metadata via subscript.
    public let context: JSONValue
    /// Row de actor_memberships del caller + key embebida `my_permissions:[]`. Opaco.
    public let membership: JSONValue
    public let roles: [ContextRole]
    public let permissions: [String]
    public let sections: [ContextSection]
    public let widgets: [ContextWidget]
    /// F.2X canonical (mismo shape que `context_available_actions`).
    public let actions: [AvailableAction]
    public let metrics: ContextMetrics
    public let membersPreview: [ContextMemberPreview]
    public let resourcesPreview: [ContextResourcePreview]
    public let eventsPreview: [ContextEventPreview]
    public let moneyPreview: ContextMoneyPreview
    public let obligationsPreview: [ContextObligationPreview]
    public let decisionsPreview: [ContextDecisionPreview]
    public let documentsPreview: [ContextDocumentPreview]
    public let activityPreview: [ActivityPreviewEvent]
    /// R.5A.B.7.1 — subcontextos via actor_relationships contains.
    public let childContextsPreview: [ContextChildPreview]
    /// R.5A.B.7.1 — invites activos no expirados con cupos.
    public let pendingInvitationsPreview: [ContextInvitePreview]
    /// R.5B.4 — counts agregados de conflictos (open/critical/total). Lista
    /// completa via `list_context_conflicts` cuando el user tap.
    public let conflicts: ContextConflictsSummary

    enum CodingKeys: String, CodingKey {
        case context
        case membership
        case roles
        case permissions
        case sections
        case widgets
        case actions
        case metrics
        case membersPreview = "members_preview"
        case resourcesPreview = "resources_preview"
        case eventsPreview = "events_preview"
        case moneyPreview = "money_preview"
        case obligationsPreview = "obligations_preview"
        case decisionsPreview = "decisions_preview"
        case documentsPreview = "documents_preview"
        case activityPreview = "activity_preview"
        case childContextsPreview = "child_contexts_preview"
        case pendingInvitationsPreview = "pending_invitations_preview"
        case conflicts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.context = try c.decodeIfPresent(JSONValue.self, forKey: .context) ?? .object([:])
        self.membership = try c.decodeIfPresent(JSONValue.self, forKey: .membership) ?? .object([:])
        self.roles = try c.decodeIfPresent([ContextRole].self, forKey: .roles) ?? []
        self.permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        self.sections = try c.decodeIfPresent([ContextSection].self, forKey: .sections) ?? []
        self.widgets = try c.decodeIfPresent([ContextWidget].self, forKey: .widgets) ?? []
        self.actions = try c.decodeIfPresent([AvailableAction].self, forKey: .actions) ?? []
        self.metrics = try c.decodeIfPresent(ContextMetrics.self, forKey: .metrics) ?? ContextMetrics()
        self.membersPreview = try c.decodeIfPresent([ContextMemberPreview].self, forKey: .membersPreview) ?? []
        self.resourcesPreview = try c.decodeIfPresent([ContextResourcePreview].self, forKey: .resourcesPreview) ?? []
        self.eventsPreview = try c.decodeIfPresent([ContextEventPreview].self, forKey: .eventsPreview) ?? []
        self.moneyPreview = try c.decodeIfPresent(ContextMoneyPreview.self, forKey: .moneyPreview) ?? ContextMoneyPreview()
        self.obligationsPreview = try c.decodeIfPresent([ContextObligationPreview].self, forKey: .obligationsPreview) ?? []
        self.decisionsPreview = try c.decodeIfPresent([ContextDecisionPreview].self, forKey: .decisionsPreview) ?? []
        self.documentsPreview = try c.decodeIfPresent([ContextDocumentPreview].self, forKey: .documentsPreview) ?? []
        self.activityPreview = try c.decodeIfPresent([ActivityPreviewEvent].self, forKey: .activityPreview) ?? []
        self.childContextsPreview = try c.decodeIfPresent([ContextChildPreview].self, forKey: .childContextsPreview) ?? []
        self.pendingInvitationsPreview = try c.decodeIfPresent([ContextInvitePreview].self, forKey: .pendingInvitationsPreview) ?? []
        self.conflicts = try c.decodeIfPresent(ContextConflictsSummary.self, forKey: .conflicts) ?? .empty
    }

    public init(
        context: JSONValue = .object([:]),
        membership: JSONValue = .object([:]),
        roles: [ContextRole] = [],
        permissions: [String] = [],
        sections: [ContextSection] = [],
        widgets: [ContextWidget] = [],
        actions: [AvailableAction] = [],
        metrics: ContextMetrics = ContextMetrics(),
        membersPreview: [ContextMemberPreview] = [],
        resourcesPreview: [ContextResourcePreview] = [],
        eventsPreview: [ContextEventPreview] = [],
        moneyPreview: ContextMoneyPreview = ContextMoneyPreview(),
        obligationsPreview: [ContextObligationPreview] = [],
        decisionsPreview: [ContextDecisionPreview] = [],
        documentsPreview: [ContextDocumentPreview] = [],
        activityPreview: [ActivityPreviewEvent] = [],
        childContextsPreview: [ContextChildPreview] = [],
        pendingInvitationsPreview: [ContextInvitePreview] = [],
        conflicts: ContextConflictsSummary = .empty
    ) {
        self.context = context
        self.membership = membership
        self.roles = roles
        self.permissions = permissions
        self.sections = sections
        self.widgets = widgets
        self.actions = actions
        self.metrics = metrics
        self.membersPreview = membersPreview
        self.resourcesPreview = resourcesPreview
        self.eventsPreview = eventsPreview
        self.moneyPreview = moneyPreview
        self.obligationsPreview = obligationsPreview
        self.decisionsPreview = decisionsPreview
        self.documentsPreview = documentsPreview
        self.activityPreview = activityPreview
        self.childContextsPreview = childContextsPreview
        self.pendingInvitationsPreview = pendingInvitationsPreview
        self.conflicts = conflicts
    }

    /// ¿El caller tiene este permission key?
    public func has(_ permission: String) -> Bool { permissions.contains(permission) }

    /// Sección filtrada por key (si está visible).
    public func section(_ key: String) -> ContextSection? {
        sections.first { $0.sectionKey == key && $0.visible }
    }

    /// `actor_subtype` extraído del row context (e.g. "family", "company", "trip").
    public var actorSubtype: String? { context["actor_subtype"]?.stringValue }

    /// Display name del context.
    public var contextDisplayName: String? { context["display_name"]?.stringValue }
}
