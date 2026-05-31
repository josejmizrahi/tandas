import Foundation

// MARK: - V3-D.20 — Membership provenance
//
// Mirrors `membership_provenance(p_membership_id)` jsonb payload.
// Answers "¿por qué esta persona está en este estado?". When state
// changed via a decision/rule, the source link is populated.

public struct MembershipLastTransition: Codable, Sendable, Hashable, Equatable {
    public let eventType: String
    public let reason: String?
    public let actorUserId: UUID?
    public let at: Date?

    enum CodingKeys: String, CodingKey {
        case eventType    = "event_type"
        case reason
        case actorUserId  = "actor_user_id"
        case at
    }
}

public struct MembershipSourceDecision: Codable, Sendable, Hashable, Equatable {
    public let decisionId: UUID
    public let title: String?
    public let outcome: String?
    public let executedAt: Date?
    public let templateKey: String?

    enum CodingKeys: String, CodingKey {
        case decisionId  = "decision_id"
        case title, outcome
        case executedAt  = "executed_at"
        case templateKey = "template_key"
    }
}

public struct MembershipProvenance: Codable, Sendable, Hashable, Equatable {
    public let found: Bool
    public let reason: String?
    public let membershipId: UUID?
    public let groupId: UUID?
    public let userId: UUID?
    public let currentState: String?
    public let membershipType: String?
    public let currentReason: String?
    public let joinedAt: Date?
    public let confirmedAt: Date?
    public let pausedUntil: Date?
    public let suspendedUntil: Date?
    public let leftAt: Date?
    public let removedAt: Date?
    public let unbannedAt: Date?
    public let joinedVia: String?
    public let invitedBy: UUID?
    public let lastTransition: MembershipLastTransition?
    public let sourceEvent: ProvenanceSourceEvent?
    public let sourceDecision: MembershipSourceDecision?
    public let sourceRuleTitle: String?
    public let sourceConsequenceKind: String?

    public init(
        found: Bool,
        reason: String? = nil,
        membershipId: UUID? = nil,
        groupId: UUID? = nil,
        userId: UUID? = nil,
        currentState: String? = nil,
        membershipType: String? = nil,
        currentReason: String? = nil,
        joinedAt: Date? = nil,
        confirmedAt: Date? = nil,
        pausedUntil: Date? = nil,
        suspendedUntil: Date? = nil,
        leftAt: Date? = nil,
        removedAt: Date? = nil,
        unbannedAt: Date? = nil,
        joinedVia: String? = nil,
        invitedBy: UUID? = nil,
        lastTransition: MembershipLastTransition? = nil,
        sourceEvent: ProvenanceSourceEvent? = nil,
        sourceDecision: MembershipSourceDecision? = nil,
        sourceRuleTitle: String? = nil,
        sourceConsequenceKind: String? = nil
    ) {
        self.found = found
        self.reason = reason
        self.membershipId = membershipId
        self.groupId = groupId
        self.userId = userId
        self.currentState = currentState
        self.membershipType = membershipType
        self.currentReason = currentReason
        self.joinedAt = joinedAt
        self.confirmedAt = confirmedAt
        self.pausedUntil = pausedUntil
        self.suspendedUntil = suspendedUntil
        self.leftAt = leftAt
        self.removedAt = removedAt
        self.unbannedAt = unbannedAt
        self.joinedVia = joinedVia
        self.invitedBy = invitedBy
        self.lastTransition = lastTransition
        self.sourceEvent = sourceEvent
        self.sourceDecision = sourceDecision
        self.sourceRuleTitle = sourceRuleTitle
        self.sourceConsequenceKind = sourceConsequenceKind
    }

    enum CodingKeys: String, CodingKey {
        case found, reason
        case membershipId             = "membership_id"
        case groupId                  = "group_id"
        case userId                   = "user_id"
        case currentState             = "current_state"
        case membershipType           = "membership_type"
        case currentReason            = "current_reason"
        case joinedAt                 = "joined_at"
        case confirmedAt              = "confirmed_at"
        case pausedUntil              = "paused_until"
        case suspendedUntil           = "suspended_until"
        case leftAt                   = "left_at"
        case removedAt                = "removed_at"
        case unbannedAt               = "unbanned_at"
        case joinedVia                = "joined_via"
        case invitedBy                = "invited_by"
        case lastTransition           = "last_transition"
        case sourceEvent              = "source_event"
        case sourceDecision           = "source_decision"
        case sourceRuleTitle          = "source_rule_title"
        case sourceConsequenceKind    = "source_consequence_kind"
    }
}

// MARK: - V3-D.20 — Approve membership request result

public struct ApproveMembershipRequestResult: Codable, Sendable, Hashable, Equatable {
    public let membershipId: UUID
    public let groupId: UUID
    public let status: String
    public let changed: Bool

    public init(membershipId: UUID, groupId: UUID, status: String, changed: Bool) {
        self.membershipId = membershipId
        self.groupId = groupId
        self.status = status
        self.changed = changed
    }

    enum CodingKeys: String, CodingKey {
        case membershipId = "membership_id"
        case groupId      = "group_id"
        case status, changed
    }
}

// MARK: - V3-D.20 — Membership state transition catalog row

public struct MembershipStateTransition: Codable, Sendable, Hashable, Equatable, Identifiable {
    public let fromState: String
    public let toState: String
    public let requiredPermission: String?
    public let requiresDecision: Bool
    public let eventType: String
    public let reversible: Bool
    public let description: String?

    public var id: String { "\(fromState)→\(toState)" }

    enum CodingKeys: String, CodingKey {
        case fromState           = "from_state"
        case toState             = "to_state"
        case requiredPermission  = "required_permission"
        case requiresDecision    = "requires_decision"
        case eventType           = "event_type"
        case reversible
        case description
    }
}
