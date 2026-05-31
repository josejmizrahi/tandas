import Foundation

/// Primitiva 16 (Decisions / Voting). Mirrors `public.group_decisions`
/// + `public.group_decision_options` + `public.group_votes` via the
/// `list_decisions_active(...)`, `list_decisions_history(...)` and
/// `decision_detail(...)` RPCs.
///
/// `group_votes` is append-only — "current vote" is the row with the
/// largest `seq` per voter. The list RPCs already collapse that into a
/// flat tally row; the detail RPC exposes the same shape plus the
/// caller's own current vote.
public enum DecisionStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case draft
    case open
    case passed
    case rejected
    case cancelled
    /// V3-D.18 — passed AND its side effects ran (execute_decision).
    case executed
    /// Legacy from the original schema. Backend CHECK keeps it for compat;
    /// no row currently uses it. iOS treats it as a synonym of `.passed`
    /// for display purposes.
    case closed

    public var label: LocalizedStringResource {
        switch self {
        case .draft:     return L10n.Decisions.statusDraft
        case .open:      return L10n.Decisions.statusOpen
        case .passed:    return L10n.Decisions.statusPassed
        case .rejected:  return L10n.Decisions.statusRejected
        case .cancelled: return L10n.Decisions.statusCancelled
        case .executed:  return L10n.Decisions.statusPassed
        case .closed:    return L10n.Decisions.statusPassed
        }
    }

    public var isOpen: Bool { self == .open }
    /// V3-D.18 — true when a passed decision still awaits execute_decision.
    public var awaitsExecution: Bool { self == .passed }
}

/// Voting methods as written by `start_vote`. Mirrors the small set
/// `finalize_vote` understands; new backend values fall back to
/// `.other` so a forward-compatible backend never crashes the client.
public enum DecisionMethod: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case admin
    case majority
    case supermajority
    case consensus
    case consent
    case rankedChoice = "ranked_choice"
    case weighted
    case veto
    case other

    public var id: String { rawValue }

    /// Methods we expose in the propose sheet — the 8 canonical methods
    /// the backend accepts (`group_decisions.method` CHECK). `other` is
    /// decode-only — it represents unknown backend values so we don't
    /// crash, but the picker never offers it.
    public static let selectable: [DecisionMethod] = [
        .admin, .majority, .supermajority, .consensus, .consent,
        .rankedChoice, .weighted, .veto
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .admin:         return L10n.Decisions.methodAdmin
        case .majority:      return L10n.Decisions.methodMajority
        case .supermajority: return L10n.Decisions.methodSupermajority
        case .consensus:     return L10n.Decisions.methodConsensus
        case .consent:       return L10n.Decisions.methodConsent
        case .rankedChoice:  return L10n.Decisions.methodRankedChoice
        case .weighted:      return L10n.Decisions.methodWeighted
        case .veto:          return L10n.Decisions.methodVeto
        case .other:         return L10n.Decisions.methodOther
        }
    }

    public var subtitle: LocalizedStringResource {
        switch self {
        case .admin:         return L10n.Decisions.methodAdminSubtitle
        case .majority:      return L10n.Decisions.methodMajoritySubtitle
        case .supermajority: return L10n.Decisions.methodSupermajoritySubtitle
        case .consensus:     return L10n.Decisions.methodConsensusSubtitle
        case .consent:       return L10n.Decisions.methodConsentSubtitle
        case .rankedChoice:  return L10n.Decisions.methodRankedChoiceSubtitle
        case .weighted:      return L10n.Decisions.methodWeightedSubtitle
        case .veto:          return L10n.Decisions.methodVetoSubtitle
        case .other:         return L10n.Decisions.methodOtherSubtitle
        }
    }

    public var systemImageName: String {
        switch self {
        case .admin:         return "person.crop.circle.badge.checkmark"
        case .majority:      return "chart.bar.fill"
        case .supermajority: return "chart.bar.doc.horizontal"
        case .consensus:     return "person.3.sequence"
        case .consent:       return "hand.raised"
        case .rankedChoice:  return "list.number"
        case .weighted:      return "scalemass"
        case .veto:          return "hand.raised.slash"
        case .other:         return "questionmark.circle"
        }
    }
}

/// Mirrors `group_decisions.legitimacy_source` CHECK — what gives this
/// decision its authority. Different from `method` (which is how votes
/// are tallied). The 10 canonical sources cover the spectrum from
/// founder-imposed to emergency-driven; `other` is decode-only.
public enum LegitimacySource: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case founder
    case election
    case majority
    case supermajority
    case committee
    case unanimity
    case expert
    case externalContract = "external_contract"
    case tradition
    case emergency
    case other

    public var id: String { rawValue }

    public static let selectable: [LegitimacySource] = [
        .founder, .election, .majority, .supermajority, .committee,
        .unanimity, .expert, .externalContract, .tradition, .emergency
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .founder:          return L10n.Decisions.legitimacyFounder
        case .election:         return L10n.Decisions.legitimacyElection
        case .majority:         return L10n.Decisions.legitimacyMajority
        case .supermajority:    return L10n.Decisions.legitimacySupermajority
        case .committee:        return L10n.Decisions.legitimacyCommittee
        case .unanimity:        return L10n.Decisions.legitimacyUnanimity
        case .expert:           return L10n.Decisions.legitimacyExpert
        case .externalContract: return L10n.Decisions.legitimacyExternalContract
        case .tradition:        return L10n.Decisions.legitimacyTradition
        case .emergency:        return L10n.Decisions.legitimacyEmergency
        case .other:            return L10n.Decisions.legitimacyOther
        }
    }

    public var subtitle: LocalizedStringResource {
        switch self {
        case .founder:          return L10n.Decisions.legitimacyFounderSubtitle
        case .election:         return L10n.Decisions.legitimacyElectionSubtitle
        case .majority:         return L10n.Decisions.legitimacyMajoritySubtitle
        case .supermajority:    return L10n.Decisions.legitimacySupermajoritySubtitle
        case .committee:        return L10n.Decisions.legitimacyCommitteeSubtitle
        case .unanimity:        return L10n.Decisions.legitimacyUnanimitySubtitle
        case .expert:           return L10n.Decisions.legitimacyExpertSubtitle
        case .externalContract: return L10n.Decisions.legitimacyExternalContractSubtitle
        case .tradition:        return L10n.Decisions.legitimacyTraditionSubtitle
        case .emergency:        return L10n.Decisions.legitimacyEmergencySubtitle
        case .other:            return L10n.Decisions.legitimacyOtherSubtitle
        }
    }

    public var systemImageName: String {
        switch self {
        case .founder:          return "star.circle"
        case .election:         return "checkmark.square"
        case .majority:         return "chart.bar.fill"
        case .supermajority:    return "chart.bar.doc.horizontal"
        case .committee:        return "person.3.sequence"
        case .unanimity:        return "hand.thumbsup"
        case .expert:           return "person.crop.rectangle.badge.checkmark"
        case .externalContract: return "doc.text"
        case .tradition:        return "book"
        case .emergency:        return "exclamationmark.triangle"
        case .other:            return "questionmark.circle"
        }
    }

    /// V2-G1 — sensible default given a chosen `method`. The matrix is
    /// non-binding: founders can override in the picker. We pair
    /// method↔source so the proposer doesn't have to reason about
    /// "why is this method legitimate" from scratch on every decision.
    public static func defaultFor(method: DecisionMethod) -> LegitimacySource {
        switch method {
        case .admin:         return .founder
        case .majority:      return .majority
        case .supermajority: return .supermajority
        case .consensus:     return .unanimity
        case .consent:       return .committee
        case .rankedChoice:  return .election
        case .weighted:      return .expert
        case .veto:          return .committee
        case .other:         return .majority
        }
    }
}

/// Mirrors `group_decisions.decision_type`. The 11 canonical types
/// from the backend CHECK are all exposed in the picker; `other` is
/// retained as a tolerant decode-only fallback for unknown future
/// values. V2-G2 sub-slice 1 surfaces all of them at the propose
/// stage; outcome handlers (mutate state on finalize) land in
/// subsequent sub-slices.
public enum DecisionType: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case proposal
    case poll
    case election
    case budget
    case ruleChange       = "rule_change"
    case membership
    case sanctionAppeal   = "sanction_appeal"
    case mandateGrant     = "mandate_grant"
    case mandateRevoke    = "mandate_revoke"
    case dissolution
    case other

    public var id: String { rawValue }

    /// What the proposer can actually pick. `other` stays decode-only.
    public static let selectable: [DecisionType] = [
        .proposal, .poll, .election, .budget,
        .ruleChange, .membership, .sanctionAppeal,
        .mandateGrant, .mandateRevoke, .dissolution
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .proposal:       return L10n.Decisions.typeProposal
        case .poll:           return L10n.Decisions.typePoll
        case .election:       return L10n.Decisions.typeElection
        case .budget:         return L10n.Decisions.typeBudget
        case .ruleChange:     return L10n.Decisions.typeRuleChange
        case .membership:     return L10n.Decisions.typeMembership
        case .sanctionAppeal: return L10n.Decisions.typeSanctionAppeal
        case .mandateGrant:   return L10n.Decisions.typeMandateGrant
        case .mandateRevoke:  return L10n.Decisions.typeMandateRevoke
        case .dissolution:    return L10n.Decisions.typeDissolution
        case .other:          return L10n.Decisions.typeOther
        }
    }

    public var subtitle: LocalizedStringResource {
        switch self {
        case .proposal:       return L10n.Decisions.typeProposalSubtitle
        case .poll:           return L10n.Decisions.typePollSubtitle
        case .election:       return L10n.Decisions.typeElectionSubtitle
        case .budget:         return L10n.Decisions.typeBudgetSubtitle
        case .ruleChange:     return L10n.Decisions.typeRuleChangeSubtitle
        case .membership:     return L10n.Decisions.typeMembershipSubtitle
        case .sanctionAppeal: return L10n.Decisions.typeSanctionAppealSubtitle
        case .mandateGrant:   return L10n.Decisions.typeMandateGrantSubtitle
        case .mandateRevoke:  return L10n.Decisions.typeMandateRevokeSubtitle
        case .dissolution:    return L10n.Decisions.typeDissolutionSubtitle
        case .other:          return L10n.Decisions.typeOtherSubtitle
        }
    }

    public var systemImageName: String {
        switch self {
        case .proposal:       return "lightbulb"
        case .poll:           return "chart.pie"
        case .election:       return "person.crop.circle.badge.checkmark"
        case .budget:         return "creditcard"
        case .ruleChange:     return "list.bullet.rectangle"
        case .membership:     return "person.2"
        case .sanctionAppeal: return "exclamationmark.shield"
        case .mandateGrant:   return "person.crop.rectangle.badge.checkmark"
        case .mandateRevoke:  return "xmark.circle"
        case .dissolution:    return "archivebox"
        case .other:          return "questionmark.circle"
        }
    }

    /// Coarse grouping so the propose picker can section the 11 types
    /// in human language ("Charla / Movimiento de gente / Plata /
    /// Reglas internas / Salida"). Order respects the founder's mental
    /// model: deliberate→organize→manage money→fix rules→leave.
    public enum Group: String, CaseIterable, Identifiable, Hashable {
        case discussion
        case people
        case money
        case rules
        case exit

        public var id: String { rawValue }

        public var label: LocalizedStringResource {
            switch self {
            case .discussion: return L10n.Decisions.typeGroupDiscussion
            case .people:     return L10n.Decisions.typeGroupPeople
            case .money:      return L10n.Decisions.typeGroupMoney
            case .rules:      return L10n.Decisions.typeGroupRules
            case .exit:       return L10n.Decisions.typeGroupExit
            }
        }
    }

    public var group: Group {
        switch self {
        case .proposal, .poll:                                     return .discussion
        case .election, .membership, .mandateGrant, .mandateRevoke: return .people
        case .budget:                                              return .money
        case .ruleChange, .sanctionAppeal:                         return .rules
        case .dissolution:                                         return .exit
        case .other:                                               return .discussion
        }
    }

    /// V2-G2 sub-slice 3 — when the decision type ties to a specific
    /// entity (a sanction to appeal, a mandate to revoke, etc.), this
    /// returns the canonical `reference_kind` string the backend
    /// `finalize_vote` switch uses to dispatch its outcome handler.
    /// `nil` means "open-ended decision, no entity required".
    public var requiredReferenceKind: String? {
        switch self {
        case .sanctionAppeal: return "sanction"
        case .mandateRevoke:  return "mandate_revoke"
        case .mandateGrant:   return "mandate_grant"
        case .dissolution:    return "dissolution"
        case .membership:     return "membership"
        case .ruleChange:     return "rule"
        case .budget:         return "pool_charge"
        default:              return nil
        }
    }
}

// `PoolChargeKind` moved to its own file (`PoolChargeKind.swift`) so
// the live typechecker can resolve it without parsing the entire
// `GroupDecision.swift` body. Same rationale as the post-G2 split in
// `7b3c1c76` — the IDE indexer chokes on large files full of
// pattern-matching enums.

/// V2-G2 sub-slice 5 — action a `decision_type='rule_change'`
/// proposes to apply on the referenced rule when finalize_vote
/// passes. The handler in finalize_vote reads `metadata.action` and
/// dispatches the corresponding inline mutation.
public enum RuleChangeAction: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case archive
    case activate

    public var id: String { rawValue }

    public static let displayOrder: [RuleChangeAction] = [.archive, .activate]

    public var label: LocalizedStringResource {
        switch self {
        case .archive:  return L10n.Decisions.ruleChangeActionArchive
        case .activate: return L10n.Decisions.ruleChangeActionActivate
        }
    }

    public var systemImageName: String {
        switch self {
        case .archive:  return "archivebox"
        case .activate: return "checkmark.circle"
        }
    }
}

/// V2-G2 sub-slice 4 — target state a `decision_type='membership'`
/// proposes to apply when finalize_vote passes. Mirrors the canonical
/// `group_memberships.status` values the backend `set_membership_state`
/// RPC accepts.
public enum MembershipDecisionTargetState: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case active
    case suspended
    case expelled
    case inactive

    public var id: String { rawValue }

    public static let displayOrder: [MembershipDecisionTargetState] = [
        .active, .suspended, .expelled, .inactive
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .active:    return L10n.Decisions.membershipTargetActive
        case .suspended: return L10n.Decisions.membershipTargetSuspended
        case .expelled:  return L10n.Decisions.membershipTargetExpelled
        case .inactive:  return L10n.Decisions.membershipTargetInactive
        }
    }

    public var systemImageName: String {
        switch self {
        case .active:    return "checkmark.circle"
        case .suspended: return "pause.circle"
        case .expelled:  return "xmark.circle"
        case .inactive:  return "minus.circle"
        }
    }
}

/// One of the four ballot values a member can cast. Mirrors
/// `group_votes.vote_value`.
public enum VoteValue: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case yes
    case no
    case abstain
    case block

    public var id: String { rawValue }

    public static let displayOrder: [VoteValue] = [.yes, .no, .abstain, .block]

    public var label: LocalizedStringResource {
        switch self {
        case .yes:     return L10n.Decisions.voteYes
        case .no:      return L10n.Decisions.voteNo
        case .abstain: return L10n.Decisions.voteAbstain
        case .block:   return L10n.Decisions.voteBlock
        }
    }

    public var systemImageName: String {
        switch self {
        case .yes:     return "checkmark.circle"
        case .no:      return "xmark.circle"
        case .abstain: return "minus.circle"
        case .block:   return "hand.raised.fill"
        }
    }

    /// V2-G1 sub-slice 2 — vote values legally castable for a given
    /// decision method. The matrix here is the iOS surface contract,
    /// not the backend gate: `cast_vote` allows any of the four values
    /// regardless of method, but the UX restricts them to the
    /// semantics that match. Admin decisions have no member ballots.
    public static func allowed(for method: DecisionMethod) -> [VoteValue] {
        switch method {
        case .admin:
            return []
        case .majority, .supermajority:
            return [.yes, .no, .abstain, .block]
        case .consensus:
            return [.yes, .no, .abstain]
        case .consent:
            return [.yes, .block]
        case .veto:
            return [.yes, .block]
        case .rankedChoice, .weighted:
            // Sub-slice 3 ships richer UX; until then we fall back to
            // the broad set so the picker stays usable.
            return [.yes, .no, .abstain, .block]
        case .other:
            return [.yes, .no, .abstain, .block]
        }
    }

    /// Context-sensitive label so consent/veto read humanly. Falls back
    /// to the generic label when no specialisation applies.
    public func label(for method: DecisionMethod) -> LocalizedStringResource {
        switch (self, method) {
        case (.yes, .consent):   return L10n.Decisions.voteConsent
        case (.yes, .veto):      return L10n.Decisions.voteNoObjection
        case (.yes, .consensus): return L10n.Decisions.voteInFavor
        case (.no,  .consensus): return L10n.Decisions.voteObject
        case (.abstain, .consensus): return L10n.Decisions.voteWithdraw
        case (.block, .consent): return L10n.Decisions.voteBlockConsent
        case (.block, .veto):    return L10n.Decisions.voteCastVeto
        default:                 return label
        }
    }

    /// Blocking on consent / veto demands a reason — the whole point of
    /// those methods is "explain why you're stopping the group".
    public func requiresReason(for method: DecisionMethod) -> Bool {
        switch (self, method) {
        case (.block, .consent), (.block, .veto):
            return true
        default:
            return false
        }
    }
}

/// A single option row inside a decision. Mirrors
/// `public.group_decision_options`.
public struct GroupDecisionOption: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let label: String
    public let body: String?
    public let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case body
        case sortOrder = "sort_order"
    }

    public init(id: UUID, label: String, body: String? = nil, sortOrder: Int = 0) {
        self.id = id
        self.label = label
        self.body = body
        self.sortOrder = sortOrder
    }
}

/// Caller's own current vote on a decision. Only populated when the
/// caller has cast at least one vote; the row reflects the latest
/// `seq` (append-only semantics).
public struct GroupDecisionMyVote: Codable, Equatable, Sendable, Hashable {
    public let voteValue: VoteValue?
    public let optionId: UUID?
    public let reason: String?
    public let castAt: Date?

    enum CodingKeys: String, CodingKey {
        case voteValue = "vote_value"
        case optionId  = "option_id"
        case reason
        case castAt    = "cast_at"
    }

    public init(voteValue: VoteValue? = nil, optionId: UUID? = nil, reason: String? = nil, castAt: Date? = nil) {
        self.voteValue = voteValue
        self.optionId = optionId
        self.reason = reason
        self.castAt = castAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(String.self, forKey: .voteValue)
        self.voteValue = raw.flatMap { VoteValue(rawValue: $0) }
        self.optionId = try c.decodeIfPresent(UUID.self, forKey: .optionId)
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
        self.castAt = try c.decodeIfPresent(Date.self, forKey: .castAt)
    }
}

/// Aggregated tally of current votes on a decision.
public struct GroupDecisionTally: Codable, Equatable, Sendable, Hashable {
    public let voteCount: Int
    public let yesCount: Decimal
    public let noCount: Decimal
    public let abstainCount: Decimal
    public let blockCount: Decimal

    enum CodingKeys: String, CodingKey {
        case voteCount    = "vote_count"
        case yesCount     = "yes_count"
        case noCount      = "no_count"
        case abstainCount = "abstain_count"
        case blockCount   = "block_count"
    }

    public init(
        voteCount: Int = 0,
        yesCount: Decimal = 0,
        noCount: Decimal = 0,
        abstainCount: Decimal = 0,
        blockCount: Decimal = 0
    ) {
        self.voteCount = voteCount
        self.yesCount = yesCount
        self.noCount = noCount
        self.abstainCount = abstainCount
        self.blockCount = blockCount
    }
}

/// Typed view over `group_decisions.result` jsonb. Populated when
/// `finalize_vote` (or `cancel_vote`) runs; empty `{}` while the
/// decision is still open.
///
/// V2-G9 — `finalize_vote` now branches by method:
/// - `weighted` / `ranked_choice` → `optionTally` + `winnerOption` +
///   `winnerPoints` + `voterCount` (no yes/no fields).
/// - everything else → the canonical yes/no/abstain/block fields.
public struct DecisionResult: Codable, Equatable, Sendable, Hashable {
    public let outcome: String?
    public let method: String?
    public let yes: Decimal?
    public let no: Decimal?
    public let abstain: Decimal?
    public let block: Decimal?
    public let cancelReason: String?
    /// V2-G9 — per-option tally (option UUID → points). Present only
    /// for `weighted` / `ranked_choice` decisions.
    public let optionTally: [UUID: Decimal]?
    public let winnerOption: UUID?
    public let winnerPoints: Decimal?
    public let voterCount: Int?

    enum CodingKeys: String, CodingKey {
        case outcome
        case method
        case yes
        case no
        case abstain
        case block
        case cancelReason = "cancel_reason"
        case optionTally  = "option_tally"
        case winnerOption = "winner_option"
        case winnerPoints = "winner_points"
        case voterCount   = "voter_count"
    }

    public init(
        outcome: String? = nil,
        method: String? = nil,
        yes: Decimal? = nil,
        no: Decimal? = nil,
        abstain: Decimal? = nil,
        block: Decimal? = nil,
        cancelReason: String? = nil,
        optionTally: [UUID: Decimal]? = nil,
        winnerOption: UUID? = nil,
        winnerPoints: Decimal? = nil,
        voterCount: Int? = nil
    ) {
        self.outcome = outcome
        self.method = method
        self.yes = yes
        self.no = no
        self.abstain = abstain
        self.block = block
        self.cancelReason = cancelReason
        self.optionTally = optionTally
        self.winnerOption = winnerOption
        self.winnerPoints = winnerPoints
        self.voterCount = voterCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        self.method = try c.decodeIfPresent(String.self, forKey: .method)
        self.yes = try c.decodeIfPresent(Decimal.self, forKey: .yes)
        self.no = try c.decodeIfPresent(Decimal.self, forKey: .no)
        self.abstain = try c.decodeIfPresent(Decimal.self, forKey: .abstain)
        self.block = try c.decodeIfPresent(Decimal.self, forKey: .block)
        self.cancelReason = try c.decodeIfPresent(String.self, forKey: .cancelReason)
        if let rawTally = try c.decodeIfPresent([String: Decimal].self, forKey: .optionTally) {
            var typed: [UUID: Decimal] = [:]
            for (k, v) in rawTally {
                if let id = UUID(uuidString: k) { typed[id] = v }
            }
            self.optionTally = typed.isEmpty ? nil : typed
        } else {
            self.optionTally = nil
        }
        self.winnerOption = try c.decodeIfPresent(UUID.self, forKey: .winnerOption)
        self.winnerPoints = try c.decodeIfPresent(Decimal.self, forKey: .winnerPoints)
        self.voterCount = try c.decodeIfPresent(Int.self, forKey: .voterCount)
    }
}

// `WeightStrategy` moved to its own file (`WeightStrategy.swift`) for
// the same indexer-friendliness reason as `PoolChargeKind`.

/// Flat list-row shape returned by `list_decisions_active` /
/// `list_decisions_history`. Tally + caller's current vote are
/// already pre-joined so the list UI can render without a second hop.
public struct GroupDecisionSummary: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let title: String
    public let body: String?
    public let decisionType: DecisionType
    public let method: DecisionMethod
    public let legitimacySource: String?
    public let status: DecisionStatus
    public let thresholdPct: Decimal?
    public let quorumPct: Decimal?
    public let referenceKind: String?
    public let referenceId: UUID?
    public let opensAt: Date?
    public let closesAt: Date?
    public let decidedAt: Date?
    public let createdAt: Date?
    public let createdBy: UUID?
    public let createdByDisplayName: String?
    public let optionCount: Int
    public let tally: GroupDecisionTally
    public let result: DecisionResult?
    public let myVoteValue: VoteValue?
    public let myVoteOptionId: UUID?

    enum CodingKeys: String, CodingKey {
        case id                   = "decision_id"
        case groupId              = "group_id"
        case title
        case body
        case decisionType         = "decision_type"
        case method
        case legitimacySource     = "legitimacy_source"
        case status
        case thresholdPct         = "threshold_pct"
        case quorumPct            = "quorum_pct"
        case referenceKind        = "reference_kind"
        case referenceId          = "reference_id"
        case opensAt              = "opens_at"
        case closesAt             = "closes_at"
        case decidedAt            = "decided_at"
        case createdAt            = "created_at"
        case createdBy            = "created_by"
        case createdByDisplayName = "created_by_display_name"
        case optionCount          = "option_count"
        case voteCount            = "vote_count"
        case yesCount             = "yes_count"
        case noCount              = "no_count"
        case abstainCount         = "abstain_count"
        case blockCount           = "block_count"
        case result
        case myVoteValue          = "my_vote_value"
        case myVoteOptionId       = "my_vote_option_id"
    }

    public init(
        id: UUID,
        groupId: UUID,
        title: String,
        body: String? = nil,
        decisionType: DecisionType = .proposal,
        method: DecisionMethod = .majority,
        legitimacySource: String? = nil,
        status: DecisionStatus = .open,
        thresholdPct: Decimal? = nil,
        quorumPct: Decimal? = nil,
        referenceKind: String? = nil,
        referenceId: UUID? = nil,
        opensAt: Date? = nil,
        closesAt: Date? = nil,
        decidedAt: Date? = nil,
        createdAt: Date? = nil,
        createdBy: UUID? = nil,
        createdByDisplayName: String? = nil,
        optionCount: Int = 0,
        tally: GroupDecisionTally = GroupDecisionTally(),
        result: DecisionResult? = nil,
        myVoteValue: VoteValue? = nil,
        myVoteOptionId: UUID? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.title = title
        self.body = body
        self.decisionType = decisionType
        self.method = method
        self.legitimacySource = legitimacySource
        self.status = status
        self.thresholdPct = thresholdPct
        self.quorumPct = quorumPct
        self.referenceKind = referenceKind
        self.referenceId = referenceId
        self.opensAt = opensAt
        self.closesAt = closesAt
        self.decidedAt = decidedAt
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.createdByDisplayName = createdByDisplayName
        self.optionCount = optionCount
        self.tally = tally
        self.result = result
        self.myVoteValue = myVoteValue
        self.myVoteOptionId = myVoteOptionId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.title = try c.decode(String.self, forKey: .title)
        self.body = try c.decodeIfPresent(String.self, forKey: .body)
        let rawType = try c.decodeIfPresent(String.self, forKey: .decisionType) ?? "proposal"
        self.decisionType = DecisionType(rawValue: rawType) ?? .other
        let rawMethod = try c.decodeIfPresent(String.self, forKey: .method) ?? "majority"
        self.method = DecisionMethod(rawValue: rawMethod) ?? .other
        self.legitimacySource = try c.decodeIfPresent(String.self, forKey: .legitimacySource)
        let rawStatus = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        self.status = DecisionStatus(rawValue: rawStatus) ?? .open
        self.thresholdPct = try c.decodeIfPresent(Decimal.self, forKey: .thresholdPct)
        self.quorumPct = try c.decodeIfPresent(Decimal.self, forKey: .quorumPct)
        self.referenceKind = try c.decodeIfPresent(String.self, forKey: .referenceKind)
        self.referenceId = try c.decodeIfPresent(UUID.self, forKey: .referenceId)
        self.opensAt = try c.decodeIfPresent(Date.self, forKey: .opensAt)
        self.closesAt = try c.decodeIfPresent(Date.self, forKey: .closesAt)
        self.decidedAt = try c.decodeIfPresent(Date.self, forKey: .decidedAt)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.createdByDisplayName = try c.decodeIfPresent(String.self, forKey: .createdByDisplayName)
        self.optionCount = try c.decodeIfPresent(Int.self, forKey: .optionCount) ?? 0
        self.tally = GroupDecisionTally(
            voteCount: try c.decodeIfPresent(Int.self, forKey: .voteCount) ?? 0,
            yesCount: try c.decodeIfPresent(Decimal.self, forKey: .yesCount) ?? 0,
            noCount: try c.decodeIfPresent(Decimal.self, forKey: .noCount) ?? 0,
            abstainCount: try c.decodeIfPresent(Decimal.self, forKey: .abstainCount) ?? 0,
            blockCount: try c.decodeIfPresent(Decimal.self, forKey: .blockCount) ?? 0
        )
        self.result = try c.decodeIfPresent(DecisionResult.self, forKey: .result)
        let rawMy = try c.decodeIfPresent(String.self, forKey: .myVoteValue)
        self.myVoteValue = rawMy.flatMap { VoteValue(rawValue: $0) }
        self.myVoteOptionId = try c.decodeIfPresent(UUID.self, forKey: .myVoteOptionId)
    }

    /// Encoder kept symmetric with the custom decoder so the type
    /// stays `Codable`-correct for tests that round-trip via JSON.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(groupId, forKey: .groupId)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(body, forKey: .body)
        try c.encode(decisionType.rawValue, forKey: .decisionType)
        try c.encode(method.rawValue, forKey: .method)
        try c.encodeIfPresent(legitimacySource, forKey: .legitimacySource)
        try c.encode(status.rawValue, forKey: .status)
        try c.encodeIfPresent(thresholdPct, forKey: .thresholdPct)
        try c.encodeIfPresent(quorumPct, forKey: .quorumPct)
        try c.encodeIfPresent(referenceKind, forKey: .referenceKind)
        try c.encodeIfPresent(referenceId, forKey: .referenceId)
        try c.encodeIfPresent(opensAt, forKey: .opensAt)
        try c.encodeIfPresent(closesAt, forKey: .closesAt)
        try c.encodeIfPresent(decidedAt, forKey: .decidedAt)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encodeIfPresent(createdByDisplayName, forKey: .createdByDisplayName)
        try c.encode(optionCount, forKey: .optionCount)
        try c.encode(tally.voteCount, forKey: .voteCount)
        try c.encode(tally.yesCount, forKey: .yesCount)
        try c.encode(tally.noCount, forKey: .noCount)
        try c.encode(tally.abstainCount, forKey: .abstainCount)
        try c.encode(tally.blockCount, forKey: .blockCount)
        try c.encodeIfPresent(result, forKey: .result)
        try c.encodeIfPresent(myVoteValue?.rawValue, forKey: .myVoteValue)
        try c.encodeIfPresent(myVoteOptionId, forKey: .myVoteOptionId)
    }
}

/// Detail shape returned by `decision_detail(p_decision_id)`. Same
/// scalar fields as `GroupDecisionSummary` plus a nested options array
/// + per-option current tally + caller's full last vote (with reason).
public struct GroupDecisionDetail: Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let title: String
    public let body: String?
    public let decisionType: DecisionType
    public let method: DecisionMethod
    public let legitimacySource: String?
    public let status: DecisionStatus
    public let thresholdPct: Decimal?
    public let quorumPct: Decimal?
    public let referenceKind: String?
    public let referenceId: UUID?
    public let opensAt: Date?
    public let closesAt: Date?
    public let decidedAt: Date?
    public let createdAt: Date?
    public let createdBy: UUID?
    public let createdByDisplayName: String?
    public let result: DecisionResult?
    public let options: [GroupDecisionOption]
    public let tally: GroupDecisionTally
    public let optionTally: [UUID: Int]
    public let myVote: GroupDecisionMyVote?
    /// V2-G9 — derived from `metadata.weight_strategy`. Non-nil only
    /// for `method='weighted'` decisions; iOS uses `maxWeight` to size
    /// the VoteSheet weight slider.
    public let weightStrategy: WeightStrategy?

    enum CodingKeys: String, CodingKey {
        case id                   = "decision_id"
        case groupId              = "group_id"
        case title
        case body
        case decisionType         = "decision_type"
        case method
        case legitimacySource     = "legitimacy_source"
        case status
        case thresholdPct         = "threshold_pct"
        case quorumPct            = "quorum_pct"
        case referenceKind        = "reference_kind"
        case referenceId          = "reference_id"
        case opensAt              = "opens_at"
        case closesAt             = "closes_at"
        case decidedAt            = "decided_at"
        case createdAt            = "created_at"
        case createdBy            = "created_by"
        case createdByDisplayName = "created_by_display_name"
        case result
        case metadata
        case options
        case tally
        case optionTally          = "option_tally"
        case myVote               = "my_vote"
    }

    /// Sub-key inside `metadata` carrying the typed weight strategy.
    private struct MetadataShape: Decodable {
        let weightStrategy: WeightStrategy?
        enum CodingKeys: String, CodingKey { case weightStrategy = "weight_strategy" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.weightStrategy = try c.decodeIfPresent(WeightStrategy.self, forKey: .weightStrategy)
        }
    }

    public init(
        id: UUID,
        groupId: UUID,
        title: String,
        body: String? = nil,
        decisionType: DecisionType = .proposal,
        method: DecisionMethod = .majority,
        legitimacySource: String? = nil,
        status: DecisionStatus = .open,
        thresholdPct: Decimal? = nil,
        quorumPct: Decimal? = nil,
        referenceKind: String? = nil,
        referenceId: UUID? = nil,
        opensAt: Date? = nil,
        closesAt: Date? = nil,
        decidedAt: Date? = nil,
        createdAt: Date? = nil,
        createdBy: UUID? = nil,
        createdByDisplayName: String? = nil,
        result: DecisionResult? = nil,
        options: [GroupDecisionOption] = [],
        tally: GroupDecisionTally = GroupDecisionTally(),
        optionTally: [UUID: Int] = [:],
        myVote: GroupDecisionMyVote? = nil,
        weightStrategy: WeightStrategy? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.title = title
        self.body = body
        self.decisionType = decisionType
        self.method = method
        self.legitimacySource = legitimacySource
        self.status = status
        self.thresholdPct = thresholdPct
        self.quorumPct = quorumPct
        self.referenceKind = referenceKind
        self.referenceId = referenceId
        self.opensAt = opensAt
        self.closesAt = closesAt
        self.decidedAt = decidedAt
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.createdByDisplayName = createdByDisplayName
        self.result = result
        self.options = options
        self.tally = tally
        self.optionTally = optionTally
        self.myVote = myVote
        self.weightStrategy = weightStrategy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.title = try c.decode(String.self, forKey: .title)
        self.body = try c.decodeIfPresent(String.self, forKey: .body)
        let rawType = try c.decodeIfPresent(String.self, forKey: .decisionType) ?? "proposal"
        self.decisionType = DecisionType(rawValue: rawType) ?? .other
        let rawMethod = try c.decodeIfPresent(String.self, forKey: .method) ?? "majority"
        self.method = DecisionMethod(rawValue: rawMethod) ?? .other
        self.legitimacySource = try c.decodeIfPresent(String.self, forKey: .legitimacySource)
        let rawStatus = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        self.status = DecisionStatus(rawValue: rawStatus) ?? .open
        self.thresholdPct = try c.decodeIfPresent(Decimal.self, forKey: .thresholdPct)
        self.quorumPct = try c.decodeIfPresent(Decimal.self, forKey: .quorumPct)
        self.referenceKind = try c.decodeIfPresent(String.self, forKey: .referenceKind)
        self.referenceId = try c.decodeIfPresent(UUID.self, forKey: .referenceId)
        self.opensAt = try c.decodeIfPresent(Date.self, forKey: .opensAt)
        self.closesAt = try c.decodeIfPresent(Date.self, forKey: .closesAt)
        self.decidedAt = try c.decodeIfPresent(Date.self, forKey: .decidedAt)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.createdByDisplayName = try c.decodeIfPresent(String.self, forKey: .createdByDisplayName)
        self.result = try c.decodeIfPresent(DecisionResult.self, forKey: .result)
        self.options = try c.decodeIfPresent([GroupDecisionOption].self, forKey: .options) ?? []
        self.tally = try c.decodeIfPresent(GroupDecisionTally.self, forKey: .tally) ?? GroupDecisionTally()
        if let rawMap = try c.decodeIfPresent([String: Int].self, forKey: .optionTally) {
            var parsed: [UUID: Int] = [:]
            for (k, v) in rawMap {
                if let id = UUID(uuidString: k) { parsed[id] = v }
            }
            self.optionTally = parsed
        } else {
            self.optionTally = [:]
        }
        self.myVote = try c.decodeIfPresent(GroupDecisionMyVote.self, forKey: .myVote)
        if let shape = try c.decodeIfPresent(MetadataShape.self, forKey: .metadata) {
            self.weightStrategy = shape.weightStrategy
        } else {
            self.weightStrategy = nil
        }
    }

    /// Encode covers the read shape only — iOS never sends a Detail
    /// back to the server. We still need this so Swift's synthesized
    /// Encodable conformance doesn't trip on the Decodable-only
    /// `MetadataShape` helper.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(groupId, forKey: .groupId)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(body, forKey: .body)
        try c.encode(decisionType.rawValue, forKey: .decisionType)
        try c.encode(method.rawValue, forKey: .method)
        try c.encodeIfPresent(legitimacySource, forKey: .legitimacySource)
        try c.encode(status.rawValue, forKey: .status)
        try c.encodeIfPresent(thresholdPct, forKey: .thresholdPct)
        try c.encodeIfPresent(quorumPct, forKey: .quorumPct)
        try c.encodeIfPresent(referenceKind, forKey: .referenceKind)
        try c.encodeIfPresent(referenceId, forKey: .referenceId)
        try c.encodeIfPresent(opensAt, forKey: .opensAt)
        try c.encodeIfPresent(closesAt, forKey: .closesAt)
        try c.encodeIfPresent(decidedAt, forKey: .decidedAt)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encodeIfPresent(createdByDisplayName, forKey: .createdByDisplayName)
        try c.encodeIfPresent(result, forKey: .result)
        try c.encode(options, forKey: .options)
        try c.encode(tally, forKey: .tally)
        let tallyStr = Dictionary(uniqueKeysWithValues: optionTally.map { ($0.key.uuidString, $0.value) })
        try c.encode(tallyStr, forKey: .optionTally)
        try c.encodeIfPresent(myVote, forKey: .myVote)
    }
}

public extension GroupDecisionSummary {
    /// `true` when the caller has cast a vote we know about.
    var hasMyVote: Bool { myVoteValue != nil }
}

public extension GroupDecisionDetail {
    var hasMyVote: Bool { myVote?.voteValue != nil }
    var isOpenForVoting: Bool { status == .open }
    var totalWeight: Decimal { tally.yesCount + tally.noCount + tally.abstainCount + tally.blockCount }
}
