import Foundation
@testable import RuulCore

/// Actor-isolated mock of `RuulRPCClient` for unit tests. Records every
/// call in `recorded` and returns the configured stub per method. Stubs
/// default to a benign `.success(...)` so tests only set what they care
/// about. Use `setXStub(.failure(.backend(.amountMustBePositive)))` to
/// drive error-mapping coverage from the repository/store side.
final actor MockRuulRPCClient: RuulRPCClient {
    // MARK: - Recorded calls

    enum RecordedCall: Sendable, Equatable {
        case createGroup(name: String, slug: String?, category: String?, purposeDeclared: String?)
        case inviteMember(groupId: UUID, email: String?, phone: String?, membershipType: String, message: String?)
        case acceptInvite(code: String)
        case leaveGroup(groupId: UUID, reason: String?)
        case recordExpense(draft: ExpenseDraft, clientId: String?)
        case recordSettlement(draft: SettlementDraft, clientId: String?)
        case listMyGroups
        case groupSummary(groupId: UUID)
        case memberBalance(groupId: UUID, membershipId: UUID)
        case memberObligationSummary(groupId: UUID, membershipId: UUID)
        case listMemberPermissions(groupId: UUID, userId: UUID?)
        case groupMembers(groupId: UUID)
        case groupMembershipBoundary(groupId: UUID)
        case groupPurposesActive(groupId: UUID)
        case setGroupPurpose(input: SetGroupPurposeInput)
        case groupRulesActive(groupId: UUID)
        case createTextRule(input: CreateTextRuleInput)
        case archiveRule(input: ArchiveRuleInput)
        case groupResourcesActive(groupId: UUID)
        case createGroupResource(input: CreateGroupResourceInput)
        case archiveGroupResource(input: ArchiveGroupResourceInput)
        case groupFoundationStatus(groupId: UUID)
        case groupDecisionRules(groupId: UUID)
        case setDecisionRules(input: SetDecisionRulesInput)
        case memberReputationEvents(groupId: UUID, subjectMembershipId: UUID, limit: Int)
        case myProfile
        case updateMyProfile(input: UpdateMyProfileInput)
    }

    private(set) var recorded: [RecordedCall] = []

    // MARK: - Stubs

    private var createGroupStub: Result<UUID, RuulError> = .success(UUID())
    private var inviteMemberStub: Result<UUID, RuulError> = .success(UUID())
    private var acceptInviteStub: Result<AcceptInviteResult, RuulError> = .success(
        AcceptInviteResult(groupId: UUID(), membershipId: UUID())
    )
    private var leaveGroupStub: Result<Void, RuulError> = .success(())
    private var recordExpenseStub: Result<UUID, RuulError> = .success(UUID())
    private var recordSettlementStub: Result<SettlementResult, RuulError> = .success(
        SettlementResult(settlementId: UUID(), transactionId: UUID())
    )
    private var listMyGroupsStub: Result<[GroupListItem], RuulError> = .success([])
    private var groupSummaryStub: Result<CanonicalGroupSummary, RuulError> = .success(
        CanonicalGroupSummary(groupId: UUID(), memberCount: 0, openDecisions: 0, openDisputes: 0, openObligations: 0, recentEvents: [])
    )
    private var memberBalanceStub: Result<Decimal, RuulError> = .success(0)
    private var memberObligationSummaryStub: Result<[ObligationSummary], RuulError> = .success([])
    private var listMemberPermissionsStub: Result<[String], RuulError> = .success([])
    private var groupMembersStub: Result<[MemberListItem], RuulError> = .success([])
    private var groupMembershipBoundaryStub: Result<[MembershipBoundaryItem], RuulError> = .success([])
    private var groupPurposesActiveStub: Result<[GroupPurpose], RuulError> = .success([])
    private var setGroupPurposeStub: Result<GroupPurpose, RuulError> = .success(
        GroupPurpose(id: UUID(), groupId: UUID(), kind: .declared, body: "")
    )
    private var groupRulesActiveStub: Result<[GroupRule], RuulError> = .success([])
    private var createTextRuleStub: Result<CreateTextRuleResult, RuulError> = .success(
        CreateTextRuleResult(ruleId: UUID(), versionId: UUID())
    )
    private var archiveRuleStub: Result<Void, RuulError> = .success(())
    private var groupResourcesActiveStub: Result<[GroupResource], RuulError> = .success([])
    private var createGroupResourceStub: Result<GroupResource, RuulError> = .success(
        GroupResource(id: UUID(), groupId: UUID(), resourceType: .other, name: "")
    )
    private var archiveGroupResourceStub: Result<Void, RuulError> = .success(())
    private var groupFoundationStatusStub: Result<GroupFoundationStatus, RuulError> = .success(
        GroupFoundationStatus(
            groupId: UUID(),
            members: GroupFoundationPrimitive(status: .incomplete),
            boundary: GroupFoundationPrimitive(status: .incomplete),
            purpose: GroupFoundationPrimitive(status: .incomplete),
            rules: GroupFoundationPrimitive(status: .incomplete),
            resources: GroupFoundationPrimitive(status: .incomplete),
            overallStatus: .notReady
        )
    )
    private var groupDecisionRulesStub: Result<GroupDecisionRules, RuulError> = .success(
        GroupDecisionRules(groupId: UUID(), defaultStyle: .majority, isDefault: true)
    )
    private var setDecisionRulesStub: Result<GroupDecisionRules, RuulError> = .success(
        GroupDecisionRules(groupId: UUID(), defaultStyle: .majority, isDefault: false)
    )
    private var memberReputationEventsStub: Result<[GroupReputationEvent], RuulError> = .success([])
    private var myProfileStub: Result<Profile, RuulError> = .success(Profile(id: UUID()))
    private var updateMyProfileStub: Result<Profile, RuulError> = .success(Profile(id: UUID()))

    init() {}

    // MARK: - Stub setters

    func setCreateGroupStub(_ stub: Result<UUID, RuulError>) { createGroupStub = stub }
    func setInviteMemberStub(_ stub: Result<UUID, RuulError>) { inviteMemberStub = stub }
    func setAcceptInviteStub(_ stub: Result<AcceptInviteResult, RuulError>) { acceptInviteStub = stub }
    func setLeaveGroupStub(_ stub: Result<Void, RuulError>) { leaveGroupStub = stub }
    func setRecordExpenseStub(_ stub: Result<UUID, RuulError>) { recordExpenseStub = stub }
    func setRecordSettlementStub(_ stub: Result<SettlementResult, RuulError>) { recordSettlementStub = stub }
    func setListMyGroupsStub(_ stub: Result<[GroupListItem], RuulError>) { listMyGroupsStub = stub }
    func setGroupSummaryStub(_ stub: Result<CanonicalGroupSummary, RuulError>) { groupSummaryStub = stub }
    func setMemberBalanceStub(_ stub: Result<Decimal, RuulError>) { memberBalanceStub = stub }
    func setMemberObligationSummaryStub(_ stub: Result<[ObligationSummary], RuulError>) { memberObligationSummaryStub = stub }
    func setListMemberPermissionsStub(_ stub: Result<[String], RuulError>) { listMemberPermissionsStub = stub }
    func setGroupMembersStub(_ stub: Result<[MemberListItem], RuulError>) { groupMembersStub = stub }
    func setGroupMembershipBoundaryStub(_ stub: Result<[MembershipBoundaryItem], RuulError>) { groupMembershipBoundaryStub = stub }
    func setGroupPurposesActiveStub(_ stub: Result<[GroupPurpose], RuulError>) { groupPurposesActiveStub = stub }
    func setSetGroupPurposeStub(_ stub: Result<GroupPurpose, RuulError>) { setGroupPurposeStub = stub }
    func setGroupRulesActiveStub(_ stub: Result<[GroupRule], RuulError>) { groupRulesActiveStub = stub }
    func setCreateTextRuleStub(_ stub: Result<CreateTextRuleResult, RuulError>) { createTextRuleStub = stub }
    func setArchiveRuleStub(_ stub: Result<Void, RuulError>) { archiveRuleStub = stub }
    func setGroupResourcesActiveStub(_ stub: Result<[GroupResource], RuulError>) { groupResourcesActiveStub = stub }
    func setCreateGroupResourceStub(_ stub: Result<GroupResource, RuulError>) { createGroupResourceStub = stub }
    func setArchiveGroupResourceStub(_ stub: Result<Void, RuulError>) { archiveGroupResourceStub = stub }
    func setGroupFoundationStatusStub(_ stub: Result<GroupFoundationStatus, RuulError>) { groupFoundationStatusStub = stub }
    func setGroupDecisionRulesStub(_ stub: Result<GroupDecisionRules, RuulError>) { groupDecisionRulesStub = stub }
    func setSetDecisionRulesStub(_ stub: Result<GroupDecisionRules, RuulError>) { setDecisionRulesStub = stub }
    func setMemberReputationEventsStub(_ stub: Result<[GroupReputationEvent], RuulError>) { memberReputationEventsStub = stub }
    func setMyProfileStub(_ stub: Result<Profile, RuulError>) { myProfileStub = stub }
    func setUpdateMyProfileStub(_ stub: Result<Profile, RuulError>) { updateMyProfileStub = stub }

    // MARK: - RuulRPCClient

    func createGroup(name: String, slug: String?, category: String?, purposeDeclared: String?) async throws -> UUID {
        recorded.append(.createGroup(name: name, slug: slug, category: category, purposeDeclared: purposeDeclared))
        return try createGroupStub.get()
    }

    func inviteMember(groupId: UUID, email: String?, phone: String?, membershipType: String, message: String?) async throws -> UUID {
        recorded.append(.inviteMember(groupId: groupId, email: email, phone: phone, membershipType: membershipType, message: message))
        return try inviteMemberStub.get()
    }

    func acceptInvite(code: String) async throws -> AcceptInviteResult {
        recorded.append(.acceptInvite(code: code))
        return try acceptInviteStub.get()
    }

    func leaveGroup(groupId: UUID, reason: String?) async throws {
        recorded.append(.leaveGroup(groupId: groupId, reason: reason))
        try leaveGroupStub.get()
    }

    func recordExpense(_ draft: ExpenseDraft, clientId: String?) async throws -> UUID {
        recorded.append(.recordExpense(draft: draft, clientId: clientId))
        return try recordExpenseStub.get()
    }

    func recordSettlement(_ draft: SettlementDraft, clientId: String?) async throws -> SettlementResult {
        recorded.append(.recordSettlement(draft: draft, clientId: clientId))
        return try recordSettlementStub.get()
    }

    func listMyGroups() async throws -> [GroupListItem] {
        recorded.append(.listMyGroups)
        return try listMyGroupsStub.get()
    }

    func groupSummary(groupId: UUID) async throws -> CanonicalGroupSummary {
        recorded.append(.groupSummary(groupId: groupId))
        return try groupSummaryStub.get()
    }

    func memberBalance(groupId: UUID, membershipId: UUID) async throws -> Decimal {
        recorded.append(.memberBalance(groupId: groupId, membershipId: membershipId))
        return try memberBalanceStub.get()
    }

    func memberObligationSummary(groupId: UUID, membershipId: UUID) async throws -> [ObligationSummary] {
        recorded.append(.memberObligationSummary(groupId: groupId, membershipId: membershipId))
        return try memberObligationSummaryStub.get()
    }

    func listMemberPermissions(groupId: UUID, userId: UUID?) async throws -> [String] {
        recorded.append(.listMemberPermissions(groupId: groupId, userId: userId))
        return try listMemberPermissionsStub.get()
    }

    func groupMembers(groupId: UUID) async throws -> [MemberListItem] {
        recorded.append(.groupMembers(groupId: groupId))
        return try groupMembersStub.get()
    }

    func groupMembershipBoundary(groupId: UUID) async throws -> [MembershipBoundaryItem] {
        recorded.append(.groupMembershipBoundary(groupId: groupId))
        return try groupMembershipBoundaryStub.get()
    }

    func groupPurposesActive(groupId: UUID) async throws -> [GroupPurpose] {
        recorded.append(.groupPurposesActive(groupId: groupId))
        return try groupPurposesActiveStub.get()
    }

    func setGroupPurpose(_ input: SetGroupPurposeInput) async throws -> GroupPurpose {
        recorded.append(.setGroupPurpose(input: input))
        return try setGroupPurposeStub.get()
    }

    func groupRulesActive(groupId: UUID) async throws -> [GroupRule] {
        recorded.append(.groupRulesActive(groupId: groupId))
        return try groupRulesActiveStub.get()
    }

    func createTextRule(_ input: CreateTextRuleInput) async throws -> CreateTextRuleResult {
        recorded.append(.createTextRule(input: input))
        return try createTextRuleStub.get()
    }

    func archiveRule(_ input: ArchiveRuleInput) async throws {
        recorded.append(.archiveRule(input: input))
        try archiveRuleStub.get()
    }

    func groupResourcesActive(groupId: UUID) async throws -> [GroupResource] {
        recorded.append(.groupResourcesActive(groupId: groupId))
        return try groupResourcesActiveStub.get()
    }

    func createGroupResource(_ input: CreateGroupResourceInput) async throws -> GroupResource {
        recorded.append(.createGroupResource(input: input))
        return try createGroupResourceStub.get()
    }

    func archiveGroupResource(_ input: ArchiveGroupResourceInput) async throws {
        recorded.append(.archiveGroupResource(input: input))
        try archiveGroupResourceStub.get()
    }

    func groupFoundationStatus(groupId: UUID) async throws -> GroupFoundationStatus {
        recorded.append(.groupFoundationStatus(groupId: groupId))
        return try groupFoundationStatusStub.get()
    }

    func groupDecisionRules(groupId: UUID) async throws -> GroupDecisionRules {
        recorded.append(.groupDecisionRules(groupId: groupId))
        return try groupDecisionRulesStub.get()
    }

    func setDecisionRules(_ input: SetDecisionRulesInput) async throws -> GroupDecisionRules {
        recorded.append(.setDecisionRules(input: input))
        return try setDecisionRulesStub.get()
    }

    func memberReputationEvents(groupId: UUID,
                                subjectMembershipId: UUID,
                                limit: Int) async throws -> [GroupReputationEvent] {
        recorded.append(.memberReputationEvents(groupId: groupId, subjectMembershipId: subjectMembershipId, limit: limit))
        return try memberReputationEventsStub.get()
    }

    func myProfile() async throws -> Profile {
        recorded.append(.myProfile)
        return try myProfileStub.get()
    }

    func updateMyProfile(_ input: UpdateMyProfileInput) async throws -> Profile {
        recorded.append(.updateMyProfile(input: input))
        return try updateMyProfileStub.get()
    }
}
