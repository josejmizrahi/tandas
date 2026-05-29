import Foundation

/// V3 PARTE 7 — single snapshot in the append-only `group_governance_versions`
/// audit trail for `groups.decision_rules`. Read via
/// `group_governance_versions(p_group_id, p_limit)` RPC; pre-joined with
/// the profile.display_name of the actor who set the version.
///
/// `effectiveUntil` is `nil` for the active version (UNIQUE partial idx
/// in the BD enforces "one active per group"). `sourceDecisionId` is
/// `nil` for direct admin sets; will carry the decision_id when the
/// PARTE 4 governance_change handler lands.
public struct GroupGovernanceVersion: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let snapshot: GovernanceSnapshot
    public let effectiveFrom: Date
    public let effectiveUntil: Date?
    public let setByUserId: UUID?
    public let setByDisplayName: String?
    public let sourceDecisionId: UUID?
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case snapshot
        case effectiveFrom    = "effective_from"
        case effectiveUntil   = "effective_until"
        case setByUserId      = "set_by_user_id"
        case setByDisplayName = "set_by_display_name"
        case sourceDecisionId = "source_decision_id"
        case createdAt        = "created_at"
    }

    public var isActive: Bool { effectiveUntil == nil }
}

/// Decoded shape of `group_governance_versions.snapshot jsonb`. Mirrors
/// the keys `set_decision_rules` writes (`default_style`,
/// `default_method`, `default_legitimacy_source`, `quorum_min`, `notes`)
/// after `jsonb_strip_nulls` — every field is optional.
public struct GovernanceSnapshot: Decodable, Sendable, Hashable {
    public let defaultStyle: DecisionStyle?
    public let defaultMethod: DecisionMethod?
    public let defaultLegitimacySource: LegitimacySource?
    public let quorumMin: Int?
    public let notes: String?

    enum CodingKeys: String, CodingKey {
        case defaultStyle            = "default_style"
        case defaultMethod           = "default_method"
        case defaultLegitimacySource = "default_legitimacy_source"
        case quorumMin               = "quorum_min"
        case notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let styleRaw = try c.decodeIfPresent(String.self, forKey: .defaultStyle)
        self.defaultStyle = styleRaw.flatMap { DecisionStyle(rawValue: $0) }
        let methodRaw = try c.decodeIfPresent(String.self, forKey: .defaultMethod)
        self.defaultMethod = methodRaw.flatMap { DecisionMethod(rawValue: $0) }
        let legitimacyRaw = try c.decodeIfPresent(String.self, forKey: .defaultLegitimacySource)
        self.defaultLegitimacySource = legitimacyRaw.flatMap { LegitimacySource(rawValue: $0) }
        self.quorumMin = try c.decodeIfPresent(Int.self, forKey: .quorumMin)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
}
