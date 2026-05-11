import Foundation

/// Stable string identifier for a governable action. Phase 1 ships the
/// `rule.*` family; later phases add `expense.*`, `fund.*`, `member.*`, etc.
///
/// Stored as TEXT in `group_policies.target_action`. New cases are pure data
/// additions: the resolver, repos, and UI dispatch by string, so adding a
/// case here + adding policy rows is enough — no engine branching needed.
public enum TargetAction: String, Codable, Sendable, Hashable, CaseIterable {
    case ruleToggle       = "rule.toggle"
    case ruleUpdateAmount = "rule.update_amount"
    case ruleCreate       = "rule.create"
    case ruleDelete       = "rule.delete"
}

/// Kind of policy applied to a (group, action) tuple. Mirrors
/// `group_policies.policy_type`.
public enum PolicyType: String, Codable, Sendable, Hashable {
    /// Anyone matching the role gate may perform the action immediately.
    case direct
    /// The action opens a vote. Direct write is forbidden until the vote passes.
    case voteRequired = "vote_required"
    /// Only members holding `Permission.modifyRules` may perform it directly.
    case adminOnly    = "admin_only"
    /// Action is never permitted in this group.
    case denied
}

/// Voting parameters for `policy_type = vote_required`. Stored in
/// `group_policies.approval_config` jsonb.
public struct ApprovalConfig: Codable, Sendable, Hashable {
    public var quorumPercent: Int
    public var thresholdPercent: Int
    public var durationHours: Int
    public var eligibleVoters: EligibleVoters

    public enum EligibleVoters: String, Codable, Sendable, Hashable {
        case groupMembers = "group_members"
        case founders
    }

    public init(
        quorumPercent: Int = 50,
        thresholdPercent: Int = 50,
        durationHours: Int = 72,
        eligibleVoters: EligibleVoters = .groupMembers
    ) {
        self.quorumPercent    = quorumPercent
        self.thresholdPercent = thresholdPercent
        self.durationHours    = durationHours
        self.eligibleVoters   = eligibleVoters
    }

    public enum CodingKeys: String, CodingKey {
        case quorumPercent    = "quorum_percent"
        case thresholdPercent = "threshold_percent"
        case durationHours    = "duration_hours"
        case eligibleVoters   = "eligible_voters"
    }
}

/// Discriminated outcome from the `resolve_governance` RPC (mig 00088).
/// Mirrors the JSON envelope the function returns: a `decision` discriminator
/// plus extra fields for `vote_required`.
public enum PolicyDecision: Sendable, Hashable {
    case allowed
    case voteRequired(quorumPercent: Int, thresholdPercent: Int, durationHours: Int)
    case adminOnly
    case denied(reason: String)
}

extension PolicyDecision: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .decision)
        switch kind {
        case "allowed":
            self = .allowed
        case "vote_required":
            self = .voteRequired(
                quorumPercent:    try c.decode(Int.self, forKey: .quorumPercent),
                thresholdPercent: try c.decode(Int.self, forKey: .thresholdPercent),
                durationHours:    try c.decode(Int.self, forKey: .durationHours)
            )
        case "admin_only":
            self = .adminOnly
        case "denied":
            self = .denied(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "denied")
        default:
            self = .denied(reason: "unknown:\(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allowed:
            try c.encode("allowed", forKey: .decision)
        case .voteRequired(let q, let t, let d):
            try c.encode("vote_required", forKey: .decision)
            try c.encode(q, forKey: .quorumPercent)
            try c.encode(t, forKey: .thresholdPercent)
            try c.encode(d, forKey: .durationHours)
        case .adminOnly:
            try c.encode("admin_only", forKey: .decision)
        case .denied(let reason):
            try c.encode("denied", forKey: .decision)
            try c.encode(reason, forKey: .reason)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case decision
        case quorumPercent    = "quorum_percent"
        case thresholdPercent = "threshold_percent"
        case durationHours    = "duration_hours"
        case reason
    }
}

/// Row in `public.group_policies` (mig 00087). V1 reads policies grouped by
/// `(group, action)`; the editor in `GroupRulesSettingsView` upserts these.
public struct GroupPolicy: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public var policyType: PolicyType
    public var targetAction: TargetAction
    public var targetScope: String       // "group" | "resource_type" | "resource"
    public var targetResourceType: String?
    public var targetResourceId: UUID?
    public var approvalConfig: ApprovalConfig?
    public var enabled: Bool
    public var priority: Int

    public init(
        id: UUID = UUID(),
        groupId: UUID,
        policyType: PolicyType,
        targetAction: TargetAction,
        targetScope: String = "group",
        targetResourceType: String? = nil,
        targetResourceId: UUID? = nil,
        approvalConfig: ApprovalConfig? = nil,
        enabled: Bool = true,
        priority: Int = 100
    ) {
        self.id = id
        self.groupId = groupId
        self.policyType = policyType
        self.targetAction = targetAction
        self.targetScope = targetScope
        self.targetResourceType = targetResourceType
        self.targetResourceId = targetResourceId
        self.approvalConfig = approvalConfig
        self.enabled = enabled
        self.priority = priority
    }

    public enum CodingKeys: String, CodingKey {
        case id, enabled, priority
        case groupId            = "group_id"
        case policyType         = "policy_type"
        case targetAction       = "target_action"
        case targetScope        = "target_scope"
        case targetResourceType = "target_resource_type"
        case targetResourceId   = "target_resource_id"
        case approvalConfig     = "approval_config"
    }
}
