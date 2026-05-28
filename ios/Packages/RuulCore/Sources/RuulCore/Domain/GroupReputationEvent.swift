import Foundation

/// Primitiva 12 (Confianza/Reputación). Append-only fact record about
/// a member's behaviour in a group. Mirrors `public.group_reputation_events`
/// 1:1 via the `member_reputation_events(...)` read RPC.
///
/// Doctrina: NO score público, NO ranking, NO badges. La UI renderiza
/// hechos neutrales (qué pasó, cuándo, opcionalmente por qué).
public enum ReputationKind: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case trustEvent              = "trust_event"
    case contributionRecognized  = "contribution_recognized"
    case commitmentKept          = "commitment_kept"
    case commitmentBroken        = "commitment_broken"
    case conflictResolved        = "conflict_resolved"
    case careShown               = "care_shown"
    case leadershipShown         = "leadership_shown"
    case ruleViolation           = "rule_violation"
    case reliabilitySignal       = "reliability_signal"
    case skillSignal             = "skill_signal"
    case other

    public var id: String { rawValue }

    public var label: LocalizedStringResource {
        switch self {
        case .trustEvent:             return L10n.Reputation.kindTrustEvent
        case .contributionRecognized: return L10n.Reputation.kindContributionRecognized
        case .commitmentKept:         return L10n.Reputation.kindCommitmentKept
        case .commitmentBroken:       return L10n.Reputation.kindCommitmentBroken
        case .conflictResolved:       return L10n.Reputation.kindConflictResolved
        case .careShown:              return L10n.Reputation.kindCareShown
        case .leadershipShown:        return L10n.Reputation.kindLeadershipShown
        case .ruleViolation:          return L10n.Reputation.kindRuleViolation
        case .reliabilitySignal:      return L10n.Reputation.kindReliabilitySignal
        case .skillSignal:            return L10n.Reputation.kindSkillSignal
        case .other:                  return L10n.Reputation.kindOther
        }
    }

    /// Neutral SF Symbol per kind. NO red/green semantics — the doctrine
    /// bans visual ranking. Icons name the *event type*, not a verdict.
    public var systemImageName: String {
        switch self {
        case .trustEvent:             return "circle.dotted"
        case .contributionRecognized: return "hands.sparkles"
        case .commitmentKept:         return "checkmark.circle"
        case .commitmentBroken:       return "exclamationmark.circle"
        case .conflictResolved:       return "person.line.dotted.person"
        case .careShown:              return "heart"
        case .leadershipShown:        return "flag.checkered"
        case .ruleViolation:          return "book.closed"
        case .reliabilitySignal:      return "clock.arrow.circlepath"
        case .skillSignal:            return "lightbulb"
        case .other:                  return "circle"
        }
    }
}

public enum ReputationVisibility: String, Codable, CaseIterable, Sendable, Hashable {
    case `private`
    case members
    case `public`

    public var label: LocalizedStringResource {
        switch self {
        case .private: return L10n.RecordReputation.visibilityPrivate
        case .members: return L10n.RecordReputation.visibilityMembers
        case .public:  return L10n.RecordReputation.visibilityPublic
        }
    }
}

public struct GroupReputationEvent: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID                            // event_id
    public let groupId: UUID
    public let subjectMembershipId: UUID
    public let subjectDisplayName: String?         // pre-joined by group feed RPC
    public let actorMembershipId: UUID?
    public let actorDisplayName: String?           // pre-joined by group feed RPC
    public let kind: ReputationKind
    public let reason: String?
    public let evidenceEntityKind: String?
    public let evidenceEntityId: UUID?
    public let visibility: ReputationVisibility
    public let status: String
    public let occurredAt: Date?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id                  = "event_id"
        case groupId             = "group_id"
        case subjectMembershipId = "subject_membership_id"
        case subjectDisplayName  = "subject_display_name"
        case actorMembershipId   = "actor_membership_id"
        case actorDisplayName    = "actor_display_name"
        case kind                = "reputation_type"
        case reason
        case evidenceEntityKind  = "evidence_entity_kind"
        case evidenceEntityId    = "evidence_entity_id"
        case visibility
        case status
        case occurredAt          = "occurred_at"
        case createdAt           = "created_at"
    }

    public init(
        id: UUID,
        groupId: UUID,
        subjectMembershipId: UUID,
        subjectDisplayName: String? = nil,
        actorMembershipId: UUID? = nil,
        actorDisplayName: String? = nil,
        kind: ReputationKind,
        reason: String? = nil,
        evidenceEntityKind: String? = nil,
        evidenceEntityId: UUID? = nil,
        visibility: ReputationVisibility = .members,
        status: String = "active",
        occurredAt: Date? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.subjectMembershipId = subjectMembershipId
        self.subjectDisplayName = subjectDisplayName
        self.actorMembershipId = actorMembershipId
        self.actorDisplayName = actorDisplayName
        self.kind = kind
        self.reason = reason
        self.evidenceEntityKind = evidenceEntityKind
        self.evidenceEntityId = evidenceEntityId
        self.visibility = visibility
        self.status = status
        self.occurredAt = occurredAt
        self.createdAt = createdAt
    }

    /// Tolerant decode: unknown enums fall back to safe defaults. The
    /// read RPC returns `event_id`; the write RPC returns the raw row
    /// with `id` — accept either. Subject/actor display names only
    /// arrive from the group-feed RPC and decode as nil otherwise.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = v
        } else {
            let alt = try decoder.container(keyedBy: AltKeys.self)
            self.id = try alt.decode(UUID.self, forKey: .idAlt)
        }
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.subjectMembershipId = try c.decode(UUID.self, forKey: .subjectMembershipId)
        self.subjectDisplayName = try c.decodeIfPresent(String.self, forKey: .subjectDisplayName)
        self.actorMembershipId = try c.decodeIfPresent(UUID.self, forKey: .actorMembershipId)
        self.actorDisplayName = try c.decodeIfPresent(String.self, forKey: .actorDisplayName)
        let rawKind = try c.decode(String.self, forKey: .kind)
        self.kind = ReputationKind(rawValue: rawKind) ?? .other
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
        self.evidenceEntityKind = try c.decodeIfPresent(String.self, forKey: .evidenceEntityKind)
        self.evidenceEntityId = try c.decodeIfPresent(UUID.self, forKey: .evidenceEntityId)
        let rawVis = try c.decodeIfPresent(String.self, forKey: .visibility) ?? "members"
        self.visibility = ReputationVisibility(rawValue: rawVis) ?? .members
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "active"
        self.occurredAt = try c.decodeIfPresent(Date.self, forKey: .occurredAt)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    private enum AltKeys: String, CodingKey { case idAlt = "id" }
}

public extension GroupReputationEvent {
    /// Best timestamp the row carries; `occurred_at` is the canonical
    /// one, `created_at` is the fallback.
    var when: Date? { occurredAt ?? createdAt }
}
