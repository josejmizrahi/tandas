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
