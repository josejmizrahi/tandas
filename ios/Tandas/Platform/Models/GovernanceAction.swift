import Foundation

/// Governance action evaluated by `GovernanceService`. Each case maps to one
/// key in `groups.governance` jsonb. Stable raw values — these are part of
/// the API surface for SQL helper functions like `group_governance_level`.
public enum GovernanceAction: String, Sendable, Hashable, CaseIterable {
    case modifyRules       = "whoCanModifyRules"
    case inviteMembers     = "whoCanInviteMembers"
    case removeMembers     = "whoCanRemoveMembers"
    case closeEvents       = "whoCanCloseEvents"
    case createVotes       = "whoCanCreateVotes"
    case modifyGovernance  = "whoCanModifyGovernance"
}
