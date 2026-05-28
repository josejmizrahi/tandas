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

    // MARK: - History / Events (Primitiva 13)

    /// `group_events_recent(p_group_id, p_limit, p_before)` —
    /// chronological feed of system events for a group, newest first.
    /// `before` is the cursor for pagination. Active-member gate.
    func groupEventsRecent(groupId: UUID, limit: Int, before: Date?) async throws -> [GroupEvent]

    // MARK: - Reputation feed + record (Primitiva 12, C4)

    /// `group_reputation_events(p_group_id, p_limit)` — group-wide
    /// reputation feed. Excludes private + non-active rows.
    /// Pre-joined with subject + actor display names.
    /// Active-member gate.
    func groupReputationEvents(groupId: UUID, limit: Int) async throws -> [GroupReputationEvent]

    /// `record_reputation_event(...)` — inserts an active reputation
    /// event. Requires permission `reputation.record`. Returns the
    /// inserted row.
    func recordReputationEvent(_ input: RecordReputationEventParams) async throws -> GroupReputationEvent

    // MARK: - Contributions (Primitiva 9, C3)

    /// `group_contributions_active(p_group_id, p_membership_id, p_resource_id)`
    /// — non-rejected contributions, optionally filtered by member or
    /// resource. Active-member gate.
    func groupContributionsActive(
        groupId: UUID,
        membershipId: UUID?,
        resourceId: UUID?
    ) async throws -> [GroupContribution]

    /// `log_contribution(...)` — self-claim a contribution (status =
    /// claimed). Requires `contribution.record`. Returns the new id.
    func logContribution(_ input: LogContributionParams) async throws -> UUID

    // MARK: - Mandates (Primitiva 23, B4)

    /// `group_mandates_active(p_group_id)` — currently-active mandates
    /// (status=active AND not expired), pre-joined with representative
    /// + granted_by display names. Active-member gate.
    func groupMandatesActive(groupId: UUID) async throws -> [GroupMandate]

    /// `grant_mandate(...)` — inserts a new mandate in `active` state.
    /// Requires permission `mandates.grant`. Returns the new mandate id.
    func grantMandate(_ input: GrantMandateParams) async throws -> UUID

    /// `revoke_mandate(p_mandate_id, p_reason)` — flips status to
    /// revoked (idempotent on non-active rows). Requires
    /// `mandates.revoke`.
    func revokeMandate(_ input: RevokeMandateParams) async throws

    // MARK: - Cultural norms (Primitiva 20, B5)

    /// `group_cultural_norms_active(p_group_id)` — proposed+endorsed
    /// norms for the group (excludes retired), pre-joined with the
    /// proposer's display_name. Sorted by endorsed_count DESC then
    /// created_at DESC. Active-member gate.
    func groupCulturalNormsActive(groupId: UUID) async throws -> [GroupCulturalNorm]

    /// `propose_cultural_norm(...)` — inserts a new norm in
    /// `proposed` state. Requires permission `culture.propose`.
    /// Returns the new norm id.
    func proposeCulturalNorm(_ input: ProposeCulturalNormParams) async throws -> UUID

    /// `endorse_cultural_norm(p_norm_id)` — increments endorsed_count
    /// and flips status proposed→endorsed on first endorse. Returns
    /// the new count. Requires `culture.endorse`.
    func endorseCulturalNorm(normId: UUID) async throws -> Int

    /// `retire_cultural_norm(p_norm_id, p_reason)` — flips status to
    /// retired (idempotent). Requires `group.update`.
    func retireCulturalNorm(_ input: RetireCulturalNormParams) async throws

    // MARK: - Money movements (Primitiva 19, A2.b)

    /// `group_money_movements(p_group_id, p_limit, p_filter, p_before_seq)`
    /// — paginated ledger feed for a group, newest first by seq. Filter
    /// = NULL means "all types"; otherwise restricts `transaction_type`
    /// to the listed strings. `beforeSeq` is the infinite-scroll cursor.
    /// Active-member gate.
    func groupMoneyMovements(
        groupId: UUID,
        limit: Int,
        filter: [String]?,
        beforeSeq: Int64?
    ) async throws -> [MoneyMovement]

    // MARK: - Disputes (Primitiva 14)

    /// `group_disputes_active(p_group_id, p_limit)` — open disputes
    /// (open/in_review/mediation/escalated), pre-joined with display
    /// names. Active-member gate.
    func groupDisputesActive(groupId: UUID, limit: Int) async throws -> [GroupDispute]

    /// `dispute_sanction(p_sanction_id, p_summary)` — opens a dispute
    /// against an existing sanction. Returns the new dispute id.
    /// Backend gates by `sanctions.dispute` permission + flips the
    /// sanction status to `disputed`.
    func disputeSanction(_ input: DisputeSanctionInput) async throws -> UUID

    // MARK: - Sanctions (Primitiva 11)

    /// `group_sanctions_active(p_group_id, p_limit)` — active+disputed
    /// sanctions for a group, pre-joined with target/issuer display
    /// names. Active-member gate.
    func groupSanctionsActive(groupId: UUID, limit: Int) async throws -> [GroupSanction]

    /// `issue_sanction(...)` — emits a sanction. Requires permission
    /// `sanctions.create`. Returns the sanction id. Monetary kinds
    /// also create a `group_obligations` row + link it back; backend
    /// also writes a reputation event automatically.
    func issueSanction(_ input: IssueSanctionInput) async throws -> UUID

    // MARK: - Reputation (Primitiva 12)

    /// `member_reputation_events(p_group_id, p_subject_membership_id, p_limit)`
    /// — visible reputation events for a member, newest first. RLS
    /// visibility tiers apply (public / members / private records.read).
    func memberReputationEvents(groupId: UUID,
                                subjectMembershipId: UUID,
                                limit: Int) async throws -> [GroupReputationEvent]

    // MARK: - Decisions / Voting (Primitiva 16, C1)

    /// `list_decisions_active(p_group_id)` — open decisions for a group,
    /// pre-joined with tally + caller's current vote. Active-member gate.
    func listDecisionsActive(groupId: UUID) async throws -> [GroupDecisionSummary]

    /// `list_decisions_history(p_group_id, p_limit)` — closed decisions
    /// (passed / rejected / cancelled) ordered by `decided_at DESC`,
    /// capped server-side. Active-member gate.
    func listDecisionsHistory(groupId: UUID, limit: Int) async throws -> [GroupDecisionSummary]

    /// `decision_detail(p_decision_id)` — single jsonb with options +
    /// tally + caller's most recent vote. Active-member gate.
    func decisionDetail(decisionId: UUID) async throws -> GroupDecisionDetail

    /// `start_vote(...)` — opens a new decision in `open` state.
    /// Requires permission `decisions.create`. Returns the decision id.
    func startVote(_ input: StartVoteParams) async throws -> UUID

    /// `cast_vote(p_decision_id, p_option_id, p_vote_value, p_reason)`
    /// — append-only ballot. Active-member gate (permission check is
    /// implicit via membership). Returns the inserted row id.
    func castVote(_ input: CastVoteParams) async throws -> UUID

    /// `finalize_vote(p_decision_id)` — closes a decision and writes
    /// the outcome. Returns the new status string (`passed` /
    /// `rejected` / `no_quorum` / pre-existing status when already
    /// closed).
    func finalizeVote(decisionId: UUID) async throws -> String

    /// `cancel_vote(p_decision_id, p_reason)` — cancels an open
    /// decision without computing tally. Requires `decisions.resolve`.
    func cancelVote(_ input: CancelVoteParams) async throws

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
