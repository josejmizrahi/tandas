import Foundation
import Supabase

/// Live implementation of `RuulRPCClient` against the canonical dev backend.
/// All write paths use `client.rpc(...)`; reads either hit a read RPC or
/// `client.from(...)` for the membership-joined groups list. Every error
/// passes through `RPCErrorMapper`.
public struct SupabaseRuulRPCClient: RuulRPCClient {
    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Identity & membership

    public func createGroup(name: String,
                            slug: String?,
                            category: String?,
                            purposeDeclared: String?) async throws -> UUID {
        let params = RPCCreateGroupParams(name: name, slug: slug, category: category, purposeDeclared: purposeDeclared)
        return try await callReturningUUID("create_group", params: params)
    }

    public func inviteMember(groupId: UUID,
                             email: String?,
                             phone: String?,
                             membershipType: String,
                             message: String?) async throws -> UUID {
        let params = InviteMemberParams(
            groupId: groupId,
            email: email,
            phone: phone,
            membershipType: membershipType,
            message: message
        )
        return try await callReturningUUID("invite_member", params: params)
    }

    public func acceptInvite(code: String) async throws -> AcceptInviteResult {
        let params = AcceptInviteParams(code: code)
        let rows: [AcceptInviteRow] = try await callReturningArray("accept_invite", params: params)
        guard let row = rows.first else {
            throw RuulError.unexpected(message: "accept_invite returned no rows")
        }
        return AcceptInviteResult(groupId: row.groupId, membershipId: row.membershipId)
    }

    public func leaveGroup(groupId: UUID, reason: String?) async throws {
        let params = LeaveGroupParams(groupId: groupId, reason: reason)
        try await callVoid("leave_group", params: params)
    }

    // MARK: - Money

    public func recordExpense(_ draft: ExpenseDraft, clientId: String?) async throws -> UUID {
        let params = RecordExpenseParams(draft: draft, clientId: clientId)
        return try await callReturningUUID("record_expense", params: params)
    }

    public func recordSettlement(_ draft: SettlementDraft, clientId: String?) async throws -> SettlementResult {
        let params = RecordSettlementParams(draft: draft, clientId: clientId)
        let rows: [RecordSettlementRow] = try await callReturningArray("record_settlement", params: params)
        guard let row = rows.first else {
            throw RuulError.unexpected(message: "record_settlement returned no rows")
        }
        return SettlementResult(settlementId: row.settlementId, transactionId: row.transactionId)
    }

    // MARK: - Reads

    public func listMyGroups() async throws -> [GroupListItem] {
        // Canonical surface: `list_my_groups()` SECURITY DEFINER filters
        // by auth.uid() + status='active' and DISTINCTs by group_id —
        // iOS no longer touches `group_memberships` directly (pre-fix
        // doing `from('group_memberships').select(...)` produced one
        // row per OTHER member, since RLS lets active members see the
        // whole group's membership rows; the same group rendered N
        // times).
        do {
            let rows: [ListMyGroupsRow] = try await client
                .rpc("list_my_groups")
                .execute()
                .value
            return rows.map { $0.toDomain() }
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func groupSummary(groupId: UUID) async throws -> CanonicalGroupSummary {
        let params = GroupSummaryParams(groupId: groupId)
        do {
            let dto: GroupSummaryDTO = try await client
                .rpc("group_summary", params: params)
                .execute()
                .value
            return dto.toDomain()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func memberBalance(groupId: UUID, membershipId: UUID) async throws -> Decimal {
        let params = MemberBalanceParams(groupId: groupId, membershipId: membershipId)
        do {
            let value: Decimal = try await client
                .rpc("member_balance_in_group", params: params)
                .execute()
                .value
            return value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func memberObligationSummary(groupId: UUID, membershipId: UUID) async throws -> [ObligationSummary] {
        let params = MemberObligationSummaryParams(groupId: groupId, membershipId: membershipId)
        do {
            let rows: [MemberObligationRow] = try await client
                .rpc("member_obligation_summary", params: params)
                .execute()
                .value
            return rows.map { $0.toDomain() }
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func listMemberPermissions(groupId: UUID, userId: UUID?) async throws -> [String] {
        let params = ListMemberPermissionsParams(groupId: groupId, userId: userId)
        do {
            let rows: [String] = try await client
                .rpc("list_member_permissions", params: params)
                .execute()
                .value
            return rows
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func groupMembers(groupId: UUID) async throws -> [MemberListItem] {
        let params = GroupMembersParams(groupId: groupId)
        do {
            let rows: [GroupMemberRow] = try await client
                .rpc("group_members", params: params)
                .execute()
                .value
            return rows.map { $0.toDomain() }
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func groupMembershipBoundary(groupId: UUID) async throws -> [MembershipBoundaryItem] {
        let params = GroupMembershipBoundaryParams(groupId: groupId)
        do {
            return try await client
                .rpc("group_membership_boundary", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Purpose

    public func groupPurposesActive(groupId: UUID) async throws -> [GroupPurpose] {
        let params = GroupPurposesActiveParams(groupId: groupId)
        do {
            return try await client
                .rpc("group_purposes_active", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func setGroupPurpose(_ input: SetGroupPurposeInput) async throws -> GroupPurpose {
        do {
            return try await client
                .rpc("set_group_purpose", params: input)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Rules

    public func groupRulesActive(groupId: UUID) async throws -> [GroupRule] {
        let params = GroupRulesActiveParams(groupId: groupId)
        do {
            return try await client
                .rpc("group_rules_active", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func createTextRule(_ input: CreateTextRuleInput) async throws -> CreateTextRuleResult {
        do {
            let rows: [CreateTextRuleResult] = try await client
                .rpc("create_text_rule", params: input)
                .execute()
                .value
            guard let row = rows.first else {
                throw RuulError.unexpected(message: "create_text_rule returned no rows")
            }
            return row
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func archiveRule(_ input: ArchiveRuleInput) async throws {
        do {
            _ = try await client.rpc("archive_rule", params: input).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Rule engine (V2-G3.1)

    public func listRuleShapes() async throws -> [RuleShape] {
        do {
            return try await client
                .rpc("list_rule_shapes")
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func validateRuleShape(_ input: ValidateRuleShapeInput) async throws -> RuleShapeValidationResult {
        do {
            return try await client
                .rpc("validate_rule_shape", params: input)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func createEngineRule(_ input: CreateEngineRuleInput) async throws -> CreateEngineRuleResult {
        do {
            let rows: [CreateEngineRuleResult] = try await client
                .rpc("create_engine_rule", params: input)
                .execute()
                .value
            guard let row = rows.first else {
                throw RuulError.unexpected(message: "create_engine_rule returned no rows")
            }
            return row
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func groupRulesEngine(groupId: UUID) async throws -> [EngineRule] {
        let params = GroupRulesEngineParams(groupId: groupId)
        do {
            return try await client
                .rpc("group_rules_engine", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func groupRuleEvaluations(
        groupId: UUID,
        limit: Int,
        before: Date?
    ) async throws -> [GroupRuleEvaluation] {
        let params = GroupRuleEvaluationsParams(groupId: groupId, limit: limit, before: before)
        do {
            return try await client
                .rpc("group_rule_evaluations", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func groupRuleEvaluationSummary(
        groupId: UUID,
        windowHours: Int
    ) async throws -> GroupRuleEvaluationSummary {
        let params = GroupRuleEvaluationSummaryParams(groupId: groupId, windowHours: windowHours)
        do {
            return try await client
                .rpc("group_rule_evaluation_summary", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func systemEventEngineProvenance(
        eventUuid: UUID
    ) async throws -> SystemEventProvenance {
        let params = SystemEventEngineProvenanceParams(eventUuid: eventUuid)
        do {
            return try await client
                .rpc("system_event_engine_provenance", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func groupSanctionPaymentStatus(
        sanctionId: UUID
    ) async throws -> SanctionPaymentStatus {
        let params = GroupSanctionPaymentStatusParams(sanctionId: sanctionId)
        do {
            return try await client
                .rpc("group_sanction_payment_status", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Resources

    public func groupResourcesActive(groupId: UUID) async throws -> [GroupResource] {
        let params = GroupResourcesActiveParams(groupId: groupId)
        do {
            return try await client
                .rpc("group_resources_active", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func createGroupResource(_ input: CreateGroupResourceInput) async throws -> GroupResource {
        do {
            return try await client
                .rpc("create_group_resource", params: input)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func archiveGroupResource(_ input: ArchiveGroupResourceInput) async throws {
        do {
            _ = try await client.rpc("archive_resource", params: input).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func setMembershipState(_ input: SetMembershipStateParams) async throws {
        do {
            _ = try await client.rpc("set_membership_state", params: input).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func setResourceOwnership(_ input: SetResourceOwnershipParams) async throws {
        do {
            _ = try await client.rpc("set_resource_ownership", params: input).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Foundation status

    public func groupFoundationStatus(groupId: UUID) async throws -> GroupFoundationStatus {
        let params = GroupFoundationStatusParams(groupId: groupId)
        do {
            return try await client
                .rpc("group_foundation_status", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Decision rules

    public func groupDecisionRules(groupId: UUID) async throws -> GroupDecisionRules {
        let params = GroupDecisionRulesParams(groupId: groupId)
        do {
            return try await client
                .rpc("group_decision_rules", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func setDecisionRules(_ input: SetDecisionRulesInput) async throws -> GroupDecisionRules {
        do {
            return try await client
                .rpc("set_decision_rules", params: input)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - History / Events (Primitiva 13)

    public func groupEventsRecent(groupId: UUID, limit: Int, before: Date?) async throws -> [GroupEvent] {
        let params = GroupEventsRecentParams(groupId: groupId, limit: limit, before: before)
        do {
            return try await client
                .rpc("group_events_recent", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Reputation feed + record (Primitiva 12, C4)

    public func groupReputationEvents(groupId: UUID, limit: Int) async throws -> [GroupReputationEvent] {
        let params = GroupReputationEventsParams(groupId: groupId, limit: limit)
        do {
            return try await client
                .rpc("group_reputation_events", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func recordReputationEvent(_ input: RecordReputationEventParams) async throws -> GroupReputationEvent {
        do {
            return try await client.rpc("record_reputation_event", params: input).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Contributions (Primitiva 9, C3)

    public func groupContributionsActive(
        groupId: UUID,
        membershipId: UUID?,
        resourceId: UUID?
    ) async throws -> [GroupContribution] {
        let params = GroupContributionsActiveParams(
            groupId: groupId,
            membershipId: membershipId,
            resourceId: resourceId
        )
        do {
            return try await client
                .rpc("group_contributions_active", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func logContribution(_ input: LogContributionParams) async throws -> UUID {
        do {
            return try await client.rpc("log_contribution", params: input).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func verifyContribution(_ input: VerifyContributionParams) async throws {
        do {
            _ = try await client.rpc("verify_contribution", params: input).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Mandates (Primitiva 23, B4)

    public func groupMandatesActive(groupId: UUID) async throws -> [GroupMandate] {
        let params = GroupMandatesActiveParams(groupId: groupId)
        do {
            return try await client
                .rpc("group_mandates_active", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func grantMandate(_ input: GrantMandateParams) async throws -> UUID {
        do {
            return try await client.rpc("grant_mandate", params: input).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func revokeMandate(_ input: RevokeMandateParams) async throws {
        do {
            _ = try await client.rpc("revoke_mandate", params: input).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Cultural norms (Primitiva 20, B5)

    public func groupCulturalNormsActive(groupId: UUID) async throws -> [GroupCulturalNorm] {
        let params = GroupCulturalNormsActiveParams(groupId: groupId)
        do {
            return try await client
                .rpc("group_cultural_norms_active", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func proposeCulturalNorm(_ input: ProposeCulturalNormParams) async throws -> UUID {
        do {
            return try await client.rpc("propose_cultural_norm", params: input).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func endorseCulturalNorm(normId: UUID) async throws -> Int {
        let params = EndorseCulturalNormParams(normId: normId)
        do {
            return try await client.rpc("endorse_cultural_norm", params: params).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func retireCulturalNorm(_ input: RetireCulturalNormParams) async throws {
        do {
            _ = try await client.rpc("retire_cultural_norm", params: input).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func promoteNormToRule(_ input: PromoteNormToRuleInput) async throws -> PromoteNormToRuleResult {
        do {
            let rows: [PromoteNormToRuleResult] = try await client
                .rpc("promote_norm_to_rule", params: input)
                .execute()
                .value
            guard let row = rows.first else {
                throw RuulError.unexpected(message: "promote_norm_to_rule returned no rows")
            }
            return row
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Money movements (Primitiva 19, A2.b)

    public func groupMoneyMovements(
        groupId: UUID,
        limit: Int,
        filter: [String]?,
        beforeSeq: Int64?
    ) async throws -> [MoneyMovement] {
        let params = GroupMoneyMovementsParams(
            groupId: groupId,
            limit: limit,
            filter: filter,
            beforeSeq: beforeSeq
        )
        do {
            return try await client
                .rpc("group_money_movements", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Disputes (Primitiva 14)

    public func groupDisputesActive(groupId: UUID, limit: Int) async throws -> [GroupDispute] {
        let params = GroupDisputesActiveParams(groupId: groupId, limit: limit)
        do {
            return try await client
                .rpc("group_disputes_active", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func disputeSanction(_ input: DisputeSanctionInput) async throws -> UUID {
        do {
            return try await client.rpc("dispute_sanction", params: input).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func disputeDetail(disputeId: UUID) async throws -> GroupDisputeDetail {
        let params = DisputeDetailParams(disputeId: disputeId)
        do {
            let rows: [GroupDisputeDetail] = try await client
                .rpc("dispute_detail", params: params)
                .execute()
                .value
            guard let row = rows.first else {
                throw RuulError.unexpected(message: "dispute_detail returned no rows")
            }
            return row
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func listDisputeEvents(disputeId: UUID, limit: Int) async throws -> [GroupDisputeEvent] {
        let params = ListDisputeEventsParams(disputeId: disputeId, limit: limit)
        do {
            return try await client
                .rpc("list_dispute_events", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func openDispute(_ input: OpenDisputeInput) async throws -> UUID {
        do {
            return try await client.rpc("open_dispute", params: input).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func appendDisputeEvent(_ input: AppendDisputeEventInput) async throws -> UUID {
        do {
            return try await client.rpc("append_dispute_event", params: input).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func recordDisputeResolution(_ input: RecordDisputeResolutionInput) async throws {
        do {
            _ = try await client.rpc("record_dispute_resolution", params: input).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func escalateDisputeToVote(_ input: EscalateDisputeToVoteInput) async throws -> UUID {
        do {
            return try await client.rpc("escalate_dispute_to_vote", params: input).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Notifications + Privacy (B7)

    public func myNotificationPreferences(groupId: UUID) async throws -> [NotificationPreferenceRow] {
        let params = MyNotificationPreferencesParams(groupId: groupId)
        do {
            return try await client
                .rpc("my_notification_preferences", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func setNotificationPreference(_ input: SetNotificationPreferenceInput) async throws {
        do {
            _ = try await client.rpc("set_notification_preference", params: input).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func registerMyNotificationToken(_ input: RegisterMyNotificationTokenInput) async throws -> UUID {
        do {
            return try await client
                .rpc("register_my_notification_token", params: input)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func groupVisibility(groupId: UUID) async throws -> String {
        let params = GroupVisibilityParams(groupId: groupId)
        do {
            return try await client.rpc("group_visibility", params: params).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func setGroupVisibility(_ input: SetGroupVisibilityInput) async throws -> String {
        do {
            return try await client.rpc("set_group_visibility", params: input).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Dissolution (Primitiva 25, B8)

    public func groupDissolutionActive(groupId: UUID) async throws -> GroupDissolution? {
        let params = GroupDissolutionActiveParams(groupId: groupId)
        do {
            // Backend returns `{}` jsonb when no active dissolution.
            // Decode tolerantly into the wire shape and convert.
            let dto: GroupDissolutionWireDTO = try await client
                .rpc("group_dissolution_active", params: params)
                .execute()
                .value
            return dto.toDomain()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func proposeDissolution(_ input: ProposeDissolutionInput) async throws -> UUID {
        do {
            return try await client.rpc("propose_dissolution", params: input).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func finalizeDissolution(_ input: FinalizeDissolutionInput) async throws {
        do {
            _ = try await client.rpc("finalize_dissolution", params: input).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Roles + Permissions (Primitiva 17, B3)

    public func listGroupRoles(groupId: UUID) async throws -> [GroupRole] {
        let params = ListGroupRolesParams(groupId: groupId)
        do {
            return try await client.rpc("list_group_roles", params: params).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func listPermissionsCatalog() async throws -> [PermissionCatalogEntry] {
        do {
            return try await client.rpc("list_permissions_catalog").execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func createCustomRole(_ input: CreateCustomRoleInput) async throws -> UUID {
        do {
            return try await client.rpc("create_custom_role", params: input).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func updateRolePermissions(_ input: UpdateRolePermissionsInput) async throws {
        do {
            _ = try await client.rpc("update_role_permissions", params: input).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func assignRoleToMember(_ input: AssignRoleToMemberInput) async throws {
        do {
            _ = try await client.rpc("assign_role_to_member", params: input).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func revokeRoleFromMember(_ input: RevokeRoleFromMemberInput) async throws {
        do {
            _ = try await client.rpc("revoke_role_from_member", params: input).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Boundary policy (Primitiva 2, B2)

    public func groupBoundaryPolicy(groupId: UUID) async throws -> GroupBoundaryPolicy {
        let params = GroupBoundaryPolicyParams(groupId: groupId)
        do {
            return try await client
                .rpc("group_boundary_policy", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func setGroupBoundaryPolicy(_ input: SetGroupBoundaryPolicyInput) async throws -> GroupBoundaryPolicy {
        do {
            return try await client
                .rpc("set_group_boundary_policy", params: input)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Rituals (Primitiva 21, B6)

    public func listGroupResourceSeries(
        groupId: UUID,
        ritualsOnly: Bool,
        includePast: Bool
    ) async throws -> [GroupResourceSeries] {
        let params = ListGroupResourceSeriesParams(
            groupId: groupId,
            ritualsOnly: ritualsOnly,
            includePast: includePast
        )
        do {
            return try await client
                .rpc("list_group_resource_series", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func createResourceSeries(_ input: CreateResourceSeriesInput) async throws -> UUID {
        do {
            return try await client.rpc("create_resource_series", params: input).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func updateResourceSeries(_ input: UpdateResourceSeriesInput) async throws {
        do {
            _ = try await client.rpc("update_resource_series", params: input).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Sanctions (Primitiva 11)

    public func groupSanctionsActive(groupId: UUID, limit: Int) async throws -> [GroupSanction] {
        let params = GroupSanctionsActiveParams(groupId: groupId, limit: limit)
        do {
            return try await client
                .rpc("group_sanctions_active", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func issueSanction(_ input: IssueSanctionInput) async throws -> UUID {
        do {
            return try await client.rpc("issue_sanction", params: input).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Reputation (Primitiva 12)

    public func memberReputationEvents(groupId: UUID,
                                       subjectMembershipId: UUID,
                                       limit: Int) async throws -> [GroupReputationEvent] {
        let params = MemberReputationEventsParams(
            groupId: groupId,
            subjectMembershipId: subjectMembershipId,
            limit: limit
        )
        do {
            return try await client
                .rpc("member_reputation_events", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Decisions / Voting (Primitiva 16, C1)

    public func listDecisionsActive(groupId: UUID) async throws -> [GroupDecisionSummary] {
        let params = ListDecisionsActiveParams(groupId: groupId)
        do {
            return try await client
                .rpc("list_decisions_active", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func listDecisionsHistory(groupId: UUID, limit: Int) async throws -> [GroupDecisionSummary] {
        let params = ListDecisionsHistoryParams(groupId: groupId, limit: limit)
        do {
            return try await client
                .rpc("list_decisions_history", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func decisionDetail(decisionId: UUID) async throws -> GroupDecisionDetail {
        let params = DecisionDetailParams(decisionId: decisionId)
        do {
            return try await client
                .rpc("decision_detail", params: params)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func startVote(_ input: StartVoteParams) async throws -> UUID {
        do {
            return try await client.rpc("start_vote", params: input).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func castVote(_ input: CastVoteParams) async throws -> UUID {
        do {
            return try await client.rpc("cast_vote", params: input).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func castRankedVote(_ input: CastRankedVoteParams) async throws -> UUID {
        do {
            return try await client.rpc("cast_ranked_vote", params: input).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func finalizeVote(decisionId: UUID) async throws -> String {
        let params = FinalizeVoteParams(decisionId: decisionId)
        do {
            return try await client.rpc("finalize_vote", params: params).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func cancelVote(_ input: CancelVoteParams) async throws {
        do {
            _ = try await client.rpc("cancel_vote", params: input).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Profile

    public func myProfile() async throws -> Profile {
        do {
            return try await client
                .rpc("my_profile")
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func updateMyProfile(_ input: UpdateMyProfileInput) async throws -> Profile {
        do {
            return try await client
                .rpc("update_my_profile", params: input)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Helpers

    private func callVoid(_ name: String, params: any Encodable & Sendable) async throws {
        do {
            _ = try await client.rpc(name, params: params).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    private func callReturningUUID(_ name: String, params: any Encodable & Sendable) async throws -> UUID {
        do {
            return try await client.rpc(name, params: params).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    private func callReturningArray<Row: Decodable>(_ name: String, params: any Encodable & Sendable) async throws -> [Row] {
        do {
            return try await client.rpc(name, params: params).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }
}
