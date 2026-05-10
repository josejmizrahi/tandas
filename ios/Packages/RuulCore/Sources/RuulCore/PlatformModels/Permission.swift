import Foundation

/// Action-typed permission identifier used by `RoleDefinition.permissions`
/// to declare what a role can do. Consulted by
/// `GovernanceService.hasPermission` (which calls the server's
/// `has_permission()` RPC, mig 00063) before falling back to the
/// legacy governance jsonb (`whoCan*` PermissionLevel).
///
/// Foundation slice ships the V1 actions actually checked today plus
/// Phase 2/3 placeholders so templates declaring custom roles
/// (`seat_owner`, `treasurer`, …) can reference them now even though
/// the RLS rewire that enforces them in the database lands in
/// Phase 5.
// @codegen:enum
public enum Permission: Codable, Sendable, Hashable {
    // MARK: - V1 (enforced today via RLS / governance jsonb)

    /// Edit `groups.governance` (whoCan* keys, voting thresholds).
    case modifyGovernance
    /// Edit rules directly (toggle is_active, edit fine amount).
    case modifyRules
    /// Promote/demote/reorder members.
    case modifyMembers
    /// Assign role strings to other members (Phase 5 RPC).
    case assignRoles
    /// Remove a member from the group.
    case removeMember
    /// Cancel a fine after issue.
    case voidFine
    /// Resolve a fine appeal (close vote early, override).
    case closeAppeal
    /// Open a vote of any type.
    case createVotes
    /// Cast a vote in any open vote.
    case castVote

    // MARK: - Phase 2 (`shared_resource`)

    /// Assign a slot to a member (palco, casa, cabaña).
    case assignSlot
    /// Book a slot for self.
    case bookSlot
    /// Approve a slot swap request.
    case approveSlotSwap

    // MARK: - Phase 3 (`pool` / tandas)

    /// Add money to the fund.
    case fundContribute
    /// Withdraw money from the fund.
    case fundWithdraw
    /// Read fund history without write access.
    case fundAudit

    // MARK: - Phase 4 (expenses, future)

    /// Submit a group expense for approval.
    case expenseSubmit
    /// Approve a group expense.
    case expenseApprove

    case unknown(String)
}
