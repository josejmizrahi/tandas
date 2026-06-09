import Foundation

// MARK: - R.5A.B.6 — Resource Detail Descriptor
//
// Shape canónico devuelto por `resource_detail_descriptor(p_resource_id)`.
// Une class/subtype/effective_capabilities/rights/sections/widgets/actions/
// action_forms/state/metrics/relations/linked_documents/activity_preview.
//
// iOS F.1 renderiza ResourceDetailView v2 desde aquí — NO desde resource_type.

public struct ResourceClassRef: Codable, Sendable, Equatable {
    public let classKey: String
    public let displayName: String
    public let description: String?
    public let icon: String?

    enum CodingKeys: String, CodingKey {
        case classKey = "class_key"
        case displayName = "display_name"
        case description
        case icon
    }

    public init(classKey: String, displayName: String, description: String? = nil, icon: String? = nil) {
        self.classKey = classKey
        self.displayName = displayName
        self.description = description
        self.icon = icon
    }
}

public struct ResourceSubtypeRef: Codable, Sendable, Equatable {
    public let subtypeKey: String
    public let classKey: String
    public let displayName: String
    public let description: String?
    public let icon: String?

    enum CodingKeys: String, CodingKey {
        case subtypeKey = "subtype_key"
        case classKey = "class_key"
        case displayName = "display_name"
        case description
        case icon
    }

    public init(subtypeKey: String, classKey: String, displayName: String, description: String? = nil, icon: String? = nil) {
        self.subtypeKey = subtypeKey
        self.classKey = classKey
        self.displayName = displayName
        self.description = description
        self.icon = icon
    }
}

public struct ResourceSection: Codable, Sendable, Equatable, Identifiable {
    public let sectionKey: String
    public let displayName: String
    public let icon: String?
    public let sortOrder: Int
    public let visible: Bool
    public let requiredCapability: String?
    public let requiredRights: [String]
    public let visibleWhenStatus: [String]

    enum CodingKeys: String, CodingKey {
        case sectionKey = "section_key"
        case displayName = "display_name"
        case icon
        case sortOrder = "sort_order"
        case visible
        case requiredCapability = "required_capability"
        case requiredRights = "required_rights"
        case visibleWhenStatus = "visible_when_status"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sectionKey = try c.decode(String.self, forKey: .sectionKey)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
        self.sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 100
        self.visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        self.requiredCapability = try c.decodeIfPresent(String.self, forKey: .requiredCapability)
        self.requiredRights = try c.decodeIfPresent([String].self, forKey: .requiredRights) ?? []
        self.visibleWhenStatus = try c.decodeIfPresent([String].self, forKey: .visibleWhenStatus) ?? []
    }

    public init(
        sectionKey: String,
        displayName: String,
        icon: String? = nil,
        sortOrder: Int = 100,
        visible: Bool = true,
        requiredCapability: String? = nil,
        requiredRights: [String] = [],
        visibleWhenStatus: [String] = []
    ) {
        self.sectionKey = sectionKey
        self.displayName = displayName
        self.icon = icon
        self.sortOrder = sortOrder
        self.visible = visible
        self.requiredCapability = requiredCapability
        self.requiredRights = requiredRights
        self.visibleWhenStatus = visibleWhenStatus
    }

    public var id: String { sectionKey }
}

public struct ResourceWidget: Codable, Sendable, Equatable, Identifiable {
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

/// Acción canónica F.2X enriquecida por R.5A.B.6 con mode/template/form/danger flags.
public struct ResourceDescriptorAction: Codable, Sendable, Equatable, Identifiable {
    public let actionKey: String
    public let label: String
    public let section: String
    public let enabled: Bool
    public let reason: String?
    public let requiredRights: [String]
    public let requiredCapabilities: [String]
    /// "execute" | "request_decision"
    public let mode: String
    public let decisionTemplateKey: String?
    public let formSchemaPresent: Bool
    public let dangerous: Bool
    public let confirmationRequired: Bool

    enum CodingKeys: String, CodingKey {
        case actionKey = "action_key"
        case label
        case section
        case enabled
        case reason
        case requiredRights = "required_rights"
        case requiredCapabilities = "required_capabilities"
        case mode
        case decisionTemplateKey = "decision_template_key"
        case formSchemaPresent = "form_schema_present"
        case dangerous
        case confirmationRequired = "confirmation_required"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.actionKey = try c.decode(String.self, forKey: .actionKey)
        self.label = try c.decode(String.self, forKey: .label)
        self.section = try c.decode(String.self, forKey: .section)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
        self.requiredRights = try c.decodeIfPresent([String].self, forKey: .requiredRights) ?? []
        self.requiredCapabilities = try c.decodeIfPresent([String].self, forKey: .requiredCapabilities) ?? []
        self.mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "execute"
        self.decisionTemplateKey = try c.decodeIfPresent(String.self, forKey: .decisionTemplateKey)
        self.formSchemaPresent = try c.decodeIfPresent(Bool.self, forKey: .formSchemaPresent) ?? false
        self.dangerous = try c.decodeIfPresent(Bool.self, forKey: .dangerous) ?? false
        self.confirmationRequired = try c.decodeIfPresent(Bool.self, forKey: .confirmationRequired) ?? false
    }

    public init(
        actionKey: String,
        label: String,
        section: String,
        enabled: Bool = true,
        reason: String? = nil,
        requiredRights: [String] = [],
        requiredCapabilities: [String] = [],
        mode: String = "execute",
        decisionTemplateKey: String? = nil,
        formSchemaPresent: Bool = false,
        dangerous: Bool = false,
        confirmationRequired: Bool = false
    ) {
        self.actionKey = actionKey
        self.label = label
        self.section = section
        self.enabled = enabled
        self.reason = reason
        self.requiredRights = requiredRights
        self.requiredCapabilities = requiredCapabilities
        self.mode = mode
        self.decisionTemplateKey = decisionTemplateKey
        self.formSchemaPresent = formSchemaPresent
        self.dangerous = dangerous
        self.confirmationRequired = confirmationRequired
    }

    public var id: String { actionKey }
    public var isRequestDecision: Bool { mode == "request_decision" }
}

/// Forma de un formulario en `descriptor.action_forms[action_key]`.
/// `formSchema` y `defaultPayload` son opacos (JSONValue) — iOS F.2 los renderiza.
public struct ResourceActionForm: Codable, Sendable, Equatable {
    public let formSchema: JSONValue
    public let defaultPayload: JSONValue
    public let dangerous: Bool
    public let confirmationRequired: Bool

    enum CodingKeys: String, CodingKey {
        case formSchema = "form_schema"
        case defaultPayload = "default_payload"
        case dangerous
        case confirmationRequired = "confirmation_required"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.formSchema = try c.decodeIfPresent(JSONValue.self, forKey: .formSchema) ?? .object([:])
        self.defaultPayload = try c.decodeIfPresent(JSONValue.self, forKey: .defaultPayload) ?? .object([:])
        self.dangerous = try c.decodeIfPresent(Bool.self, forKey: .dangerous) ?? false
        self.confirmationRequired = try c.decodeIfPresent(Bool.self, forKey: .confirmationRequired) ?? false
    }

    public init(
        formSchema: JSONValue = .object([:]),
        defaultPayload: JSONValue = .object([:]),
        dangerous: Bool = false,
        confirmationRequired: Bool = false
    ) {
        self.formSchema = formSchema
        self.defaultPayload = defaultPayload
        self.dangerous = dangerous
        self.confirmationRequired = confirmationRequired
    }
}

public struct ResourceDescriptorState: Codable, Sendable, Equatable {
    public let status: String
    public let archived: Bool
    public let archivedAt: Date?
    public let lockedForGovernance: Bool
    public let openDecisionId: UUID?

    enum CodingKeys: String, CodingKey {
        case status
        case archived
        case archivedAt = "archived_at"
        case lockedForGovernance = "locked_for_governance"
        case openDecisionId = "open_decision_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "active"
        self.archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        self.archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        self.lockedForGovernance = try c.decodeIfPresent(Bool.self, forKey: .lockedForGovernance) ?? false
        self.openDecisionId = try c.decodeIfPresent(UUID.self, forKey: .openDecisionId)
    }

    public init(
        status: String = "active",
        archived: Bool = false,
        archivedAt: Date? = nil,
        lockedForGovernance: Bool = false,
        openDecisionId: UUID? = nil
    ) {
        self.status = status
        self.archived = archived
        self.archivedAt = archivedAt
        self.lockedForGovernance = lockedForGovernance
        self.openDecisionId = openDecisionId
    }
}

public struct ResourceMetrics: Codable, Sendable, Equatable {
    public let estimatedValue: Double?
    public let currency: String?
    public let balance: Double?
    public let lastMovementAt: Date?

    enum CodingKeys: String, CodingKey {
        case estimatedValue = "estimated_value"
        case currency
        case balance
        case lastMovementAt = "last_movement_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.estimatedValue = try c.decodeIfPresent(Double.self, forKey: .estimatedValue)
        self.currency = try c.decodeIfPresent(String.self, forKey: .currency)
        self.balance = try c.decodeIfPresent(Double.self, forKey: .balance)
        self.lastMovementAt = try c.decodeIfPresent(Date.self, forKey: .lastMovementAt)
    }

    public init(estimatedValue: Double? = nil, currency: String? = nil, balance: Double? = nil, lastMovementAt: Date? = nil) {
        self.estimatedValue = estimatedValue
        self.currency = currency
        self.balance = balance
        self.lastMovementAt = lastMovementAt
    }
}

// MARK: - Relations (R.5A.B.3)

/// Otro endpoint en una relación. Trae class/subtype para que iOS no requiera
/// otro round-trip.
public struct ResourceRelationOther: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let classKey: String?
    public let subtypeKey: String?
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case classKey = "class_key"
        case subtypeKey = "subtype_key"
        case status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.classKey = try c.decodeIfPresent(String.self, forKey: .classKey)
        self.subtypeKey = try c.decodeIfPresent(String.self, forKey: .subtypeKey)
        self.status = try c.decodeIfPresent(String.self, forKey: .status)
    }

    public init(id: UUID, displayName: String, classKey: String? = nil, subtypeKey: String? = nil, status: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.classKey = classKey
        self.subtypeKey = subtypeKey
        self.status = status
    }
}

public struct ResourceRelation: Codable, Sendable, Equatable, Identifiable {
    public let relationId: UUID
    /// "outbound" | "inbound"
    public let direction: String
    public let relationType: String
    public let otherResourceId: UUID
    public let other: ResourceRelationOther
    public let metadata: JSONValue
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case relationId = "relation_id"
        case direction
        case relationType = "relation_type"
        case otherResourceId = "other_resource_id"
        case other
        case metadata
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.relationId = try c.decode(UUID.self, forKey: .relationId)
        self.direction = try c.decode(String.self, forKey: .direction)
        self.relationType = try c.decode(String.self, forKey: .relationType)
        self.otherResourceId = try c.decode(UUID.self, forKey: .otherResourceId)
        self.other = try c.decode(ResourceRelationOther.self, forKey: .other)
        self.metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata) ?? .object([:])
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public var id: UUID { relationId }
    public var isOutbound: Bool { direction == "outbound" }
}

public struct ResourceRelationsBundle: Codable, Sendable, Equatable {
    public let resourceId: UUID?
    public let outbound: [ResourceRelation]
    public let inbound: [ResourceRelation]

    enum CodingKeys: String, CodingKey {
        case resourceId = "resource_id"
        case outbound
        case inbound
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resourceId = try c.decodeIfPresent(UUID.self, forKey: .resourceId)
        self.outbound = try c.decodeIfPresent([ResourceRelation].self, forKey: .outbound) ?? []
        self.inbound = try c.decodeIfPresent([ResourceRelation].self, forKey: .inbound) ?? []
    }

    public init(resourceId: UUID? = nil, outbound: [ResourceRelation] = [], inbound: [ResourceRelation] = []) {
        self.resourceId = resourceId
        self.outbound = outbound
        self.inbound = inbound
    }
}

// MARK: - Linked previews

public struct LinkedDocument: Codable, Sendable, Equatable, Identifiable {
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

public struct ActivityPreviewEvent: Codable, Sendable, Equatable, Identifiable {
    public let eventId: UUID
    public let eventType: String
    public let actorId: UUID?
    public let payload: JSONValue
    public let occurredAt: Date?

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case eventType = "event_type"
        case actorId = "actor_id"
        case payload
        case occurredAt = "occurred_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.eventId = try c.decode(UUID.self, forKey: .eventId)
        self.eventType = try c.decode(String.self, forKey: .eventType)
        self.actorId = try c.decodeIfPresent(UUID.self, forKey: .actorId)
        self.payload = try c.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .object([:])
        self.occurredAt = try c.decodeIfPresent(Date.self, forKey: .occurredAt)
    }

    public var id: UUID { eventId }
}

// MARK: - ResourceDetailDescriptor (R.5A.B.6)

public struct ResourceDetailDescriptor: Decodable, Sendable, Equatable {
    public let resource: Resource
    public let `class`: ResourceClassRef
    public let subtype: ResourceSubtypeRef
    public let effectiveCapabilities: [String]
    public let rights: [ResourceRight]
    public let sections: [ResourceSection]
    public let widgets: [ResourceWidget]
    public let actions: [ResourceDescriptorAction]
    public let actionForms: [String: ResourceActionForm]
    public let state: ResourceDescriptorState
    public let metrics: ResourceMetrics
    public let relations: ResourceRelationsBundle
    public let linkedEvents: [JSONValue]
    public let linkedDocuments: [LinkedDocument]
    public let linkedObligations: [JSONValue]
    public let linkedDecisions: [JSONValue]
    public let activityPreview: [ActivityPreviewEvent]
    /// R.5B.4 — conflicts abiertos del recurso (full list dedup'd).
    public let conflicts: ResourceConflictList

    enum CodingKeys: String, CodingKey {
        case resource
        case `class`
        case subtype
        case effectiveCapabilities = "effective_capabilities"
        case rights
        case sections
        case widgets
        case actions
        case actionForms = "action_forms"
        case state
        case metrics
        case relations
        case linkedEvents = "linked_events"
        case linkedDocuments = "linked_documents"
        case linkedObligations = "linked_obligations"
        case linkedDecisions = "linked_decisions"
        case activityPreview = "activity_preview"
        case conflicts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resource = try c.decode(Resource.self, forKey: .resource)
        // 2026-06-08 defensive — antes class/subtype eran hard-required y el
        // descriptor entero fallaba a decodificar cuando el backend devolvía
        // null (recurso sin fila en catálogos resource_class_catalog /
        // resource_subtype_catalog). Founder reportó "algo salió mal" abriendo
        // un recurso real. Ahora caen a un fallback genérico derivado del
        // resource_type legacy.
        let resourceTypeLegacy = self.resource.resourceType
        self.class = (try c.decodeIfPresent(ResourceClassRef.self, forKey: .class))
            ?? ResourceClassRef(
                classKey: "generic",
                displayName: ResourceType(rawValue: resourceTypeLegacy)?.label ?? "Recurso"
            )
        self.subtype = (try c.decodeIfPresent(ResourceSubtypeRef.self, forKey: .subtype))
            ?? ResourceSubtypeRef(
                subtypeKey: "generic_\(resourceTypeLegacy)",
                classKey: self.class.classKey,
                displayName: self.class.displayName
            )
        self.effectiveCapabilities = try c.decodeIfPresent([String].self, forKey: .effectiveCapabilities) ?? []
        self.rights = try c.decodeIfPresent([ResourceRight].self, forKey: .rights) ?? []
        self.sections = try c.decodeIfPresent([ResourceSection].self, forKey: .sections) ?? []
        self.widgets = try c.decodeIfPresent([ResourceWidget].self, forKey: .widgets) ?? []
        self.actions = try c.decodeIfPresent([ResourceDescriptorAction].self, forKey: .actions) ?? []
        self.actionForms = try c.decodeIfPresent([String: ResourceActionForm].self, forKey: .actionForms) ?? [:]
        self.state = try c.decodeIfPresent(ResourceDescriptorState.self, forKey: .state) ?? ResourceDescriptorState()
        self.metrics = try c.decodeIfPresent(ResourceMetrics.self, forKey: .metrics) ?? ResourceMetrics()
        self.relations = try c.decodeIfPresent(ResourceRelationsBundle.self, forKey: .relations) ?? ResourceRelationsBundle()
        self.linkedEvents = try c.decodeIfPresent([JSONValue].self, forKey: .linkedEvents) ?? []
        self.linkedDocuments = try c.decodeIfPresent([LinkedDocument].self, forKey: .linkedDocuments) ?? []
        self.linkedObligations = try c.decodeIfPresent([JSONValue].self, forKey: .linkedObligations) ?? []
        self.linkedDecisions = try c.decodeIfPresent([JSONValue].self, forKey: .linkedDecisions) ?? []
        self.activityPreview = try c.decodeIfPresent([ActivityPreviewEvent].self, forKey: .activityPreview) ?? []
        self.conflicts = try c.decodeIfPresent(ResourceConflictList.self, forKey: .conflicts) ?? .empty
    }

    public init(
        resource: Resource,
        `class`: ResourceClassRef,
        subtype: ResourceSubtypeRef,
        effectiveCapabilities: [String] = [],
        rights: [ResourceRight] = [],
        sections: [ResourceSection] = [],
        widgets: [ResourceWidget] = [],
        actions: [ResourceDescriptorAction] = [],
        actionForms: [String: ResourceActionForm] = [:],
        state: ResourceDescriptorState = ResourceDescriptorState(),
        metrics: ResourceMetrics = ResourceMetrics(),
        relations: ResourceRelationsBundle = ResourceRelationsBundle(),
        linkedEvents: [JSONValue] = [],
        linkedDocuments: [LinkedDocument] = [],
        linkedObligations: [JSONValue] = [],
        linkedDecisions: [JSONValue] = [],
        activityPreview: [ActivityPreviewEvent] = [],
        conflicts: ResourceConflictList = .empty
    ) {
        self.resource = resource
        self.class = `class`
        self.subtype = subtype
        self.effectiveCapabilities = effectiveCapabilities
        self.rights = rights
        self.sections = sections
        self.widgets = widgets
        self.actions = actions
        self.actionForms = actionForms
        self.state = state
        self.metrics = metrics
        self.relations = relations
        self.linkedEvents = linkedEvents
        self.linkedDocuments = linkedDocuments
        self.linkedObligations = linkedObligations
        self.linkedDecisions = linkedDecisions
        self.activityPreview = activityPreview
        self.conflicts = conflicts
    }

    /// ¿La capability efectiva del recurso incluye este key?
    public func has(_ capability: String) -> Bool {
        effectiveCapabilities.contains(capability)
    }

    /// Sección filtrada por section_key (si está visible).
    public func section(_ key: String) -> ResourceSection? {
        sections.first { $0.sectionKey == key && $0.visible }
    }

    /// Acción enriquecida por action_key.
    public func action(_ key: String) -> ResourceDescriptorAction? {
        actions.first { $0.actionKey == key }
    }

    /// Form schema para una action key.
    public func form(for actionKey: String) -> ResourceActionForm? {
        actionForms[actionKey]
    }
}

// MARK: - execute_resource_action result (R.5A.B.8)

public struct ExecuteResourceActionResult: Decodable, Sendable, Equatable {
    public let actionKey: String
    /// "execute" | "request_decision"
    public let mode: String
    public let delegatedToRpc: String?
    public let result: JSONValue
    public let decisionId: UUID?
    public let activityEventId: UUID?
    public let idempotentHit: Bool

    enum CodingKeys: String, CodingKey {
        case actionKey = "action_key"
        case mode
        case delegatedToRpc = "delegated_to_rpc"
        case result
        case decisionId = "decision_id"
        case activityEventId = "activity_event_id"
        case idempotentHit = "idempotent_hit"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.actionKey = try c.decode(String.self, forKey: .actionKey)
        self.mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "execute"
        self.delegatedToRpc = try c.decodeIfPresent(String.self, forKey: .delegatedToRpc)
        self.result = try c.decodeIfPresent(JSONValue.self, forKey: .result) ?? .null
        self.decisionId = try c.decodeIfPresent(UUID.self, forKey: .decisionId)
        self.activityEventId = try c.decodeIfPresent(UUID.self, forKey: .activityEventId)
        self.idempotentHit = try c.decodeIfPresent(Bool.self, forKey: .idempotentHit) ?? false
    }

    public var isRequestDecision: Bool { mode == "request_decision" }
}
