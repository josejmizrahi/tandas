import Foundation

/// Primitiva 14 (Resolución de conflictos). Mirrors `public.group_disputes`
/// 1:1 via `group_disputes_active(...)` (pre-joined with display names).
/// Foundation V1 exposes read + dispute-a-sanction; mediation/resolution/
/// escalation UI land in a later slice.
public enum DisputeStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case open
    case inReview     = "in_review"
    case mediation
    case resolved
    case dismissed
    case escalated
    case closed

    public var isOpen: Bool {
        switch self {
        case .open, .inReview, .mediation, .escalated: return true
        case .resolved, .dismissed, .closed: return false
        }
    }

    public var label: LocalizedStringResource {
        switch self {
        case .open:       return L10n.Disputes.statusOpen
        case .inReview:   return L10n.Disputes.statusInReview
        case .mediation:  return L10n.Disputes.statusMediation
        case .resolved:   return L10n.Disputes.statusResolved
        case .dismissed:  return L10n.Disputes.statusDismissed
        case .escalated:  return L10n.Disputes.statusEscalated
        case .closed:     return L10n.Disputes.statusClosed
        }
    }
}

public enum DisputeSubjectKind: String, Codable, CaseIterable, Sendable, Hashable {
    case sanction
    case rule
    case resource
    case member
    case other

    public var label: LocalizedStringResource {
        switch self {
        case .sanction: return L10n.Disputes.subjectSanction
        case .rule:     return L10n.Disputes.subjectRule
        case .resource: return L10n.Disputes.subjectResource
        case .member:   return L10n.Disputes.subjectMember
        case .other:    return L10n.Disputes.subjectOther
        }
    }

    public var systemImageName: String {
        switch self {
        case .sanction: return "exclamationmark.shield"
        case .rule:     return "list.bullet.rectangle"
        case .resource: return "square.stack.3d.up"
        case .member:   return "person.crop.circle"
        case .other:    return "questionmark.circle"
        }
    }
}

public enum DisputeResolutionMethod: String, Codable, CaseIterable, Sendable, Hashable {
    case conversation
    case mediation
    case vote
    case adminDecision = "admin_decision"
    case arbitration
    case separation
    case other
}

public struct GroupDispute: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID                              // dispute_id
    public let groupId: UUID
    public let openedByMembershipId: UUID?
    public let openedByDisplayName: String?
    public let respondentMembershipId: UUID?
    public let respondentDisplayName: String?
    public let subjectKind: DisputeSubjectKind
    public let subjectId: UUID?
    public let title: String
    public let description: String?
    public let status: DisputeStatus
    public let mediatorMembershipId: UUID?
    public let mediatorDisplayName: String?
    public let resolutionMethod: DisputeResolutionMethod?
    public let resolution: String?
    public let openedAt: Date?
    public let resolvedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id                       = "dispute_id"
        case groupId                  = "group_id"
        case openedByMembershipId     = "opened_by_membership_id"
        case openedByDisplayName      = "opened_by_display_name"
        case respondentMembershipId   = "respondent_membership_id"
        case respondentDisplayName    = "respondent_display_name"
        case subjectKind              = "subject_kind"
        case subjectId                = "subject_id"
        case title
        case description
        case status
        case mediatorMembershipId     = "mediator_membership_id"
        case mediatorDisplayName      = "mediator_display_name"
        case resolutionMethod         = "resolution_method"
        case resolution
        case openedAt                 = "opened_at"
        case resolvedAt               = "resolved_at"
    }

    public init(
        id: UUID,
        groupId: UUID,
        openedByMembershipId: UUID? = nil,
        openedByDisplayName: String? = nil,
        respondentMembershipId: UUID? = nil,
        respondentDisplayName: String? = nil,
        subjectKind: DisputeSubjectKind,
        subjectId: UUID? = nil,
        title: String,
        description: String? = nil,
        status: DisputeStatus = .open,
        mediatorMembershipId: UUID? = nil,
        mediatorDisplayName: String? = nil,
        resolutionMethod: DisputeResolutionMethod? = nil,
        resolution: String? = nil,
        openedAt: Date? = nil,
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.openedByMembershipId = openedByMembershipId
        self.openedByDisplayName = openedByDisplayName
        self.respondentMembershipId = respondentMembershipId
        self.respondentDisplayName = respondentDisplayName
        self.subjectKind = subjectKind
        self.subjectId = subjectId
        self.title = title
        self.description = description
        self.status = status
        self.mediatorMembershipId = mediatorMembershipId
        self.mediatorDisplayName = mediatorDisplayName
        self.resolutionMethod = resolutionMethod
        self.resolution = resolution
        self.openedAt = openedAt
        self.resolvedAt = resolvedAt
    }

    /// Tolerant decode: unknown enum values fall back to safe defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.openedByMembershipId = try c.decodeIfPresent(UUID.self, forKey: .openedByMembershipId)
        self.openedByDisplayName = try c.decodeIfPresent(String.self, forKey: .openedByDisplayName)
        self.respondentMembershipId = try c.decodeIfPresent(UUID.self, forKey: .respondentMembershipId)
        self.respondentDisplayName = try c.decodeIfPresent(String.self, forKey: .respondentDisplayName)
        let rawKind = try c.decode(String.self, forKey: .subjectKind)
        self.subjectKind = DisputeSubjectKind(rawValue: rawKind) ?? .other
        self.subjectId = try c.decodeIfPresent(UUID.self, forKey: .subjectId)
        self.title = try c.decode(String.self, forKey: .title)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        let rawStatus = try c.decode(String.self, forKey: .status)
        self.status = DisputeStatus(rawValue: rawStatus) ?? .open
        self.mediatorMembershipId = try c.decodeIfPresent(UUID.self, forKey: .mediatorMembershipId)
        self.mediatorDisplayName = try c.decodeIfPresent(String.self, forKey: .mediatorDisplayName)
        if let raw = try c.decodeIfPresent(String.self, forKey: .resolutionMethod) {
            self.resolutionMethod = DisputeResolutionMethod(rawValue: raw)
        } else {
            self.resolutionMethod = nil
        }
        self.resolution = try c.decodeIfPresent(String.self, forKey: .resolution)
        self.openedAt = try c.decodeIfPresent(Date.self, forKey: .openedAt)
        self.resolvedAt = try c.decodeIfPresent(Date.self, forKey: .resolvedAt)
    }
}

public extension GroupDispute {
    var isSanctionDispute: Bool { subjectKind == .sanction }
    var isInMediation: Bool { status == .mediation }
    var isEscalated: Bool { status == .escalated }
}

// MARK: - Detail + events (Primitiva 14, C2)

/// Wire row returned by `dispute_detail(p_dispute_id)`. Same scalar
/// shape as `GroupDispute` plus the escalated decision link + an
/// `event_count` hint so the list/detail UI can render the timeline
/// strip without first fetching the full events page.
public struct GroupDisputeDetail: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let openedByMembershipId: UUID?
    public let openedByDisplayName: String?
    public let respondentMembershipId: UUID?
    public let respondentDisplayName: String?
    public let mediatorMembershipId: UUID?
    public let mediatorDisplayName: String?
    public let subjectKind: DisputeSubjectKind
    public let subjectId: UUID?
    public let title: String
    public let description: String?
    public let status: DisputeStatus
    public let resolutionMethod: DisputeResolutionMethod?
    public let resolution: String?
    public let escalatedDecisionId: UUID?
    public let openedAt: Date?
    public let resolvedAt: Date?
    public let eventCount: Int

    enum CodingKeys: String, CodingKey {
        case id                       = "dispute_id"
        case groupId                  = "group_id"
        case openedByMembershipId     = "opened_by_membership_id"
        case openedByDisplayName      = "opened_by_display_name"
        case respondentMembershipId   = "respondent_membership_id"
        case respondentDisplayName    = "respondent_display_name"
        case mediatorMembershipId     = "mediator_membership_id"
        case mediatorDisplayName      = "mediator_display_name"
        case subjectKind              = "subject_kind"
        case subjectId                = "subject_id"
        case title
        case description
        case status
        case resolutionMethod         = "resolution_method"
        case resolution
        case escalatedDecisionId      = "escalated_decision_id"
        case openedAt                 = "opened_at"
        case resolvedAt               = "resolved_at"
        case eventCount               = "event_count"
    }

    public init(
        id: UUID,
        groupId: UUID,
        openedByMembershipId: UUID? = nil,
        openedByDisplayName: String? = nil,
        respondentMembershipId: UUID? = nil,
        respondentDisplayName: String? = nil,
        mediatorMembershipId: UUID? = nil,
        mediatorDisplayName: String? = nil,
        subjectKind: DisputeSubjectKind = .other,
        subjectId: UUID? = nil,
        title: String,
        description: String? = nil,
        status: DisputeStatus = .open,
        resolutionMethod: DisputeResolutionMethod? = nil,
        resolution: String? = nil,
        escalatedDecisionId: UUID? = nil,
        openedAt: Date? = nil,
        resolvedAt: Date? = nil,
        eventCount: Int = 0
    ) {
        self.id = id
        self.groupId = groupId
        self.openedByMembershipId = openedByMembershipId
        self.openedByDisplayName = openedByDisplayName
        self.respondentMembershipId = respondentMembershipId
        self.respondentDisplayName = respondentDisplayName
        self.mediatorMembershipId = mediatorMembershipId
        self.mediatorDisplayName = mediatorDisplayName
        self.subjectKind = subjectKind
        self.subjectId = subjectId
        self.title = title
        self.description = description
        self.status = status
        self.resolutionMethod = resolutionMethod
        self.resolution = resolution
        self.escalatedDecisionId = escalatedDecisionId
        self.openedAt = openedAt
        self.resolvedAt = resolvedAt
        self.eventCount = eventCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.openedByMembershipId = try c.decodeIfPresent(UUID.self, forKey: .openedByMembershipId)
        self.openedByDisplayName = try c.decodeIfPresent(String.self, forKey: .openedByDisplayName)
        self.respondentMembershipId = try c.decodeIfPresent(UUID.self, forKey: .respondentMembershipId)
        self.respondentDisplayName = try c.decodeIfPresent(String.self, forKey: .respondentDisplayName)
        self.mediatorMembershipId = try c.decodeIfPresent(UUID.self, forKey: .mediatorMembershipId)
        self.mediatorDisplayName = try c.decodeIfPresent(String.self, forKey: .mediatorDisplayName)
        let rawKind = try c.decodeIfPresent(String.self, forKey: .subjectKind) ?? "other"
        self.subjectKind = DisputeSubjectKind(rawValue: rawKind) ?? .other
        self.subjectId = try c.decodeIfPresent(UUID.self, forKey: .subjectId)
        self.title = try c.decode(String.self, forKey: .title)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        let rawStatus = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        self.status = DisputeStatus(rawValue: rawStatus) ?? .open
        if let raw = try c.decodeIfPresent(String.self, forKey: .resolutionMethod) {
            self.resolutionMethod = DisputeResolutionMethod(rawValue: raw)
        } else {
            self.resolutionMethod = nil
        }
        self.resolution = try c.decodeIfPresent(String.self, forKey: .resolution)
        self.escalatedDecisionId = try c.decodeIfPresent(UUID.self, forKey: .escalatedDecisionId)
        self.openedAt = try c.decodeIfPresent(Date.self, forKey: .openedAt)
        self.resolvedAt = try c.decodeIfPresent(Date.self, forKey: .resolvedAt)
        self.eventCount = try c.decodeIfPresent(Int.self, forKey: .eventCount) ?? 0
    }
}

/// Canonical event types the backend CHECK constraint accepts on
/// `group_dispute_events.event_type`. Unknown wire values fall back
/// to `.other`.
public enum DisputeEventType: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case comment
    case statusChange   = "status_change"
    case evidenceAdded  = "evidence_added"
    case mediationNote  = "mediation_note"
    case resolution
    case escalation
    case other

    public var id: String { rawValue }

    public var label: LocalizedStringResource {
        switch self {
        case .comment:        return L10n.Disputes.eventComment
        case .statusChange:   return L10n.Disputes.eventStatusChange
        case .evidenceAdded:  return L10n.Disputes.eventEvidenceAdded
        case .mediationNote:  return L10n.Disputes.eventMediationNote
        case .resolution:     return L10n.Disputes.eventResolution
        case .escalation:     return L10n.Disputes.eventEscalation
        case .other:          return L10n.Disputes.eventOther
        }
    }

    public var systemImageName: String {
        switch self {
        case .comment:       return "bubble.left"
        case .statusChange:  return "arrow.left.arrow.right"
        case .evidenceAdded: return "paperclip"
        case .mediationNote: return "person.line.dotted.person"
        case .resolution:    return "checkmark.seal"
        case .escalation:    return "arrow.up.forward.circle"
        case .other:         return "ellipsis.circle"
        }
    }

    /// Event types iOS surfaces in the "Agregar al hilo" sheet picker.
    /// `status_change` / `resolution` / `escalation` are written by
    /// backend actions and never selected by the user directly.
    public static let userSelectable: [DisputeEventType] = [
        .comment, .evidenceAdded, .mediationNote, .other
    ]
}

/// Wire row returned by `list_dispute_events(p_dispute_id, p_limit)`.
/// Append-only — order ASC by created_at so the timeline reads
/// top-to-bottom.
public struct GroupDisputeEvent: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let disputeId: UUID
    public let actorMembershipId: UUID?
    public let actorDisplayName: String?
    public let eventType: DisputeEventType
    public let body: String?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id                = "event_id"
        case disputeId         = "dispute_id"
        case actorMembershipId = "actor_membership_id"
        case actorDisplayName  = "actor_display_name"
        case eventType         = "event_type"
        case body
        case createdAt         = "created_at"
    }

    public init(
        id: UUID,
        disputeId: UUID,
        actorMembershipId: UUID? = nil,
        actorDisplayName: String? = nil,
        eventType: DisputeEventType,
        body: String? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.disputeId = disputeId
        self.actorMembershipId = actorMembershipId
        self.actorDisplayName = actorDisplayName
        self.eventType = eventType
        self.body = body
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.disputeId = try c.decode(UUID.self, forKey: .disputeId)
        self.actorMembershipId = try c.decodeIfPresent(UUID.self, forKey: .actorMembershipId)
        self.actorDisplayName = try c.decodeIfPresent(String.self, forKey: .actorDisplayName)
        let raw = try c.decodeIfPresent(String.self, forKey: .eventType) ?? "other"
        self.eventType = DisputeEventType(rawValue: raw) ?? .other
        self.body = try c.decodeIfPresent(String.self, forKey: .body)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

public extension DisputeResolutionMethod {
    var label: LocalizedStringResource {
        switch self {
        case .conversation:   return L10n.Disputes.resolutionConversation
        case .mediation:      return L10n.Disputes.resolutionMediation
        case .vote:           return L10n.Disputes.resolutionVote
        case .adminDecision:  return L10n.Disputes.resolutionAdminDecision
        case .arbitration:    return L10n.Disputes.resolutionArbitration
        case .separation:     return L10n.Disputes.resolutionSeparation
        case .other:          return L10n.Disputes.resolutionOther
        }
    }

    /// Methods iOS exposes in the resolve sheet picker.
    static let selectable: [DisputeResolutionMethod] = [
        .conversation, .mediation, .adminDecision, .vote, .arbitration, .separation, .other
    ]
}
