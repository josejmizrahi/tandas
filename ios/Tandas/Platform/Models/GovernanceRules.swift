import Foundation

/// Per-group governance configuration. Stored as `groups.governance` jsonb.
/// Each `whoCan*` field is a `PermissionLevel`; voting fields drive the
/// quorum / threshold / duration of any `Vote` opened in the group.
///
/// Defaults match the `recurring_dinner` template (see migration 00021).
/// `GovernanceService.canPerform` evaluates these against the current
/// member at action sites.
public struct GovernanceRules: Codable, Sendable, Equatable, Hashable {
    public var whoCanModifyRules:      PermissionLevel
    public var whoCanInviteMembers:    PermissionLevel
    public var whoCanRemoveMembers:    PermissionLevel
    public var whoCanCloseEvents:      PermissionLevel
    public var whoCanCreateVotes:      PermissionLevel
    public var whoCanModifyGovernance: PermissionLevel
    public var votingQuorumPercent:    Int
    public var votingThresholdPercent: Int
    public var votingDurationHours:    Int
    public var votesAreAnonymous:      Bool

    public init(
        whoCanModifyRules:      PermissionLevel = .founder,
        whoCanInviteMembers:    PermissionLevel = .founder,
        whoCanRemoveMembers:    PermissionLevel = .majorityVote,
        whoCanCloseEvents:      PermissionLevel = .host,
        whoCanCreateVotes:      PermissionLevel = .anyMember,
        whoCanModifyGovernance: PermissionLevel = .founder,
        votingQuorumPercent:    Int = 50,
        votingThresholdPercent: Int = 50,
        votingDurationHours:    Int = 72,
        votesAreAnonymous:      Bool = true
    ) {
        self.whoCanModifyRules      = whoCanModifyRules
        self.whoCanInviteMembers    = whoCanInviteMembers
        self.whoCanRemoveMembers    = whoCanRemoveMembers
        self.whoCanCloseEvents      = whoCanCloseEvents
        self.whoCanCreateVotes      = whoCanCreateVotes
        self.whoCanModifyGovernance = whoCanModifyGovernance
        self.votingQuorumPercent    = votingQuorumPercent
        self.votingThresholdPercent = votingThresholdPercent
        self.votingDurationHours    = votingDurationHours
        self.votesAreAnonymous      = votesAreAnonymous
    }

    /// Defaults for the V1 template `recurring_dinner`.
    public static let recurringDinnerDefaults = GovernanceRules()

    /// Tolerant decoder: missing keys fall back to defaults so legacy rows
    /// that never had governance written keep working until backfill runs.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GovernanceRules()
        self.whoCanModifyRules      = (try? c.decode(PermissionLevel.self, forKey: .whoCanModifyRules))      ?? defaults.whoCanModifyRules
        self.whoCanInviteMembers    = (try? c.decode(PermissionLevel.self, forKey: .whoCanInviteMembers))    ?? defaults.whoCanInviteMembers
        self.whoCanRemoveMembers    = (try? c.decode(PermissionLevel.self, forKey: .whoCanRemoveMembers))    ?? defaults.whoCanRemoveMembers
        self.whoCanCloseEvents      = (try? c.decode(PermissionLevel.self, forKey: .whoCanCloseEvents))      ?? defaults.whoCanCloseEvents
        self.whoCanCreateVotes      = (try? c.decode(PermissionLevel.self, forKey: .whoCanCreateVotes))      ?? defaults.whoCanCreateVotes
        self.whoCanModifyGovernance = (try? c.decode(PermissionLevel.self, forKey: .whoCanModifyGovernance)) ?? defaults.whoCanModifyGovernance
        self.votingQuorumPercent    = (try? c.decode(Int.self,  forKey: .votingQuorumPercent))    ?? defaults.votingQuorumPercent
        self.votingThresholdPercent = (try? c.decode(Int.self,  forKey: .votingThresholdPercent)) ?? defaults.votingThresholdPercent
        self.votingDurationHours    = (try? c.decode(Int.self,  forKey: .votingDurationHours))    ?? defaults.votingDurationHours
        self.votesAreAnonymous      = (try? c.decode(Bool.self, forKey: .votesAreAnonymous))      ?? defaults.votesAreAnonymous
    }

    /// Reads the permission level for a given action. Used by
    /// `GovernanceService` to gate mutable operations.
    public func level(for action: GovernanceAction) -> PermissionLevel {
        switch action {
        case .modifyRules:       return whoCanModifyRules
        case .inviteMembers:     return whoCanInviteMembers
        case .removeMembers:     return whoCanRemoveMembers
        case .closeEvents:       return whoCanCloseEvents
        case .createVotes:       return whoCanCreateVotes
        case .modifyGovernance:  return whoCanModifyGovernance
        }
    }
}
