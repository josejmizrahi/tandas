import Foundation

/// One row in the unified inbox queue. The InboxView (Sprint 1c) renders
/// these as `ActionCard`s. The action layer (template-specific) maps each
/// `ActionType` to an icon + onTap navigation.
public struct UserAction: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public let userId: UUID
    public let groupId: UUID
    public let actionType: ActionType
    public let referenceId: UUID
    public let title: String
    public let body: String?
    public let priority: ActionPriority
    public let createdAt: Date
    public let resolvedAt: Date?

    public init(
        id: UUID = UUID(),
        userId: UUID,
        groupId: UUID,
        actionType: ActionType,
        referenceId: UUID,
        title: String,
        body: String? = nil,
        priority: ActionPriority = .medium,
        createdAt: Date = .now,
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.groupId = groupId
        self.actionType = actionType
        self.referenceId = referenceId
        self.title = title
        self.body = body
        self.priority = priority
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }

    public var isPending: Bool { resolvedAt == nil }

    public enum CodingKeys: String, CodingKey {
        case id
        case userId       = "user_id"
        case groupId      = "group_id"
        case actionType   = "action_type"
        case referenceId  = "reference_id"
        case title
        case body
        case priority
        case createdAt    = "created_at"
        case resolvedAt   = "resolved_at"
    }
}

public enum ActionType: String, Codable, Sendable, Hashable, CaseIterable {
    // V1
    case finePending             = "finePending"
    case fineVoided              = "fineVoided"
    case appealVotePending       = "appealVotePending"
    case rsvpPending             = "rsvpPending"
    case fineProposalReview      = "fineProposalReview"
    case ruleChangeApplyPending  = "ruleChangeApplyPending"  // NEW: emitted by finalize_vote v3 when rule_change passes
    /// Tier 5 Beta (mig 00133): inserted by the events insert trigger
    /// when host_id ≠ created_by. Covers both manual assignment and
    /// rotation-resolved hosts from auto-generate-events.
    case hostAssigned            = "hostAssigned"
    // Future phases
    case slotPending             = "slotPending"
    case votePending             = "votePending"
    case contributionDue         = "contributionDue"
    case compensationDue         = "compensationDue"
}

public enum ActionPriority: String, Codable, Sendable, Hashable, CaseIterable {
    case low, medium, high, urgent
}
