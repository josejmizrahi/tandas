import Foundation

/// Action-typed permission identifier used by `RoleDefinition.permissions`
/// to declare what a role can do.
///
/// Resolved via `GovernanceService.hasPermission(_:member:in:)`. When the
/// actor is wired with a SupabaseClient (live path), this calls the
/// server's `has_permission()` RPC (mig 00228) with a 30s TTL cache.
/// When wired without a client (tests / mocks / previews), it walks the
/// local `group.roles` catalog — same semantics, no I/O. Sprint E
/// fulfilled this contract; pre-Sprint-E this docstring was aspirational.
///
/// Independent from the legacy governance jsonb (`whoCan*` PermissionLevel)
/// evaluated by `GovernanceService.canPerform`. The two compose: an
/// action may be allowed via either the role permission OR the governance
/// `whoCan*` level. Server-side RLS + RPC gates remain authoritative.
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
    /// Issue a manual fine against another member. Gates
    /// `issue_manual_fine` RPC (mig 00232). Custom roles that need
    /// fine-issuing authority (e.g. `treasurer`) declare this
    /// permission instead of inheriting the legacy admin gate.
    case issueFine
    /// Cancel a fine after issue.
    case voidFine
    /// Mark a fine as paid on behalf of the fined member (external
    /// payment recording, off-app reconciliation). Gates the admin
    /// branch of `pay_fine`; the fined member can always pay their
    /// own fine without this permission.
    case markFinePaid
    /// Resolve a fine appeal (close vote early, override).
    case closeAppeal
    /// Open a vote of any type.
    case createVotes
    /// Cast a vote in any open vote.
    case castVote
    /// Govern event lifecycle: close/cancel an event, edit its
    /// metadata, check in another member. Hosts of their own event
    /// retain these powers without needing the permission (mig 00235).
    /// Custom roles like `event_coordinator` declare this permission
    /// to manage events they don't host themselves.
    case manageEvents
    /// Toggle group modules on/off (set_group_module RPC, mig 00236).
    /// Activates/deactivates capabilities like `basic_fines`,
    /// `appeal_voting`, `slot_assignment`. Cascades to dependencies
    /// and seeds/archives the module's rules.
    case manageModules

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

    // MARK: - Right resource_type (mig 00198 + 00200, slice 19)

    /// Transfer a right to another member. Server-side, mig 00206 gates
    /// this on (holder OR admin/founder); custom roles that need the
    /// authority (e.g. "treasurer" handling equity transfers) declare
    /// this permission instead of relying on the hard-coded admin check.
    case transferRight
    /// Delegate a right temporarily. Same gating as transfer.
    case delegateRight
    /// Revoke a right (terminal-ish admin action). Founder + custom
    /// roles with `manageRights`-shaped templates.
    case revokeRight
    /// Suspend a right (pause exercise without terminal revocation).
    case suspendRight
    /// Exercise a right. Default gate is "holder OR active delegate" —
    /// this permission lets custom templates extend the surface (e.g.
    /// committee role that can exercise any group right for audit).
    case exerciseRight

    case unknown(String)
}
