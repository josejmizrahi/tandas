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
        case listRuleShapes
        case validateRuleShape(input: ValidateRuleShapeInput)
        case createEngineRule(input: CreateEngineRuleInput)
        case groupRulesEngine(groupId: UUID)
        case groupRuleEvaluations(groupId: UUID, limit: Int, before: Date?)
        case groupRuleEvaluationSummary(groupId: UUID, windowHours: Int)
        case systemEventEngineProvenance(eventUuid: UUID)
        case groupSanctionPaymentStatus(sanctionId: UUID)
        case proposeSanctionPaymentPlan(input: ProposeSanctionPaymentPlanParams)
        case cancelSanctionPaymentPlan(input: CancelSanctionPaymentPlanParams)
        case groupSanctionPaymentPlanActive(sanctionId: UUID)
        case groupResourcesActive(groupId: UUID)
        case createGroupResource(input: CreateGroupResourceInput)
        case archiveGroupResource(input: ArchiveGroupResourceInput)
        case setResourceOwnership(input: SetResourceOwnershipParams)
        case setMembershipState(input: SetMembershipStateParams)
        case groupFoundationStatus(groupId: UUID)
        case groupDecisionRules(groupId: UUID)
        case setDecisionRules(input: SetDecisionRulesInput)
        case memberReputationEvents(groupId: UUID, subjectMembershipId: UUID, limit: Int)
        case groupSanctionsActive(groupId: UUID, limit: Int)
        case issueSanction(input: IssueSanctionInput)
        case groupDisputesActive(groupId: UUID, limit: Int)
        case disputeSanction(input: DisputeSanctionInput)
        case groupEventsRecent(groupId: UUID, limit: Int, before: Date?)
        case groupMoneyMovements(groupId: UUID, limit: Int, filter: [String]?, beforeSeq: Int64?)
        case groupCulturalNormsActive(groupId: UUID)
        case proposeCulturalNorm(input: ProposeCulturalNormParams)
        case endorseCulturalNorm(normId: UUID)
        case retireCulturalNorm(input: RetireCulturalNormParams)
        case promoteNormToRule(input: PromoteNormToRuleInput)
        case groupMandatesActive(groupId: UUID)
        case grantMandate(input: GrantMandateParams)
        case revokeMandate(input: RevokeMandateParams)
        case groupContributionsActive(groupId: UUID, membershipId: UUID?, resourceId: UUID?)
        case logContribution(input: LogContributionParams)
        case verifyContribution(input: VerifyContributionParams)
        case groupReputationEvents(groupId: UUID, limit: Int)
        case recordReputationEvent(input: RecordReputationEventParams)
        case myProfile
        case updateMyProfile(input: UpdateMyProfileInput)
        case listDecisionsActive(groupId: UUID)
        case listDecisionsHistory(groupId: UUID, limit: Int)
        case decisionDetail(decisionId: UUID)
        case startVote(input: StartVoteParams)
        case castVote(input: CastVoteParams)
        case castRankedVote(input: CastRankedVoteParams)
        case finalizeVote(decisionId: UUID)
        case cancelVote(input: CancelVoteParams)
        case disputeDetail(disputeId: UUID)
        case listDisputeEvents(disputeId: UUID, limit: Int)
        case openDispute(input: OpenDisputeInput)
        case appendDisputeEvent(input: AppendDisputeEventInput)
        case recordDisputeResolution(input: RecordDisputeResolutionInput)
        case escalateDisputeToVote(input: EscalateDisputeToVoteInput)
        case listGroupResourceSeries(groupId: UUID, ritualsOnly: Bool, includePast: Bool)
        case createResourceSeries(input: CreateResourceSeriesInput)
        case updateResourceSeries(input: UpdateResourceSeriesInput)
        case groupBoundaryPolicy(groupId: UUID)
        case setGroupBoundaryPolicy(input: SetGroupBoundaryPolicyInput)
        case listGroupRoles(groupId: UUID)
        case listPermissionsCatalog
        case createCustomRole(input: CreateCustomRoleInput)
        case updateRolePermissions(input: UpdateRolePermissionsInput)
        case assignRoleToMember(input: AssignRoleToMemberInput)
        case revokeRoleFromMember(input: RevokeRoleFromMemberInput)
        case groupDissolutionActive(groupId: UUID)
        case proposeDissolution(input: ProposeDissolutionInput)
        case finalizeDissolution(input: FinalizeDissolutionInput)
        case myNotificationPreferences(groupId: UUID)
        case setNotificationPreference(input: SetNotificationPreferenceInput)
        case registerMyNotificationToken(input: RegisterMyNotificationTokenInput)
        case groupVisibility(groupId: UUID)
        case setGroupVisibility(input: SetGroupVisibilityInput)
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
    private var listRuleShapesStub: Result<[RuleShape], RuulError> = .success([])
    private var validateRuleShapeStub: Result<RuleShapeValidationResult, RuulError> = .success(
        RuleShapeValidationResult(valid: true, errors: [], shapeKey: nil, triggerEventType: nil)
    )
    private var createEngineRuleStub: Result<CreateEngineRuleResult, RuulError> = .success(
        CreateEngineRuleResult(ruleId: UUID(), versionId: UUID())
    )
    private var groupRulesEngineStub: Result<[EngineRule], RuulError> = .success([])
    private var groupRuleEvaluationsStub: Result<[GroupRuleEvaluation], RuulError> = .success([])
    private var groupRuleEvaluationSummaryStub: Result<GroupRuleEvaluationSummary, RuulError> = .success(
        GroupRuleEvaluationSummary(evaluationsCount: 0)
    )
    private var systemEventEngineProvenanceStub: Result<SystemEventProvenance, RuulError> = .success(
        SystemEventProvenance(found: false, reason: "no_engine_origin")
    )
    private var groupSanctionPaymentStatusStub: Result<SanctionPaymentStatus, RuulError> = .success(
        SanctionPaymentStatus(
            sanctionId: UUID(),
            amountOriginal: 0,
            amountOutstanding: 0,
            amountPaid: 0,
            obligationStatus: "no_obligation",
            sanctionStatus: "active"
        )
    )
    private var proposeSanctionPaymentPlanStub: Result<UUID, RuulError> = .success(UUID())
    private var cancelSanctionPaymentPlanStub: Result<Void, RuulError> = .success(())
    private var groupSanctionPaymentPlanActiveStub: Result<SanctionPaymentPlan, RuulError> = .success(
        SanctionPaymentPlan(active: false)
    )
    private var groupResourcesActiveStub: Result<[GroupResource], RuulError> = .success([])
    private var createGroupResourceStub: Result<GroupResource, RuulError> = .success(
        GroupResource(id: UUID(), groupId: UUID(), resourceType: .other, name: "")
    )
    private var archiveGroupResourceStub: Result<Void, RuulError> = .success(())
    private var setResourceOwnershipStub: Result<Void, RuulError> = .success(())
    private var setMembershipStateStub: Result<Void, RuulError> = .success(())
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
    private var groupSanctionsActiveStub: Result<[GroupSanction], RuulError> = .success([])
    private var issueSanctionStub: Result<UUID, RuulError> = .success(UUID())
    private var groupDisputesActiveStub: Result<[GroupDispute], RuulError> = .success([])
    private var disputeSanctionStub: Result<UUID, RuulError> = .success(UUID())
    private var groupEventsRecentStub: Result<[GroupEvent], RuulError> = .success([])
    private var groupMoneyMovementsStub: Result<[MoneyMovement], RuulError> = .success([])
    private var groupCulturalNormsActiveStub: Result<[GroupCulturalNorm], RuulError> = .success([])
    private var proposeCulturalNormStub: Result<UUID, RuulError> = .success(UUID())
    private var endorseCulturalNormStub: Result<Int, RuulError> = .success(1)
    private var retireCulturalNormStub: Result<Void, RuulError> = .success(())
    private var promoteNormToRuleStub: Result<PromoteNormToRuleResult, RuulError> = .success(
        PromoteNormToRuleResult(ruleId: UUID(), versionId: UUID(), normId: UUID())
    )
    private var groupMandatesActiveStub: Result<[GroupMandate], RuulError> = .success([])
    private var grantMandateStub: Result<UUID, RuulError> = .success(UUID())
    private var revokeMandateStub: Result<Void, RuulError> = .success(())
    private var groupContributionsActiveStub: Result<[GroupContribution], RuulError> = .success([])
    private var logContributionStub: Result<UUID, RuulError> = .success(UUID())
    private var verifyContributionStub: Result<Void, RuulError> = .success(())
    private var groupReputationEventsStub: Result<[GroupReputationEvent], RuulError> = .success([])
    private var recordReputationEventStub: Result<GroupReputationEvent, RuulError> = .success(
        GroupReputationEvent(id: UUID(), groupId: UUID(), subjectMembershipId: UUID(), kind: .other)
    )
    private var myProfileStub: Result<Profile, RuulError> = .success(Profile(id: UUID()))
    private var updateMyProfileStub: Result<Profile, RuulError> = .success(Profile(id: UUID()))
    private var listDecisionsActiveStub: Result<[GroupDecisionSummary], RuulError> = .success([])
    private var listDecisionsHistoryStub: Result<[GroupDecisionSummary], RuulError> = .success([])
    private var decisionDetailStub: Result<GroupDecisionDetail, RuulError> = .success(
        GroupDecisionDetail(id: UUID(), groupId: UUID(), title: "")
    )
    private var startVoteStub: Result<UUID, RuulError> = .success(UUID())
    private var castVoteStub: Result<UUID, RuulError> = .success(UUID())
    private var castRankedVoteStub: Result<UUID, RuulError> = .success(UUID())
    private var finalizeVoteStub: Result<String, RuulError> = .success("passed")
    private var cancelVoteStub: Result<Void, RuulError> = .success(())
    private var disputeDetailStub: Result<GroupDisputeDetail, RuulError> = .success(
        GroupDisputeDetail(id: UUID(), groupId: UUID(), title: "")
    )
    private var listDisputeEventsStub: Result<[GroupDisputeEvent], RuulError> = .success([])
    private var openDisputeStub: Result<UUID, RuulError> = .success(UUID())
    private var appendDisputeEventStub: Result<UUID, RuulError> = .success(UUID())
    private var recordDisputeResolutionStub: Result<Void, RuulError> = .success(())
    private var escalateDisputeToVoteStub: Result<UUID, RuulError> = .success(UUID())
    private var listGroupResourceSeriesStub: Result<[GroupResourceSeries], RuulError> = .success([])
    private var createResourceSeriesStub: Result<UUID, RuulError> = .success(UUID())
    private var updateResourceSeriesStub: Result<Void, RuulError> = .success(())
    private var groupBoundaryPolicyStub: Result<GroupBoundaryPolicy, RuulError> = .success(
        GroupBoundaryPolicy(groupId: UUID())
    )
    private var setGroupBoundaryPolicyStub: Result<GroupBoundaryPolicy, RuulError> = .success(
        GroupBoundaryPolicy(groupId: UUID(), isDefault: false)
    )
    private var listGroupRolesStub: Result<[GroupRole], RuulError> = .success([])
    private var listPermissionsCatalogStub: Result<[PermissionCatalogEntry], RuulError> = .success([])
    private var createCustomRoleStub: Result<UUID, RuulError> = .success(UUID())
    private var updateRolePermissionsStub: Result<Void, RuulError> = .success(())
    private var assignRoleToMemberStub: Result<Void, RuulError> = .success(())
    private var revokeRoleFromMemberStub: Result<Void, RuulError> = .success(())
    private var groupDissolutionActiveStub: Result<GroupDissolution?, RuulError> = .success(nil)
    private var proposeDissolutionStub: Result<UUID, RuulError> = .success(UUID())
    private var finalizeDissolutionStub: Result<Void, RuulError> = .success(())
    private var myNotificationPreferencesStub: Result<[NotificationPreferenceRow], RuulError> = .success([])
    private var setNotificationPreferenceStub: Result<Void, RuulError> = .success(())
    private var registerMyNotificationTokenStub: Result<UUID, RuulError> = .success(UUID())
    private var groupVisibilityStub: Result<String, RuulError> = .success("private")
    private var setGroupVisibilityStub: Result<String, RuulError> = .success("private")

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
    func setListRuleShapesStub(_ stub: Result<[RuleShape], RuulError>) { listRuleShapesStub = stub }
    func setValidateRuleShapeStub(_ stub: Result<RuleShapeValidationResult, RuulError>) { validateRuleShapeStub = stub }
    func setCreateEngineRuleStub(_ stub: Result<CreateEngineRuleResult, RuulError>) { createEngineRuleStub = stub }
    func setGroupRulesEngineStub(_ stub: Result<[EngineRule], RuulError>) { groupRulesEngineStub = stub }
    func setGroupRuleEvaluationsStub(_ stub: Result<[GroupRuleEvaluation], RuulError>) { groupRuleEvaluationsStub = stub }
    func setGroupRuleEvaluationSummaryStub(_ stub: Result<GroupRuleEvaluationSummary, RuulError>) { groupRuleEvaluationSummaryStub = stub }
    func setSystemEventEngineProvenanceStub(_ stub: Result<SystemEventProvenance, RuulError>) { systemEventEngineProvenanceStub = stub }
    func setGroupSanctionPaymentStatusStub(_ stub: Result<SanctionPaymentStatus, RuulError>) { groupSanctionPaymentStatusStub = stub }
    func setProposeSanctionPaymentPlanStub(_ stub: Result<UUID, RuulError>) { proposeSanctionPaymentPlanStub = stub }
    func setCancelSanctionPaymentPlanStub(_ stub: Result<Void, RuulError>) { cancelSanctionPaymentPlanStub = stub }
    func setGroupSanctionPaymentPlanActiveStub(_ stub: Result<SanctionPaymentPlan, RuulError>) { groupSanctionPaymentPlanActiveStub = stub }
    func setGroupResourcesActiveStub(_ stub: Result<[GroupResource], RuulError>) { groupResourcesActiveStub = stub }
    func setCreateGroupResourceStub(_ stub: Result<GroupResource, RuulError>) { createGroupResourceStub = stub }
    func setArchiveGroupResourceStub(_ stub: Result<Void, RuulError>) { archiveGroupResourceStub = stub }
    func setSetResourceOwnershipStub(_ stub: Result<Void, RuulError>) { setResourceOwnershipStub = stub }
    func setSetMembershipStateStub(_ stub: Result<Void, RuulError>) { setMembershipStateStub = stub }
    func setGroupFoundationStatusStub(_ stub: Result<GroupFoundationStatus, RuulError>) { groupFoundationStatusStub = stub }
    func setGroupDecisionRulesStub(_ stub: Result<GroupDecisionRules, RuulError>) { groupDecisionRulesStub = stub }
    func setSetDecisionRulesStub(_ stub: Result<GroupDecisionRules, RuulError>) { setDecisionRulesStub = stub }
    func setMemberReputationEventsStub(_ stub: Result<[GroupReputationEvent], RuulError>) { memberReputationEventsStub = stub }
    func setGroupSanctionsActiveStub(_ stub: Result<[GroupSanction], RuulError>) { groupSanctionsActiveStub = stub }
    func setIssueSanctionStub(_ stub: Result<UUID, RuulError>) { issueSanctionStub = stub }
    func setGroupDisputesActiveStub(_ stub: Result<[GroupDispute], RuulError>) { groupDisputesActiveStub = stub }
    func setDisputeSanctionStub(_ stub: Result<UUID, RuulError>) { disputeSanctionStub = stub }
    func setGroupEventsRecentStub(_ stub: Result<[GroupEvent], RuulError>) { groupEventsRecentStub = stub }
    func setGroupMoneyMovementsStub(_ stub: Result<[MoneyMovement], RuulError>) { groupMoneyMovementsStub = stub }
    func setGroupCulturalNormsActiveStub(_ stub: Result<[GroupCulturalNorm], RuulError>) { groupCulturalNormsActiveStub = stub }
    func setProposeCulturalNormStub(_ stub: Result<UUID, RuulError>) { proposeCulturalNormStub = stub }
    func setEndorseCulturalNormStub(_ stub: Result<Int, RuulError>) { endorseCulturalNormStub = stub }
    func setRetireCulturalNormStub(_ stub: Result<Void, RuulError>) { retireCulturalNormStub = stub }
    func setPromoteNormToRuleStub(_ stub: Result<PromoteNormToRuleResult, RuulError>) { promoteNormToRuleStub = stub }
    func setGroupMandatesActiveStub(_ stub: Result<[GroupMandate], RuulError>) { groupMandatesActiveStub = stub }
    func setGrantMandateStub(_ stub: Result<UUID, RuulError>) { grantMandateStub = stub }
    func setRevokeMandateStub(_ stub: Result<Void, RuulError>) { revokeMandateStub = stub }
    func setGroupContributionsActiveStub(_ stub: Result<[GroupContribution], RuulError>) { groupContributionsActiveStub = stub }
    func setLogContributionStub(_ stub: Result<UUID, RuulError>) { logContributionStub = stub }
    func setVerifyContributionStub(_ stub: Result<Void, RuulError>) { verifyContributionStub = stub }
    func setGroupReputationEventsStub(_ stub: Result<[GroupReputationEvent], RuulError>) { groupReputationEventsStub = stub }
    func setRecordReputationEventStub(_ stub: Result<GroupReputationEvent, RuulError>) { recordReputationEventStub = stub }
    func setMyProfileStub(_ stub: Result<Profile, RuulError>) { myProfileStub = stub }
    func setUpdateMyProfileStub(_ stub: Result<Profile, RuulError>) { updateMyProfileStub = stub }
    func setListDecisionsActiveStub(_ stub: Result<[GroupDecisionSummary], RuulError>) { listDecisionsActiveStub = stub }
    func setListDecisionsHistoryStub(_ stub: Result<[GroupDecisionSummary], RuulError>) { listDecisionsHistoryStub = stub }
    func setDecisionDetailStub(_ stub: Result<GroupDecisionDetail, RuulError>) { decisionDetailStub = stub }
    func setStartVoteStub(_ stub: Result<UUID, RuulError>) { startVoteStub = stub }
    func setCastVoteStub(_ stub: Result<UUID, RuulError>) { castVoteStub = stub }
    func setCastRankedVoteStub(_ stub: Result<UUID, RuulError>) { castRankedVoteStub = stub }
    func setFinalizeVoteStub(_ stub: Result<String, RuulError>) { finalizeVoteStub = stub }
    func setCancelVoteStub(_ stub: Result<Void, RuulError>) { cancelVoteStub = stub }
    func setDisputeDetailStub(_ stub: Result<GroupDisputeDetail, RuulError>) { disputeDetailStub = stub }
    func setListDisputeEventsStub(_ stub: Result<[GroupDisputeEvent], RuulError>) { listDisputeEventsStub = stub }
    func setOpenDisputeStub(_ stub: Result<UUID, RuulError>) { openDisputeStub = stub }
    func setAppendDisputeEventStub(_ stub: Result<UUID, RuulError>) { appendDisputeEventStub = stub }
    func setRecordDisputeResolutionStub(_ stub: Result<Void, RuulError>) { recordDisputeResolutionStub = stub }
    func setEscalateDisputeToVoteStub(_ stub: Result<UUID, RuulError>) { escalateDisputeToVoteStub = stub }
    func setListGroupResourceSeriesStub(_ stub: Result<[GroupResourceSeries], RuulError>) { listGroupResourceSeriesStub = stub }
    func setCreateResourceSeriesStub(_ stub: Result<UUID, RuulError>) { createResourceSeriesStub = stub }
    func setUpdateResourceSeriesStub(_ stub: Result<Void, RuulError>) { updateResourceSeriesStub = stub }
    func setGroupBoundaryPolicyStub(_ stub: Result<GroupBoundaryPolicy, RuulError>) { groupBoundaryPolicyStub = stub }
    func setSetGroupBoundaryPolicyStub(_ stub: Result<GroupBoundaryPolicy, RuulError>) { setGroupBoundaryPolicyStub = stub }
    func setListGroupRolesStub(_ stub: Result<[GroupRole], RuulError>) { listGroupRolesStub = stub }
    func setListPermissionsCatalogStub(_ stub: Result<[PermissionCatalogEntry], RuulError>) { listPermissionsCatalogStub = stub }
    func setCreateCustomRoleStub(_ stub: Result<UUID, RuulError>) { createCustomRoleStub = stub }
    func setUpdateRolePermissionsStub(_ stub: Result<Void, RuulError>) { updateRolePermissionsStub = stub }
    func setAssignRoleToMemberStub(_ stub: Result<Void, RuulError>) { assignRoleToMemberStub = stub }
    func setRevokeRoleFromMemberStub(_ stub: Result<Void, RuulError>) { revokeRoleFromMemberStub = stub }
    func setGroupDissolutionActiveStub(_ stub: Result<GroupDissolution?, RuulError>) { groupDissolutionActiveStub = stub }
    func setProposeDissolutionStub(_ stub: Result<UUID, RuulError>) { proposeDissolutionStub = stub }
    func setFinalizeDissolutionStub(_ stub: Result<Void, RuulError>) { finalizeDissolutionStub = stub }
    func setMyNotificationPreferencesStub(_ stub: Result<[NotificationPreferenceRow], RuulError>) { myNotificationPreferencesStub = stub }
    func setSetNotificationPreferenceStub(_ stub: Result<Void, RuulError>) { setNotificationPreferenceStub = stub }
    func setRegisterMyNotificationTokenStub(_ stub: Result<UUID, RuulError>) { registerMyNotificationTokenStub = stub }
    func setGroupVisibilityStub(_ stub: Result<String, RuulError>) { groupVisibilityStub = stub }
    func setSetGroupVisibilityStub(_ stub: Result<String, RuulError>) { setGroupVisibilityStub = stub }

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

    func listRuleShapes() async throws -> [RuleShape] {
        recorded.append(.listRuleShapes)
        return try listRuleShapesStub.get()
    }

    func validateRuleShape(_ input: ValidateRuleShapeInput) async throws -> RuleShapeValidationResult {
        recorded.append(.validateRuleShape(input: input))
        return try validateRuleShapeStub.get()
    }

    func createEngineRule(_ input: CreateEngineRuleInput) async throws -> CreateEngineRuleResult {
        recorded.append(.createEngineRule(input: input))
        return try createEngineRuleStub.get()
    }

    func groupRulesEngine(groupId: UUID) async throws -> [EngineRule] {
        recorded.append(.groupRulesEngine(groupId: groupId))
        return try groupRulesEngineStub.get()
    }

    func groupRuleEvaluations(groupId: UUID, limit: Int, before: Date?) async throws -> [GroupRuleEvaluation] {
        recorded.append(.groupRuleEvaluations(groupId: groupId, limit: limit, before: before))
        return try groupRuleEvaluationsStub.get()
    }

    func groupRuleEvaluationSummary(groupId: UUID, windowHours: Int) async throws -> GroupRuleEvaluationSummary {
        recorded.append(.groupRuleEvaluationSummary(groupId: groupId, windowHours: windowHours))
        return try groupRuleEvaluationSummaryStub.get()
    }

    func systemEventEngineProvenance(eventUuid: UUID) async throws -> SystemEventProvenance {
        recorded.append(.systemEventEngineProvenance(eventUuid: eventUuid))
        return try systemEventEngineProvenanceStub.get()
    }

    func groupSanctionPaymentStatus(sanctionId: UUID) async throws -> SanctionPaymentStatus {
        recorded.append(.groupSanctionPaymentStatus(sanctionId: sanctionId))
        return try groupSanctionPaymentStatusStub.get()
    }

    func proposeSanctionPaymentPlan(_ input: ProposeSanctionPaymentPlanParams) async throws -> UUID {
        recorded.append(.proposeSanctionPaymentPlan(input: input))
        return try proposeSanctionPaymentPlanStub.get()
    }

    func cancelSanctionPaymentPlan(_ input: CancelSanctionPaymentPlanParams) async throws {
        recorded.append(.cancelSanctionPaymentPlan(input: input))
        try cancelSanctionPaymentPlanStub.get()
    }

    func groupSanctionPaymentPlanActive(sanctionId: UUID) async throws -> SanctionPaymentPlan {
        recorded.append(.groupSanctionPaymentPlanActive(sanctionId: sanctionId))
        return try groupSanctionPaymentPlanActiveStub.get()
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

    func setResourceOwnership(_ input: SetResourceOwnershipParams) async throws {
        recorded.append(.setResourceOwnership(input: input))
        try setResourceOwnershipStub.get()
    }

    func setMembershipState(_ input: SetMembershipStateParams) async throws {
        recorded.append(.setMembershipState(input: input))
        try setMembershipStateStub.get()
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

    func groupSanctionsActive(groupId: UUID, limit: Int) async throws -> [GroupSanction] {
        recorded.append(.groupSanctionsActive(groupId: groupId, limit: limit))
        return try groupSanctionsActiveStub.get()
    }

    func issueSanction(_ input: IssueSanctionInput) async throws -> UUID {
        recorded.append(.issueSanction(input: input))
        return try issueSanctionStub.get()
    }

    func groupDisputesActive(groupId: UUID, limit: Int) async throws -> [GroupDispute] {
        recorded.append(.groupDisputesActive(groupId: groupId, limit: limit))
        return try groupDisputesActiveStub.get()
    }

    func disputeSanction(_ input: DisputeSanctionInput) async throws -> UUID {
        recorded.append(.disputeSanction(input: input))
        return try disputeSanctionStub.get()
    }

    func groupEventsRecent(groupId: UUID, limit: Int, before: Date?) async throws -> [GroupEvent] {
        recorded.append(.groupEventsRecent(groupId: groupId, limit: limit, before: before))
        return try groupEventsRecentStub.get()
    }

    func groupMoneyMovements(
        groupId: UUID,
        limit: Int,
        filter: [String]?,
        beforeSeq: Int64?
    ) async throws -> [MoneyMovement] {
        recorded.append(.groupMoneyMovements(groupId: groupId, limit: limit, filter: filter, beforeSeq: beforeSeq))
        return try groupMoneyMovementsStub.get()
    }

    func groupCulturalNormsActive(groupId: UUID) async throws -> [GroupCulturalNorm] {
        recorded.append(.groupCulturalNormsActive(groupId: groupId))
        return try groupCulturalNormsActiveStub.get()
    }

    func proposeCulturalNorm(_ input: ProposeCulturalNormParams) async throws -> UUID {
        recorded.append(.proposeCulturalNorm(input: input))
        return try proposeCulturalNormStub.get()
    }

    func endorseCulturalNorm(normId: UUID) async throws -> Int {
        recorded.append(.endorseCulturalNorm(normId: normId))
        return try endorseCulturalNormStub.get()
    }

    func retireCulturalNorm(_ input: RetireCulturalNormParams) async throws {
        recorded.append(.retireCulturalNorm(input: input))
        try retireCulturalNormStub.get()
    }

    func promoteNormToRule(_ input: PromoteNormToRuleInput) async throws -> PromoteNormToRuleResult {
        recorded.append(.promoteNormToRule(input: input))
        return try promoteNormToRuleStub.get()
    }

    func groupMandatesActive(groupId: UUID) async throws -> [GroupMandate] {
        recorded.append(.groupMandatesActive(groupId: groupId))
        return try groupMandatesActiveStub.get()
    }

    func grantMandate(_ input: GrantMandateParams) async throws -> UUID {
        recorded.append(.grantMandate(input: input))
        return try grantMandateStub.get()
    }

    func revokeMandate(_ input: RevokeMandateParams) async throws {
        recorded.append(.revokeMandate(input: input))
        try revokeMandateStub.get()
    }

    func groupContributionsActive(
        groupId: UUID,
        membershipId: UUID?,
        resourceId: UUID?
    ) async throws -> [GroupContribution] {
        recorded.append(.groupContributionsActive(groupId: groupId, membershipId: membershipId, resourceId: resourceId))
        return try groupContributionsActiveStub.get()
    }

    func logContribution(_ input: LogContributionParams) async throws -> UUID {
        recorded.append(.logContribution(input: input))
        return try logContributionStub.get()
    }

    func verifyContribution(_ input: VerifyContributionParams) async throws {
        recorded.append(.verifyContribution(input: input))
        try verifyContributionStub.get()
    }

    func groupReputationEvents(groupId: UUID, limit: Int) async throws -> [GroupReputationEvent] {
        recorded.append(.groupReputationEvents(groupId: groupId, limit: limit))
        return try groupReputationEventsStub.get()
    }

    func recordReputationEvent(_ input: RecordReputationEventParams) async throws -> GroupReputationEvent {
        recorded.append(.recordReputationEvent(input: input))
        return try recordReputationEventStub.get()
    }

    func myProfile() async throws -> Profile {
        recorded.append(.myProfile)
        return try myProfileStub.get()
    }

    func updateMyProfile(_ input: UpdateMyProfileInput) async throws -> Profile {
        recorded.append(.updateMyProfile(input: input))
        return try updateMyProfileStub.get()
    }

    func listDecisionsActive(groupId: UUID) async throws -> [GroupDecisionSummary] {
        recorded.append(.listDecisionsActive(groupId: groupId))
        return try listDecisionsActiveStub.get()
    }

    func listDecisionsHistory(groupId: UUID, limit: Int) async throws -> [GroupDecisionSummary] {
        recorded.append(.listDecisionsHistory(groupId: groupId, limit: limit))
        return try listDecisionsHistoryStub.get()
    }

    func decisionDetail(decisionId: UUID) async throws -> GroupDecisionDetail {
        recorded.append(.decisionDetail(decisionId: decisionId))
        return try decisionDetailStub.get()
    }

    func startVote(_ input: StartVoteParams) async throws -> UUID {
        recorded.append(.startVote(input: input))
        return try startVoteStub.get()
    }

    func castVote(_ input: CastVoteParams) async throws -> UUID {
        recorded.append(.castVote(input: input))
        return try castVoteStub.get()
    }

    func castRankedVote(_ input: CastRankedVoteParams) async throws -> UUID {
        recorded.append(.castRankedVote(input: input))
        return try castRankedVoteStub.get()
    }

    func finalizeVote(decisionId: UUID) async throws -> String {
        recorded.append(.finalizeVote(decisionId: decisionId))
        return try finalizeVoteStub.get()
    }

    func cancelVote(_ input: CancelVoteParams) async throws {
        recorded.append(.cancelVote(input: input))
        try cancelVoteStub.get()
    }

    func disputeDetail(disputeId: UUID) async throws -> GroupDisputeDetail {
        recorded.append(.disputeDetail(disputeId: disputeId))
        return try disputeDetailStub.get()
    }

    func listDisputeEvents(disputeId: UUID, limit: Int) async throws -> [GroupDisputeEvent] {
        recorded.append(.listDisputeEvents(disputeId: disputeId, limit: limit))
        return try listDisputeEventsStub.get()
    }

    func openDispute(_ input: OpenDisputeInput) async throws -> UUID {
        recorded.append(.openDispute(input: input))
        return try openDisputeStub.get()
    }

    func appendDisputeEvent(_ input: AppendDisputeEventInput) async throws -> UUID {
        recorded.append(.appendDisputeEvent(input: input))
        return try appendDisputeEventStub.get()
    }

    func recordDisputeResolution(_ input: RecordDisputeResolutionInput) async throws {
        recorded.append(.recordDisputeResolution(input: input))
        try recordDisputeResolutionStub.get()
    }

    func escalateDisputeToVote(_ input: EscalateDisputeToVoteInput) async throws -> UUID {
        recorded.append(.escalateDisputeToVote(input: input))
        return try escalateDisputeToVoteStub.get()
    }

    func listGroupResourceSeries(groupId: UUID, ritualsOnly: Bool, includePast: Bool) async throws -> [GroupResourceSeries] {
        recorded.append(.listGroupResourceSeries(groupId: groupId, ritualsOnly: ritualsOnly, includePast: includePast))
        return try listGroupResourceSeriesStub.get()
    }

    func createResourceSeries(_ input: CreateResourceSeriesInput) async throws -> UUID {
        recorded.append(.createResourceSeries(input: input))
        return try createResourceSeriesStub.get()
    }

    func updateResourceSeries(_ input: UpdateResourceSeriesInput) async throws {
        recorded.append(.updateResourceSeries(input: input))
        try updateResourceSeriesStub.get()
    }

    func groupBoundaryPolicy(groupId: UUID) async throws -> GroupBoundaryPolicy {
        recorded.append(.groupBoundaryPolicy(groupId: groupId))
        return try groupBoundaryPolicyStub.get()
    }

    func setGroupBoundaryPolicy(_ input: SetGroupBoundaryPolicyInput) async throws -> GroupBoundaryPolicy {
        recorded.append(.setGroupBoundaryPolicy(input: input))
        return try setGroupBoundaryPolicyStub.get()
    }

    func listGroupRoles(groupId: UUID) async throws -> [GroupRole] {
        recorded.append(.listGroupRoles(groupId: groupId))
        return try listGroupRolesStub.get()
    }

    func listPermissionsCatalog() async throws -> [PermissionCatalogEntry] {
        recorded.append(.listPermissionsCatalog)
        return try listPermissionsCatalogStub.get()
    }

    func createCustomRole(_ input: CreateCustomRoleInput) async throws -> UUID {
        recorded.append(.createCustomRole(input: input))
        return try createCustomRoleStub.get()
    }

    func updateRolePermissions(_ input: UpdateRolePermissionsInput) async throws {
        recorded.append(.updateRolePermissions(input: input))
        try updateRolePermissionsStub.get()
    }

    func assignRoleToMember(_ input: AssignRoleToMemberInput) async throws {
        recorded.append(.assignRoleToMember(input: input))
        try assignRoleToMemberStub.get()
    }

    func revokeRoleFromMember(_ input: RevokeRoleFromMemberInput) async throws {
        recorded.append(.revokeRoleFromMember(input: input))
        try revokeRoleFromMemberStub.get()
    }

    func groupDissolutionActive(groupId: UUID) async throws -> GroupDissolution? {
        recorded.append(.groupDissolutionActive(groupId: groupId))
        return try groupDissolutionActiveStub.get()
    }

    func proposeDissolution(_ input: ProposeDissolutionInput) async throws -> UUID {
        recorded.append(.proposeDissolution(input: input))
        return try proposeDissolutionStub.get()
    }

    func finalizeDissolution(_ input: FinalizeDissolutionInput) async throws {
        recorded.append(.finalizeDissolution(input: input))
        try finalizeDissolutionStub.get()
    }

    func myNotificationPreferences(groupId: UUID) async throws -> [NotificationPreferenceRow] {
        recorded.append(.myNotificationPreferences(groupId: groupId))
        return try myNotificationPreferencesStub.get()
    }

    func setNotificationPreference(_ input: SetNotificationPreferenceInput) async throws {
        recorded.append(.setNotificationPreference(input: input))
        try setNotificationPreferenceStub.get()
    }

    func registerMyNotificationToken(_ input: RegisterMyNotificationTokenInput) async throws -> UUID {
        recorded.append(.registerMyNotificationToken(input: input))
        return try registerMyNotificationTokenStub.get()
    }

    func groupVisibility(groupId: UUID) async throws -> String {
        recorded.append(.groupVisibility(groupId: groupId))
        return try groupVisibilityStub.get()
    }

    func setGroupVisibility(_ input: SetGroupVisibilityInput) async throws -> String {
        recorded.append(.setGroupVisibility(input: input))
        return try setGroupVisibilityStub.get()
    }
}
