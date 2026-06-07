import Foundation

// MARK: - R.5B — Resource Conflict Model
//
// Shapes canónicos devueltos por las 5 RPCs de R.5B:
//   - `list_resource_conflicts(p_resource_id, p_include_resolved)` → ResourceConflictList
//   - `list_context_conflicts(p_context_actor_id, p_include_resolved)` → ContextConflictList
//   - `resolve_resource_conflict(p_conflict_id, p_resolution_kind, p_winner_actor_id?, p_payload?)` → ResolveResourceConflictResult
//   - `detect_resource_conflicts(p_resource_id)` → DetectConflictsResult
//   - `detect_context_conflicts(p_context_actor_id)` → DetectContextConflictsResult
//
// Y la summary embebida en los descriptors (B.6/B.7) post-R.5B.4:
//   - `resource_detail_descriptor.conflicts` = ResourceConflictList completo
//   - `context_detail_descriptor.conflicts`  = ContextConflictsSummary (counts only)

/// Un conflicto individual (ya deduplicado por el list RPC).
///
/// `payload` y `resolutionPayload` son opacos — la UI los lee con subscript
/// para campos específicos (reservation_a_id, recommended_winner_actor_id, etc.).
public struct ResourceConflict: Decodable, Sendable, Equatable, Identifiable {
    public let conflictId: UUID
    /// Catálogo R.5B.0: reservation_overlap, double_booking, blackout_violation, …
    public let conflictType: String
    public let conflictTypeDisplay: String?
    /// reservations | rights | documents | money | maintenance | rules | governance | generic
    public let category: String?
    /// info | warning | critical
    public let severity: String
    /// open | acknowledged | resolved | dismissed
    public let status: String
    public let detectedAt: Date?
    public let detectedByActorId: UUID?
    public let contextActorId: UUID
    public let resourceId: UUID
    /// reservation_pair | reservation | reservation_conflict | manual | rule_evaluation | …
    public let sourceType: String
    public let sourceId: UUID?
    public let payload: JSONValue
    /// Acción canónica que la UI puede presentar (resolve_resource_conflict / escalate_to_decision / …).
    public let recommendedActionKey: String?
    public let sourceDecisionId: UUID?
    public let resolvedAt: Date?
    public let resolvedByActorId: UUID?
    public let resolutionPayload: JSONValue

    enum CodingKeys: String, CodingKey {
        case conflictId            = "conflict_id"
        case conflictType          = "conflict_type"
        case conflictTypeDisplay   = "conflict_type_display"
        case category
        case severity
        case status
        case detectedAt            = "detected_at"
        case detectedByActorId     = "detected_by_actor_id"
        case contextActorId        = "context_actor_id"
        case resourceId            = "resource_id"
        case sourceType            = "source_type"
        case sourceId              = "source_id"
        case payload
        case recommendedActionKey  = "recommended_action_key"
        case sourceDecisionId      = "source_decision_id"
        case resolvedAt            = "resolved_at"
        case resolvedByActorId     = "resolved_by_actor_id"
        case resolutionPayload     = "resolution_payload"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.conflictId          = try c.decode(UUID.self, forKey: .conflictId)
        self.conflictType        = try c.decode(String.self, forKey: .conflictType)
        self.conflictTypeDisplay = try c.decodeIfPresent(String.self, forKey: .conflictTypeDisplay)
        self.category            = try c.decodeIfPresent(String.self, forKey: .category)
        self.severity            = try c.decodeIfPresent(String.self, forKey: .severity) ?? "warning"
        self.status              = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        self.detectedAt          = try c.decodeIfPresent(Date.self, forKey: .detectedAt)
        self.detectedByActorId   = try c.decodeIfPresent(UUID.self, forKey: .detectedByActorId)
        self.contextActorId      = try c.decode(UUID.self, forKey: .contextActorId)
        self.resourceId          = try c.decode(UUID.self, forKey: .resourceId)
        self.sourceType          = try c.decodeIfPresent(String.self, forKey: .sourceType) ?? "system"
        self.sourceId            = try c.decodeIfPresent(UUID.self, forKey: .sourceId)
        self.payload             = try c.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .object([:])
        self.recommendedActionKey = try c.decodeIfPresent(String.self, forKey: .recommendedActionKey)
        self.sourceDecisionId    = try c.decodeIfPresent(UUID.self, forKey: .sourceDecisionId)
        self.resolvedAt          = try c.decodeIfPresent(Date.self, forKey: .resolvedAt)
        self.resolvedByActorId   = try c.decodeIfPresent(UUID.self, forKey: .resolvedByActorId)
        self.resolutionPayload   = try c.decodeIfPresent(JSONValue.self, forKey: .resolutionPayload) ?? .null
    }

    public init(
        conflictId: UUID,
        conflictType: String,
        conflictTypeDisplay: String? = nil,
        category: String? = nil,
        severity: String = "warning",
        status: String = "open",
        detectedAt: Date? = nil,
        detectedByActorId: UUID? = nil,
        contextActorId: UUID,
        resourceId: UUID,
        sourceType: String = "system",
        sourceId: UUID? = nil,
        payload: JSONValue = .object([:]),
        recommendedActionKey: String? = nil,
        sourceDecisionId: UUID? = nil,
        resolvedAt: Date? = nil,
        resolvedByActorId: UUID? = nil,
        resolutionPayload: JSONValue = .null
    ) {
        self.conflictId = conflictId
        self.conflictType = conflictType
        self.conflictTypeDisplay = conflictTypeDisplay
        self.category = category
        self.severity = severity
        self.status = status
        self.detectedAt = detectedAt
        self.detectedByActorId = detectedByActorId
        self.contextActorId = contextActorId
        self.resourceId = resourceId
        self.sourceType = sourceType
        self.sourceId = sourceId
        self.payload = payload
        self.recommendedActionKey = recommendedActionKey
        self.sourceDecisionId = sourceDecisionId
        self.resolvedAt = resolvedAt
        self.resolvedByActorId = resolvedByActorId
        self.resolutionPayload = resolutionPayload
    }

    public var id: UUID { conflictId }
    public var isOpen: Bool { status == "open" }
    public var isCritical: Bool { severity == "critical" }
    /// Mirror legacy de reservation_conflicts (writes-through el legacy table al resolver).
    public var isLegacyMirror: Bool { sourceType == "reservation_conflict" }
}

/// Shape de `list_resource_conflicts` y de `descriptor.conflicts` (resource side).
public struct ResourceConflictList: Decodable, Sendable, Equatable {
    public let resourceId: UUID?
    public let openCount: Int
    public let totalCount: Int
    public let items: [ResourceConflict]

    enum CodingKeys: String, CodingKey {
        case resourceId = "resource_id"
        case openCount  = "open_count"
        case totalCount = "total_count"
        case items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resourceId = try c.decodeIfPresent(UUID.self, forKey: .resourceId)
        self.openCount  = try c.decodeIfPresent(Int.self, forKey: .openCount) ?? 0
        self.totalCount = try c.decodeIfPresent(Int.self, forKey: .totalCount) ?? 0
        self.items      = try c.decodeIfPresent([ResourceConflict].self, forKey: .items) ?? []
    }

    public init(resourceId: UUID? = nil, openCount: Int = 0, totalCount: Int = 0, items: [ResourceConflict] = []) {
        self.resourceId = resourceId
        self.openCount = openCount
        self.totalCount = totalCount
        self.items = items
    }

    public static var empty: ResourceConflictList { .init() }
}

/// Shape de `list_context_conflicts` (items livianos con `resource_display_name`).
public struct ContextConflictItem: Decodable, Sendable, Equatable, Identifiable {
    public let conflictId: UUID
    public let conflictType: String
    public let conflictTypeDisplay: String?
    public let severity: String
    public let status: String
    public let detectedAt: Date?
    public let resourceId: UUID
    public let resourceDisplayName: String?
    public let sourceType: String?
    public let recommendedActionKey: String?
    public let sourceDecisionId: UUID?

    enum CodingKeys: String, CodingKey {
        case conflictId           = "conflict_id"
        case conflictType         = "conflict_type"
        case conflictTypeDisplay  = "conflict_type_display"
        case severity
        case status
        case detectedAt           = "detected_at"
        case resourceId           = "resource_id"
        case resourceDisplayName  = "resource_display_name"
        case sourceType           = "source_type"
        case recommendedActionKey = "recommended_action_key"
        case sourceDecisionId     = "source_decision_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.conflictId           = try c.decode(UUID.self, forKey: .conflictId)
        self.conflictType         = try c.decode(String.self, forKey: .conflictType)
        self.conflictTypeDisplay  = try c.decodeIfPresent(String.self, forKey: .conflictTypeDisplay)
        self.severity             = try c.decodeIfPresent(String.self, forKey: .severity) ?? "warning"
        self.status               = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        self.detectedAt           = try c.decodeIfPresent(Date.self, forKey: .detectedAt)
        self.resourceId           = try c.decode(UUID.self, forKey: .resourceId)
        self.resourceDisplayName  = try c.decodeIfPresent(String.self, forKey: .resourceDisplayName)
        self.sourceType           = try c.decodeIfPresent(String.self, forKey: .sourceType)
        self.recommendedActionKey = try c.decodeIfPresent(String.self, forKey: .recommendedActionKey)
        self.sourceDecisionId     = try c.decodeIfPresent(UUID.self, forKey: .sourceDecisionId)
    }

    public init(
        conflictId: UUID, conflictType: String, conflictTypeDisplay: String? = nil,
        severity: String = "warning", status: String = "open", detectedAt: Date? = nil,
        resourceId: UUID, resourceDisplayName: String? = nil,
        sourceType: String? = nil, recommendedActionKey: String? = nil,
        sourceDecisionId: UUID? = nil
    ) {
        self.conflictId = conflictId
        self.conflictType = conflictType
        self.conflictTypeDisplay = conflictTypeDisplay
        self.severity = severity
        self.status = status
        self.detectedAt = detectedAt
        self.resourceId = resourceId
        self.resourceDisplayName = resourceDisplayName
        self.sourceType = sourceType
        self.recommendedActionKey = recommendedActionKey
        self.sourceDecisionId = sourceDecisionId
    }

    public var id: UUID { conflictId }
    public var isCritical: Bool { severity == "critical" }
}

/// Shape de `list_context_conflicts` (lista enriquecida con resource name).
public struct ContextConflictList: Decodable, Sendable, Equatable {
    public let contextActorId: UUID?
    public let openCount: Int
    public let totalCount: Int
    public let items: [ContextConflictItem]

    enum CodingKeys: String, CodingKey {
        case contextActorId = "context_actor_id"
        case openCount      = "open_count"
        case totalCount     = "total_count"
        case items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.contextActorId = try c.decodeIfPresent(UUID.self, forKey: .contextActorId)
        self.openCount      = try c.decodeIfPresent(Int.self, forKey: .openCount) ?? 0
        self.totalCount     = try c.decodeIfPresent(Int.self, forKey: .totalCount) ?? 0
        self.items          = try c.decodeIfPresent([ContextConflictItem].self, forKey: .items) ?? []
    }

    public init(contextActorId: UUID? = nil, openCount: Int = 0, totalCount: Int = 0, items: [ContextConflictItem] = []) {
        self.contextActorId = contextActorId
        self.openCount = openCount
        self.totalCount = totalCount
        self.items = items
    }

    public static var empty: ContextConflictList { .init() }
}

/// Counts-only embedded en `context_detail_descriptor.conflicts` (R.5B.4).
/// La lista completa viene de `list_context_conflicts` cuando el user tap.
public struct ContextConflictsSummary: Decodable, Sendable, Equatable {
    public let contextActorId: UUID?
    public let openCount: Int
    public let criticalCount: Int
    public let totalCount: Int

    enum CodingKeys: String, CodingKey {
        case contextActorId = "context_actor_id"
        case openCount      = "open_count"
        case criticalCount  = "critical_count"
        case totalCount     = "total_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.contextActorId = try c.decodeIfPresent(UUID.self, forKey: .contextActorId)
        self.openCount      = try c.decodeIfPresent(Int.self, forKey: .openCount) ?? 0
        self.criticalCount  = try c.decodeIfPresent(Int.self, forKey: .criticalCount) ?? 0
        self.totalCount     = try c.decodeIfPresent(Int.self, forKey: .totalCount) ?? 0
    }

    public init(contextActorId: UUID? = nil, openCount: Int = 0, criticalCount: Int = 0, totalCount: Int = 0) {
        self.contextActorId = contextActorId
        self.openCount = openCount
        self.criticalCount = criticalCount
        self.totalCount = totalCount
    }

    public static var empty: ContextConflictsSummary { .init() }
    public var hasOpenConflicts: Bool { openCount > 0 }
}

// MARK: - resolve_resource_conflict

/// 3 kinds canónicos del backend R.5B.3.
public enum ResolveResourceConflictKind: String, Sendable, Codable, CaseIterable {
    case manualResolution = "manual_resolution"
    case escalate         = "escalate"
    case dismiss          = "dismiss"
}

/// Shape de `resolve_resource_conflict(...)` returns jsonb.
public struct ResolveResourceConflictResult: Decodable, Sendable, Equatable {
    public let conflictId: UUID
    /// "dismiss" | "escalate" | "manual_resolution" — devuelto cuando NO es no_op.
    public let resolutionKind: String?
    /// open | acknowledged | resolved | dismissed
    public let status: String?
    public let decisionId: UUID?
    public let templateKey: String?
    public let winnerActorId: UUID?
    /// True cuando el conflict ya no estaba open (RPC devuelve {no_op:true, status}).
    public let noOp: Bool

    enum CodingKeys: String, CodingKey {
        case conflictId     = "conflict_id"
        case resolutionKind = "resolution_kind"
        case status
        case decisionId     = "decision_id"
        case templateKey    = "template_key"
        case winnerActorId  = "winner_actor_id"
        case noOp           = "no_op"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.conflictId     = try c.decode(UUID.self, forKey: .conflictId)
        self.resolutionKind = try c.decodeIfPresent(String.self, forKey: .resolutionKind)
        self.status         = try c.decodeIfPresent(String.self, forKey: .status)
        self.decisionId     = try c.decodeIfPresent(UUID.self, forKey: .decisionId)
        self.templateKey    = try c.decodeIfPresent(String.self, forKey: .templateKey)
        self.winnerActorId  = try c.decodeIfPresent(UUID.self, forKey: .winnerActorId)
        self.noOp           = try c.decodeIfPresent(Bool.self, forKey: .noOp) ?? false
    }
}

// MARK: - detect_* helpers

public struct DetectResourceConflictsResult: Decodable, Sendable, Equatable {
    public let resourceId: UUID?
    public let detectedNewCount: Int
    public let dismissedStaleCount: Int
    public let openTotal: Int

    enum CodingKeys: String, CodingKey {
        case resourceId         = "resource_id"
        case detectedNewCount   = "detected_new_count"
        case dismissedStaleCount = "dismissed_stale_count"
        case openTotal          = "open_total"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resourceId          = try c.decodeIfPresent(UUID.self, forKey: .resourceId)
        self.detectedNewCount    = try c.decodeIfPresent(Int.self, forKey: .detectedNewCount) ?? 0
        self.dismissedStaleCount = try c.decodeIfPresent(Int.self, forKey: .dismissedStaleCount) ?? 0
        self.openTotal           = try c.decodeIfPresent(Int.self, forKey: .openTotal) ?? 0
    }
}

public struct DetectContextConflictsResult: Decodable, Sendable, Equatable {
    public let contextActorId: UUID?
    public let resourcesScanned: Int
    public let detectedNewCount: Int
    public let dismissedStaleCount: Int
    public let openConflictsTotal: Int

    enum CodingKeys: String, CodingKey {
        case contextActorId      = "context_actor_id"
        case resourcesScanned    = "resources_scanned"
        case detectedNewCount    = "detected_new_count"
        case dismissedStaleCount = "dismissed_stale_count"
        case openConflictsTotal  = "open_conflicts_total"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.contextActorId      = try c.decodeIfPresent(UUID.self, forKey: .contextActorId)
        self.resourcesScanned    = try c.decodeIfPresent(Int.self, forKey: .resourcesScanned) ?? 0
        self.detectedNewCount    = try c.decodeIfPresent(Int.self, forKey: .detectedNewCount) ?? 0
        self.dismissedStaleCount = try c.decodeIfPresent(Int.self, forKey: .dismissedStaleCount) ?? 0
        self.openConflictsTotal  = try c.decodeIfPresent(Int.self, forKey: .openConflictsTotal) ?? 0
    }
}
