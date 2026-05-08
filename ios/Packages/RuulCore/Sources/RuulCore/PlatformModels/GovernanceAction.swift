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
    /// V1: synthetic `.founder` level inside `GovernanceRules.level(for:)`,
    /// no jsonb field. V2 may add `whoCanIssueManualFine` to `GovernanceRules`
    /// struct + governance jsonb defaults migration when user-configurable.
    case issueManualFine   = "whoCanIssueManualFine"
    /// V1: synthetic `.founder` level inside `GovernanceRules.level(for:)`,
    /// no jsonb field. V2 may add `whoCanVoidFines` to `GovernanceRules`
    /// struct + governance jsonb defaults migration when user-configurable.
    case voidFine          = "whoCanVoidFines"
}
