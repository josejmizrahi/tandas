import Foundation

/// Single typed surface for every canonical RPC iOS is allowed to call in
/// Foundation scope (CanonicalRPCs_Contract.md §16-bis). Anything that
/// mutates server state goes through here; features and view models must
/// never touch `SupabaseClient` directly.
///
/// All methods throw `RuulError` (mapped by `RPCErrorMapper`). Implementors
/// are responsible for translating the underlying `PostgrestError`.
public protocol RuulRPCClient: Sendable {
    // MARK: - Identity & membership

    func createGroup(name: String,
                     slug: String?,
                     category: String?,
                     purposeDeclared: String?) async throws -> UUID

    func inviteMember(groupId: UUID,
                      email: String?,
                      phone: String?,
                      membershipType: String,
                      message: String?) async throws -> UUID

    func acceptInvite(code: String) async throws -> AcceptInviteResult

    func leaveGroup(groupId: UUID, reason: String?) async throws

    // MARK: - Money (self-party only in Foundation)

    func recordExpense(_ draft: ExpenseDraft, clientId: String?) async throws -> UUID

    func recordSettlement(_ draft: SettlementDraft, clientId: String?) async throws -> SettlementResult

    // MARK: - Reads

    func listMyGroups() async throws -> [GroupListItem]

    func groupSummary(groupId: UUID) async throws -> CanonicalGroupSummary

    func memberBalance(groupId: UUID, membershipId: UUID) async throws -> Decimal

    func memberObligationSummary(groupId: UUID, membershipId: UUID) async throws -> [ObligationSummary]

    func listMemberPermissions(groupId: UUID, userId: UUID?) async throws -> [String]

    /// `group_members(p_group_id) returns table(...)`. Pre-joined rows
    /// (membership × profile × roles) for the Members surface. RPC
    /// validates the caller is an active member of the group.
    func groupMembers(groupId: UUID) async throws -> [MemberListItem]

    /// `group_membership_boundary(p_group_id) returns table(...)` —
    /// Primitiva 2 unified view that UNIONs memberships with pending
    /// invites. Same auth rules as `groupMembers`.
    func groupMembershipBoundary(groupId: UUID) async throws -> [MembershipBoundaryItem]

    // MARK: - Purpose

    /// `group_purposes_active(p_group_id)` — returns the group's
    /// active purposes (declared/operative/emotional). Any active
    /// member can read.
    func groupPurposesActive(groupId: UUID) async throws -> [GroupPurpose]

    /// `set_group_purpose(p_group_id, p_kind, p_body, p_visibility)` —
    /// upsert by kind. Requires `purpose.set` permission.
    func setGroupPurpose(_ input: SetGroupPurposeInput) async throws -> GroupPurpose

    // MARK: - Rules

    /// `group_rules_active(p_group_id)` — active text rules for the
    /// group (engine rules filtered out). Any active member can read.
    func groupRulesActive(groupId: UUID) async throws -> [GroupRule]

    /// `create_text_rule(...)` — one-shot create+publish for a text
    /// rule. Requires `rules.create`.
    func createTextRule(_ input: CreateTextRuleInput) async throws -> CreateTextRuleResult

    /// `archive_rule(p_rule_id, p_reason)` — marks the rule
    /// `archived` and closes its current version. Requires
    /// `rules.archive`.
    func archiveRule(_ input: ArchiveRuleInput) async throws

    // MARK: - Resources

    /// `group_resources_active(p_group_id)` — active resource envelopes
    /// filtered to Foundation types (fund/space/asset/document/other).
    func groupResourcesActive(groupId: UUID) async throws -> [GroupResource]

    /// `create_group_resource(...)` — envelope-only create.
    /// Requires `resources.create`.
    func createGroupResource(_ input: CreateGroupResourceInput) async throws -> GroupResource

    /// `archive_resource(p_resource_id, p_reason)` — marks the
    /// resource archived. Requires `resources.archive`. Backend
    /// raises `resource has N open obligations` if obligations are
    /// outstanding; the canonical iOS surface treats that as a
    /// generic backend error.
    func archiveGroupResource(_ input: ArchiveGroupResourceInput) async throws

    // MARK: - Foundation status

    /// `group_foundation_status(p_group_id)` — per-primitive readiness
    /// (Members/Boundary/Purpose/Rules/Resources) + overall summary.
    /// Active-member gate.
    func groupFoundationStatus(groupId: UUID) async throws -> GroupFoundationStatus

    // MARK: - Decision rules

    /// `group_decision_rules(p_group_id)` — returns the active
    /// decision style + quorum + notes (with defaults baked in when
    /// the underlying jsonb is empty). Active-member gate.
    func groupDecisionRules(groupId: UUID) async throws -> GroupDecisionRules

    /// `set_decision_rules(p_group_id, p_default_style, p_quorum_min, p_notes)`
    /// — upsert in-place on `groups.decision_rules`. Requires
    /// `group.update` permission.
    func setDecisionRules(_ input: SetDecisionRulesInput) async throws -> GroupDecisionRules

    // MARK: - Reputation (Primitiva 12)

    /// `member_reputation_events(p_group_id, p_subject_membership_id, p_limit)`
    /// — visible reputation events for a member, newest first. RLS
    /// visibility tiers apply (public / members / private records.read).
    func memberReputationEvents(groupId: UUID,
                                subjectMembershipId: UUID,
                                limit: Int) async throws -> [GroupReputationEvent]

    // MARK: - Profile

    /// `my_profile() returns public.profiles`. Backend creates a blank
    /// row on first call so this never returns nil for an authenticated
    /// caller.
    func myProfile() async throws -> Profile

    /// `update_my_profile(p_display_name, p_username, p_avatar_url, p_bio)
    /// returns public.profiles`. Caller pre-trims; backend lowercases
    /// username and enforces uniqueness.
    func updateMyProfile(_ input: UpdateMyProfileInput) async throws -> Profile
}
