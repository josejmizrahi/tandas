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

    /// V3-INV: returns the created invite + its shareable code so the
    /// UI can show / copy / share it. Replaces the previous UUID-only
    /// return shape.
    func inviteMember(groupId: UUID,
                      email: String?,
                      phone: String?,
                      membershipType: String,
                      message: String?) async throws -> InviteCreated

    /// V3-INV: cancel a pending invitation. Authorized to the original
    /// inviter or anyone with `members.invite`. Backend blocks if the
    /// linked placeholder membership has open obligations.
    func revokeInvite(inviteId: UUID, reason: String?) async throws

    func acceptInvite(code: String) async throws -> AcceptInviteResult

    func leaveGroup(groupId: UUID, reason: String?) async throws

    // MARK: - Money (self-party only in Foundation)

    func recordExpense(_ draft: ExpenseDraft, clientId: String?) async throws -> UUID

    func recordSettlement(_ draft: SettlementDraft, clientId: String?) async throws -> SettlementResult

    /// V3 PARTE 5a — `pay_sanction(...)` self-party sugar. El target del
    /// sanction paga (resuelto server-side) y el backend delega a
    /// `record_settlement` con paid_to_kind='pool'. Rechaza over-pay
    /// (cap en `amount_outstanding`). Devuelve el `SettlementResult`
    /// usual. Para pagar on-behalf usar `recordSettlement` con `mandateId`.
    func paySanction(_ input: PaySanctionParams) async throws -> SettlementResult

    /// V3 — `record_contribution(...)` para depositar dinero al pool
    /// del grupo (o a un recurso específico cuando `resourceId != nil`).
    /// A diferencia de record_expense, NO genera obligations peer-to-peer:
    /// es un acredita-al-grupo directo. Returns la transaction_id.
    func recordContribution(_ input: RecordContributionParams) async throws -> UUID

    /// V3 — `group_pool_balance(p_group_id)` agregado del fondo común
    /// del grupo. Active-member gate. iOS lo muestra como header en el
    /// dashboard ("El grupo tiene $X").
    func groupPoolBalance(groupId: UUID) async throws -> GroupPoolBalance

    /// V3 — `record_pool_charge(p_group_id, p_target_membership_id,
    /// p_amount, p_unit, p_charge_kind, p_reason?, p_mandate_id?,
    /// p_client_id?)`. Crea una obligation pool-side contra un miembro
    /// (cuota / buy_in / fee). Requiere permission `pool_charge.record`
    /// (admin típicamente). Returns la obligation_id.
    func recordPoolCharge(_ input: RecordPoolChargeParams) async throws -> UUID

    /// V3 — `record_pool_charge_batch(...)` cobra el mismo cargo a N
    /// miembros atómicamente. Si una falla, rollback total. iOS lo
    /// usa cuando admin marca múltiples targets en IssuePoolChargeSheet.
    func recordPoolChargeBatch(_ input: RecordPoolChargeBatchParams) async throws -> Int

    // MARK: - Reads

    func listMyGroups() async throws -> [GroupListItem]

    func groupSummary(groupId: UUID) async throws -> CanonicalGroupSummary

    func memberBalance(groupId: UUID, membershipId: UUID) async throws -> Decimal

    func memberObligationSummary(groupId: UUID, membershipId: UUID) async throws -> [ObligationSummary]

    /// V3-SE-1 — Splitwise-style "Settle up" plan for the caller. Returns
    /// one item per peer counterparty with a non-zero netted balance.
    /// `netAmount > 0` ⇒ caller owes; `< 0` ⇒ counterparty owes caller.
    /// Excludes pool obligations by doctrine.
    func groupSettlementPlanForMember(groupId: UUID, membershipId: UUID) async throws -> [SettlementPlanItem]

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

    // MARK: - Rule engine (V2-G3.1)

    /// `list_rule_shapes()` — the institutional atom catalog: every
    /// trigger / condition / consequence iOS is allowed to pick from
    /// when authoring engine rules. Auth-only (catalog is global,
    /// shape `select` policy allows any caller).
    func listRuleShapes() async throws -> [RuleShape]

    /// `validate_rule_shape(p_shape jsonb)` — dry-run validator used by
    /// the iOS shape-builder for inline preview. Mirrors the checks
    /// `create_engine_rule(...)` runs on commit, so a `valid=true` here
    /// guarantees the same payload won't be rejected on save.
    func validateRuleShape(_ input: ValidateRuleShapeInput) async throws -> RuleShapeValidationResult

    /// `create_engine_rule(...)` — atomic propose+publish wrapper for
    /// engine rules. Server re-runs `validate_rule_shape` before write
    /// + requires `rules.publish` (consistent with
    /// `publish_rule_version`). Returns the new rule id + first
    /// version id, mirroring `createTextRule`.
    func createEngineRule(_ input: CreateEngineRuleInput) async throws -> CreateEngineRuleResult

    /// `group_rules_engine(p_group_id)` — active engine rules for a
    /// group, hydrated with their trigger + condition + consequences
    /// so iOS can render the rule explicably (which atoms it's wired
    /// to). Active-member gate.
    func groupRulesEngine(groupId: UUID) async throws -> [EngineRule]

    /// `group_rule_evaluations(p_group_id, p_limit, p_before)` —
    /// paginated feed of engine audit rows for a group, newest first.
    /// Each row carries the matched_predicate outcome
    /// `{passed, reason, evaluated_value}` and `actions_emitted[]`
    /// per-action results so iOS can render explainability without a
    /// second hop. Active-member gate.
    func groupRuleEvaluations(
        groupId: UUID,
        limit: Int,
        before: Date?
    ) async throws -> [GroupRuleEvaluation]

    /// `group_rule_evaluation_summary(p_group_id, p_window_hours)` —
    /// V2-G8.1 cheap aggregate for the home banner. Returns
    /// `{evaluations_count, last_evaluated_at, has_failures,
    /// window_hours}`. iOS uses count=0 as the invisibility signal.
    /// Active-member gate.
    func groupRuleEvaluationSummary(
        groupId: UUID,
        windowHours: Int
    ) async throws -> GroupRuleEvaluationSummary

    /// `system_event_engine_provenance(p_event_uuid_id)` — V2-G8.2
    /// reverse lookup from a `group_events` row to the
    /// `group_rule_evaluations` row that originated it (if any). Drives
    /// the "¿Por qué pasó esto?" sheet. Active-member gate.
    func systemEventEngineProvenance(
        eventUuid: UUID
    ) async throws -> SystemEventProvenance

    /// `group_sanction_payment_status(p_sanction_id)` — V2-G4.1 read
    /// RPC for "Pendiente X de Y" + payment history per sanction. The
    /// backend already supports partial payments via the FIFO settlement
    /// allocator; this surface makes the progress visible. Active-member
    /// gate.
    func groupSanctionPaymentStatus(
        sanctionId: UUID
    ) async throws -> SanctionPaymentStatus

    /// `propose_sanction_payment_plan(...)` — V2-G4.2 self-party only
    /// (target of the sanction). Auto-active al propose. No cron
    /// auto-debit yet (V3) — el plan es guía + tracking.
    func proposeSanctionPaymentPlan(
        _ input: ProposeSanctionPaymentPlanParams
    ) async throws -> UUID

    /// `cancel_sanction_payment_plan(p_plan_id, p_reason)` — V2-G4.2
    /// target O admin con `sanction.review`.
    func cancelSanctionPaymentPlan(
        _ input: CancelSanctionPaymentPlanParams
    ) async throws

    /// `group_sanction_payment_plan_active(p_sanction_id)` — V2-G4.2
    /// read RPC. `active=false` cuando no hay plan vivo.
    func groupSanctionPaymentPlanActive(
        sanctionId: UUID
    ) async throws -> SanctionPaymentPlan

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

    /// `set_membership_state(p_membership_id, p_new_state, p_reason, p_until)`
    /// — moves a membership between `active|suspended|left|banned|requested|invited`.
    /// Permissions: `members.suspend` for suspended; `members.remove`
    /// for banned (and non-self left); `members.update` otherwise.
    func setMembershipState(_ input: SetMembershipStateParams) async throws

    /// `set_resource_ownership(...)` — switches `ownership_kind` (and
    /// optionally `owner_membership_id`) on an existing resource.
    /// Requires `resources.transfer`. Records a `resource.ownership_changed`
    /// system event.
    func setResourceOwnership(_ input: SetResourceOwnershipParams) async throws

    /// `group_resource_detail(p_resource_id)` — augmented envelope +
    /// per-type `subtype` jsonb. Active-member gate.
    func groupResourceDetail(resourceId: UUID) async throws -> GroupResourceDetail

    // MARK: - Asset Fase B.1

    /// `assign_asset_custodian(...)` — sets or replaces the custodian.
    /// Requires `resources.update`. Emits `resource.assigned` with
    /// `role=custodian`. Idempotent via `p_client_id`.
    func assignAssetCustodian(_ input: AssignAssetCustodianParams) async throws -> UUID

    /// `release_asset_custodian(...)` — clears the custodian. Requires
    /// `resources.update`. Emits `resource.returned`. Idempotent.
    func releaseAssetCustodian(_ input: ReleaseAssetCustodianParams) async throws -> UUID

    /// `mark_asset_condition(...)` — updates condition. Emits
    /// `resource.damaged` (→damaged), `resource.repaired`
    /// (damaged→repaired) or `resource.status_changed`. Requires
    /// `resources.update`. Idempotent via `p_client_id`.
    func markAssetCondition(_ input: MarkAssetConditionParams) async throws -> UUID

    /// `record_asset_valuation(...)` — appends a row to
    /// `group_resource_asset_valuations` and updates
    /// `group_resource_assets.current_value`. Requires
    /// `resources.update_value`.
    func recordAssetValuation(_ input: RecordAssetValuationParams) async throws

    // MARK: - Fund Fase B.2

    /// `lock_fund(...)` — sets `locked_at=now()` if not already locked.
    /// Emits `resource.status_changed` (`to=locked`). Requires
    /// `resources.update`. Idempotent.
    func lockFund(_ input: LockFundParams) async throws -> UUID

    /// `unlock_fund(...)` — sets `locked_at=NULL`. Emits
    /// `resource.status_changed` (`to=unlocked`). Requires
    /// `resources.update`. Idempotent.
    func unlockFund(_ input: UnlockFundParams) async throws -> UUID

    /// `set_fund_threshold(...)` — updates `threshold_target` (and
    /// optionally `currency`). Emits `resource.status_changed`
    /// (`kind=threshold_updated`). Requires `resources.update`.
    /// Idempotent via `p_client_id`.
    func setFundThreshold(_ input: SetFundThresholdParams) async throws -> UUID

    // MARK: - Space / Bookings Fase B.3

    /// `book_resource(...)` — creates a confirmed booking. Backend
    /// rejects overlapping confirmed bookings + invalid windows.
    /// Requires `bookings.create`. Idempotent via `p_client_id`.
    func bookResource(_ input: BookResourceParams) async throws -> UUID

    /// `cancel_booking(...)` — inserts a cancellation audit row.
    /// Requires `bookings.cancel` OR self-ownership of the booking.
    func cancelBooking(_ input: CancelBookingParams) async throws -> UUID

    /// `list_bookings_for_resource(...)` — bookings for a resource
    /// optionally filtered by date window. Active-member gate.
    func listBookingsForResource(_ input: ListBookingsForResourceParams) async throws -> [GroupResourceBooking]

    // MARK: - Right Fase B.4

    /// `grant_right(...)` — grants or re-grants a right to a holder.
    /// Refreshes granted_at and clears expired_at/revoked_at. Requires
    /// `resources.update`. Emits `resource.assigned` (role=holder).
    func grantRight(_ input: GrantRightParams) async throws -> UUID

    /// `transfer_right(...)` — transfers an active transferable right.
    /// Backend rejects when not active or not transferable.
    /// Requires `resources.update`. Emits `resource.transferred`.
    func transferRight(_ input: TransferRightParams) async throws -> UUID

    /// `revoke_right(...)` — sets revoked_at. Requires `resources.update`.
    /// Emits `resource.status_changed` (to=revoked).
    func revokeRight(_ input: RevokeRightParams) async throws -> UUID

    /// `expire_right(...)` — marks a right as expired once its
    /// expires_at deadline has passed. Requires `resources.update`.
    /// Emits `resource.status_changed` (to=expired).
    func expireRight(_ input: ExpireRightParams) async throws -> UUID

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

    /// V3 PARTE 7c — `group_governance_versions(p_group_id, p_limit)`
    /// historial append-only de snapshots de `groups.decision_rules`.
    /// Pre-joined con profile.display_name del actor. Active-member gate.
    func groupGovernanceVersions(groupId: UUID, limit: Int) async throws -> [GroupGovernanceVersion]

    // MARK: - History / Events (Primitiva 13)

    /// `group_events_recent(p_group_id, p_limit, p_before)` —
    /// chronological feed of system events for a group, newest first.
    /// `before` is the cursor for pagination. Active-member gate.
    func groupEventsRecent(groupId: UUID, limit: Int, before: Date?) async throws -> [GroupEvent]

    /// V3 Batch B-1 — `group_events_for_member(p_group_id, p_membership_id, p_limit)`
    /// timeline filtrada por miembro: entity-side (mutaciones a la
    /// membership) + actor-side (cosas que esta persona hizo).
    /// Active-member gate.
    func groupEventsForMember(groupId: UUID, membershipId: UUID, limit: Int) async throws -> [GroupEvent]

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

    /// `verify_contribution(p_contribution_id, p_outcome, p_note)` —
    /// flips a `claimed` contribution to `verified` or `rejected`.
    /// Requires `contribution.verify`. Verifier must not be the
    /// contribution subject (server-side check). On `verified`, the
    /// backend appends a `contribution_recognized` reputation event.
    func verifyContribution(_ input: VerifyContributionParams) async throws

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

    /// `promote_norm_to_rule(p_norm_id, p_rule_type, p_severity)` —
    /// V2-G6 atomic promotion: creates the rule (status=active,
    /// execution_mode=text) and retires the source norm in one
    /// transaction. Requires `rules.create`. Returns the new rule id,
    /// first version id and the retired norm id.
    func promoteNormToRule(_ input: PromoteNormToRuleInput) async throws -> PromoteNormToRuleResult

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

    /// `dispute_detail(p_dispute_id)` — single dispute pre-joined with
    /// opener/respondent/mediator display names + event count.
    /// Active-member gate.
    func disputeDetail(disputeId: UUID) async throws -> GroupDisputeDetail

    /// `list_dispute_events(p_dispute_id, p_limit)` — chronological
    /// timeline for a dispute (ASC by created_at). Active-member gate.
    func listDisputeEvents(disputeId: UUID, limit: Int) async throws -> [GroupDisputeEvent]

    /// `open_dispute(...)` — generic open against any subject (sanction
    /// / rule / resource / member / other). Requires `disputes.open`.
    /// Returns the new dispute id.
    func openDispute(_ input: OpenDisputeInput) async throws -> UUID

    /// `append_dispute_event(p_dispute_id, p_event_type, p_body, p_metadata)`
    /// — comment / evidence / mediation note. Append-only. Backend
    /// gates by opener / respondent / mediator OR `disputes.mediate`.
    func appendDisputeEvent(_ input: AppendDisputeEventInput) async throws -> UUID

    /// `record_dispute_resolution(p_dispute_id, p_method, p_resolution_text, p_outcome)`
    /// — closes the dispute with a resolution. Requires
    /// `disputes.resolve` (or assigned mediator).
    func recordDisputeResolution(_ input: RecordDisputeResolutionInput) async throws

    /// `escalate_dispute_to_vote(p_dispute_id, p_decision_title, p_decision_method, p_closes_at)`
    /// — flips the dispute to `escalated` and creates a linked
    /// `group_decisions` row. Returns the new decision id.
    func escalateDisputeToVote(_ input: EscalateDisputeToVoteInput) async throws -> UUID

    // MARK: - Notifications + Privacy (B7)

    /// `my_notification_preferences(p_group_id)` — caller's stored
    /// preference rows for a group. Missing rows = enabled by default
    /// (iOS merges with curated category × channel grid).
    /// Active-member gate.
    func myNotificationPreferences(groupId: UUID) async throws -> [NotificationPreferenceRow]

    /// `set_notification_preference(...)` — upserts a single
    /// `(group, category, channel)` row. Returns void.
    func setNotificationPreference(_ input: SetNotificationPreferenceInput) async throws

    /// `register_my_notification_token(p_token, p_platform)` —
    /// upserts the caller's APNs/FCM device token into
    /// `notification_tokens` (unique on `user_id+token`). Bumps
    /// `updated_at` on re-registration. authenticated-only.
    /// Returns the row id.
    func registerMyNotificationToken(_ input: RegisterMyNotificationTokenInput) async throws -> UUID

    /// `group_visibility(p_group_id)` — returns the current
    /// `groups.visibility` text. Active-member gate.
    func groupVisibility(groupId: UUID) async throws -> String

    /// `set_group_visibility(p_group_id, p_visibility)` — updates
    /// `groups.visibility` to one of `private` / `unlisted` /
    /// `public`. Requires `group.update`. Returns the new value.
    func setGroupVisibility(_ input: SetGroupVisibilityInput) async throws -> String

    // MARK: - Dissolution (Primitiva 25, B8)

    /// `group_dissolution_active(p_group_id)` — returns the active
    /// dissolution row (proposed/approved/liquidating) as a domain
    /// model, or `nil` when none. Active-member gate. Includes
    /// `open_obligations_count` so the surface can gate finalize.
    func groupDissolutionActive(groupId: UUID) async throws -> GroupDissolution?

    /// `propose_dissolution(...)` — inserts a `proposed` row + auto-
    /// creates the linked supermajority vote. Requires
    /// `group.dissolve`. Returns the new dissolution id.
    func proposeDissolution(_ input: ProposeDissolutionInput) async throws -> UUID

    /// `finalize_dissolution(p_dissolution_id)` — flips group to
    /// `dissolved` + all active memberships to `left`. Requires
    /// `group.dissolve` and all obligations resolved (backend raises
    /// otherwise).
    func finalizeDissolution(_ input: FinalizeDissolutionInput) async throws

    // MARK: - Roles + Permissions (Primitiva 17, B3)

    /// `list_group_roles(p_group_id)` — roles for a group with the
    /// joined permission_keys and member_count pre-flattened.
    /// Active-member gate.
    func listGroupRoles(groupId: UUID) async throws -> [GroupRole]

    /// `list_permissions_catalog()` — static permissions catalog
    /// grouped by category. Authenticated-only gate (no group
    /// context). The catalog is global so this is safe to cache.
    func listPermissionsCatalog() async throws -> [PermissionCatalogEntry]

    /// `create_custom_role(p_group_id, p_key, p_name, p_description, p_permission_keys)`
    /// — creates a new non-system role with the supplied permissions.
    /// Requires `roles.manage`. Returns the new role id.
    func createCustomRole(_ input: CreateCustomRoleInput) async throws -> UUID

    /// `update_role_permissions(p_role_id, p_permission_keys)` —
    /// patches the role's permission set (overwrite semantics).
    /// Requires `roles.manage`. Backend raises on system roles.
    func updateRolePermissions(_ input: UpdateRolePermissionsInput) async throws

    /// `assign_role_to_member(p_membership_id, p_role_id)` —
    /// idempotent assignment. Requires `roles.manage`.
    func assignRoleToMember(_ input: AssignRoleToMemberInput) async throws

    /// `revoke_role_from_member(p_membership_id, p_role_id)` — removes
    /// the role from the member. Requires `roles.manage`. Backend
    /// blocks removing the member's last role.
    func revokeRoleFromMember(_ input: RevokeRoleFromMemberInput) async throws

    // MARK: - Boundary policy (Primitiva 2, B2)

    /// `group_boundary_policy(p_group_id)` — returns the active
    /// boundary policy (entry/inviter/approval/exit). Defaults baked
    /// in when groups.settings.boundary_policy is empty. Active-member
    /// gate.
    func groupBoundaryPolicy(groupId: UUID) async throws -> GroupBoundaryPolicy

    /// `set_group_boundary_policy(p_group_id, p_entry_mode,
    /// p_who_can_invite, p_requires_approval, p_exit_mode, p_notes)`
    /// — upsert in-place on `groups.settings.boundary_policy`.
    /// Requires `group.update` permission.
    func setGroupBoundaryPolicy(_ input: SetGroupBoundaryPolicyInput) async throws -> GroupBoundaryPolicy

    // MARK: - Rituals (Primitiva 21, B6)

    /// `list_group_resource_series(p_group_id, p_rituals_only, p_include_past)`
    /// — series for the group; defaults to ritual-flagged ones only
    /// and excludes ended series. Active-member gate.
    func listGroupResourceSeries(
        groupId: UUID,
        ritualsOnly: Bool,
        includePast: Bool
    ) async throws -> [GroupResourceSeries]

    /// `create_resource_series(...)` — creates a new ritual/recurrence
    /// row. Requires `resources.create`. Returns the new series id.
    func createResourceSeries(_ input: CreateResourceSeriesInput) async throws -> UUID

    /// `update_resource_series(...)` — patches the ritual annotation
    /// or end date. Requires `resources.update`.
    func updateResourceSeries(_ input: UpdateResourceSeriesInput) async throws

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

    /// `cast_vote(p_decision_id, p_option_id, p_vote_value, p_reason, p_weight)`
    /// — append-only ballot. Active-member gate (permission check is
    /// implicit via membership). `p_weight` is only honored when the
    /// decision's `method='weighted'`. Returns the inserted row id.
    func castVote(_ input: CastVoteParams) async throws -> UUID

    /// V2-G9 — `cast_ranked_vote(p_decision_id, p_rankings, p_reason)`
    /// inserts one ballot per ranked option using Borda points
    /// (`weight = N - rank`). Only applies to `method='ranked_choice'`.
    func castRankedVote(_ input: CastRankedVoteParams) async throws -> UUID

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
