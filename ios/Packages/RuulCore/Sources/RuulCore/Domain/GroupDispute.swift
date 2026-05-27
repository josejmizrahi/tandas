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
