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
        case revokeInvite(inviteId: UUID, reason: String?)
        case acceptInvite(code: String)
        case leaveGroup(groupId: UUID, reason: String?)
        case recordExpense(draft: ExpenseDraft, clientId: String?)
        case recordSettlement(draft: SettlementDraft, clientId: String?)
        case paySanction(input: PaySanctionParams)
        case recordContribution(input: RecordContributionParams)
        case groupPoolBalance(groupId: UUID)
        case recordPoolCharge(input: RecordPoolChargeParams)
        case recordPoolChargeBatch(input: RecordPoolChargeBatchParams)
        case listMyGroups
        case groupSummary(groupId: UUID)
        case memberBalance(groupId: UUID, membershipId: UUID)
        case memberObligationSummary(groupId: UUID, membershipId: UUID)
        case groupSettlementPlanForMember(groupId: UUID, membershipId: UUID)
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
        case ruleEvaluationSummary(groupId: UUID, since: Date)
        case setGroupEngineActive(groupId: UUID, active: Bool)
        case groupRuleEngineQuota(groupId: UUID)
        case listDecisionTemplates
        case executeDecision(decisionId: UUID)
        case decisionProvenance(decisionId: UUID)
        case decisionSummary(groupId: UUID)
        case applyDecisionTemplate(decisionId: UUID, templateKey: String)
        case membershipProvenance(membershipId: UUID)
        case approveMembershipRequest(membershipId: UUID)
        case listMembershipTransitions
        case groupSanctionPaymentStatus(sanctionId: UUID)
        case proposeSanctionPaymentPlan(input: ProposeSanctionPaymentPlanParams)
        case cancelSanctionPaymentPlan(input: CancelSanctionPaymentPlanParams)
        case groupSanctionPaymentPlanActive(sanctionId: UUID)
        case groupResourcesActive(groupId: UUID)
        case createGroupResource(input: CreateGroupResourceInput)
        case archiveGroupResource(input: ArchiveGroupResourceInput)
        case setResourceOwnership(input: SetResourceOwnershipParams)
        case groupResourceDetail(resourceId: UUID)
        case updateResource(input: UpdateResourceParams)
        case groupEventsForEntity(input: GroupEventsForEntityParams)
        case assignAssetCustodian(input: AssignAssetCustodianParams)
        case releaseAssetCustodian(input: ReleaseAssetCustodianParams)
        case markAssetCondition(input: MarkAssetConditionParams)
        case recordAssetValuation(input: RecordAssetValuationParams)
        case lockFund(input: LockFundParams)
        case unlockFund(input: UnlockFundParams)
        case setFundThreshold(input: SetFundThresholdParams)
        case bookResource(input: BookResourceParams)
        case cancelBooking(input: CancelBookingParams)
        case listBookingsForResource(input: ListBookingsForResourceParams)
        case grantRight(input: GrantRightParams)
        case transferRight(input: TransferRightParams)
        case revokeRight(input: RevokeRightParams)
        case expireRight(input: ExpireRightParams)
        case assignSlot(input: AssignSlotParams)
        case releaseSlot(input: ReleaseSlotParams)
        case expireSlot(input: ExpireSlotParams)
        case setMembershipState(input: SetMembershipStateParams)
        case groupFoundationStatus(groupId: UUID)
        case groupDecisionRules(groupId: UUID)
        case setDecisionRules(input: SetDecisionRulesInput)
        case groupGovernanceVersions(groupId: UUID, limit: Int)
        case memberReputationEvents(groupId: UUID, subjectMembershipId: UUID, limit: Int)
        case groupSanctionsActive(groupId: UUID, limit: Int)
        case issueSanction(input: IssueSanctionInput)
        case groupDisputesActive(groupId: UUID, limit: Int)
        case disputeSanction(input: DisputeSanctionInput)
        case groupEventsRecent(groupId: UUID, limit: Int, before: Date?)
        case groupEventsForMember(groupId: UUID, membershipId: UUID, limit: Int)
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
        case listMyInbox(input: ListMyInboxParams)
        case markInboxRead(input: MarkInboxReadParams)
        case markAllInboxRead(input: MarkAllInboxReadParams)
        case myInboxUnreadCount(input: MyInboxUnreadCountParams)
        case groupVisibility(groupId: UUID)
        case setGroupVisibility(input: SetGroupVisibilityInput)
        case globalSearch(input: GlobalSearchParams)
        case requestMembership(input: RequestMembershipParams)
        case requestOrExecuteAction(actionKey: String, targetId: UUID?)
    }

    private(set) var recorded: [RecordedCall] = []

    // MARK: - Stubs

    private var createGroupStub: Result<UUID, RuulError> = .success(UUID())
    private var inviteMemberStub: Result<InviteCreated, RuulError> = .success(
        InviteCreated(inviteId: UUID(), code: "STUBSTUB", placeholderMembershipId: UUID())
    )
    private var revokeInviteStub: Result<Void, RuulError> = .success(())
    private var acceptInviteStub: Result<AcceptInviteResult, RuulError> = .success(
        AcceptInviteResult(groupId: UUID(), membershipId: UUID())
    )
    private var leaveGroupStub: Result<Void, RuulError> = .success(())
    private var recordExpenseStub: Result<UUID, RuulError> = .success(UUID())
    private var recordSettlementStub: Result<SettlementResult, RuulError> = .success(
        SettlementResult(settlementId: UUID(), transactionId: UUID())
    )
    private var paySanctionStub: Result<SettlementResult, RuulError> = .success(
        SettlementResult(settlementId: UUID(), transactionId: UUID())
    )
    private var recordContributionStub: Result<UUID, RuulError> = .success(UUID())
    private var groupPoolBalanceStub: Result<GroupPoolBalance, RuulError> = .success(
        GroupPoolBalance(groupId: UUID(), contributionsIn: 0, settlementsIn: 0, payoutsOut: 0, reversalsNet: 0, net: 0, unit: "MXN")
    )
    private var recordPoolChargeStub: Result<UUID, RuulError> = .success(UUID())
    private var recordPoolChargeBatchStub: Result<Int, RuulError> = .success(0)
    private var listMyGroupsStub: Result<[GroupListItem], RuulError> = .success([])
    private var groupSummaryStub: Result<CanonicalGroupSummary, RuulError> = .success(
        CanonicalGroupSummary(groupId: UUID(), memberCount: 0, openDecisions: 0, openDisputes: 0, openObligations: 0, recentEvents: [])
    )
    private var memberBalanceStub: Result<Decimal, RuulError> = .success(0)
    private var memberObligationSummaryStub: Result<[ObligationSummary], RuulError> = .success([])
    private var groupSettlementPlanForMemberStub: Result<[SettlementPlanItem], RuulError> = .success([])
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
    private var groupResourceDetailStub: Result<GroupResourceDetail, RuulError> = .success(
        GroupResourceDetail(
            resource: GroupResource(id: UUID(), groupId: UUID(), resourceType: .asset, name: "")
        )
    )
    private var updateResourceStub: Result<Void, RuulError> = .success(())
    private var groupEventsForEntityStub: Result<[GroupEvent], RuulError> = .success([])
    private var assignAssetCustodianStub: Result<UUID, RuulError> = .success(UUID())
    private var releaseAssetCustodianStub: Result<UUID, RuulError> = .success(UUID())
    private var markAssetConditionStub: Result<UUID, RuulError> = .success(UUID())
    private var recordAssetValuationStub: Result<Void, RuulError> = .success(())
    private var lockFundStub: Result<UUID, RuulError> = .success(UUID())
    private var unlockFundStub: Result<UUID, RuulError> = .success(UUID())
    private var setFundThresholdStub: Result<UUID, RuulError> = .success(UUID())
    private var bookResourceStub: Result<UUID, RuulError> = .success(UUID())
    private var cancelBookingStub: Result<UUID, RuulError> = .success(UUID())
    private var listBookingsForResourceStub: Result<[GroupResourceBooking], RuulError> = .success([])
    private var grantRightStub: Result<UUID, RuulError> = .success(UUID())
    private var transferRightStub: Result<UUID, RuulError> = .success(UUID())
    private var revokeRightStub: Result<UUID, RuulError> = .success(UUID())
    private var expireRightStub: Result<UUID, RuulError> = .success(UUID())
    private var assignSlotStub: Result<UUID, RuulError> = .success(UUID())
    private var releaseSlotStub: Result<UUID, RuulError> = .success(UUID())
    private var expireSlotStub: Result<UUID, RuulError> = .success(UUID())
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
    private var groupGovernanceVersionsStub: Result<[GroupGovernanceVersion], RuulError> = .success([])
    private var memberReputationEventsStub: Result<[GroupReputationEvent], RuulError> = .success([])
    private var groupSanctionsActiveStub: Result<[GroupSanction], RuulError> = .success([])
    private var issueSanctionStub: Result<UUID, RuulError> = .success(UUID())
    private var groupDisputesActiveStub: Result<[GroupDispute], RuulError> = .success([])
    private var disputeSanctionStub: Result<UUID, RuulError> = .success(UUID())
    private var groupEventsRecentStub: Result<[GroupEvent], RuulError> = .success([])
    private var groupEventsForMemberStub: Result<[GroupEvent], RuulError> = .success([])
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
    private var myWorldSummaryStub: Result<MyWorldSummary, RuulError>?

    init() {}

    // MARK: - Stub setters

    func setCreateGroupStub(_ stub: Result<UUID, RuulError>) { createGroupStub = stub }
    func setMyWorldSummaryStub(_ stub: Result<MyWorldSummary, RuulError>?) { myWorldSummaryStub = stub }
    func setInviteMemberStub(_ stub: Result<InviteCreated, RuulError>) { inviteMemberStub = stub }
    func setRevokeInviteStub(_ stub: Result<Void, RuulError>) { revokeInviteStub = stub }
    func setAcceptInviteStub(_ stub: Result<AcceptInviteResult, RuulError>) { acceptInviteStub = stub }
    func setLeaveGroupStub(_ stub: Result<Void, RuulError>) { leaveGroupStub = stub }
    func setRecordExpenseStub(_ stub: Result<UUID, RuulError>) { recordExpenseStub = stub }
    func setRecordSettlementStub(_ stub: Result<SettlementResult, RuulError>) { recordSettlementStub = stub }
    func setPaySanctionStub(_ stub: Result<SettlementResult, RuulError>) { paySanctionStub = stub }
    func setRecordContributionStub(_ stub: Result<UUID, RuulError>) { recordContributionStub = stub }
    func setGroupPoolBalanceStub(_ stub: Result<GroupPoolBalance, RuulError>) { groupPoolBalanceStub = stub }
    func setRecordPoolChargeStub(_ stub: Result<UUID, RuulError>) { recordPoolChargeStub = stub }
    func setRecordPoolChargeBatchStub(_ stub: Result<Int, RuulError>) { recordPoolChargeBatchStub = stub }
    func setListMyGroupsStub(_ stub: Result<[GroupListItem], RuulError>) { listMyGroupsStub = stub }
    func setGroupSummaryStub(_ stub: Result<CanonicalGroupSummary, RuulError>) { groupSummaryStub = stub }
    func setMemberBalanceStub(_ stub: Result<Decimal, RuulError>) { memberBalanceStub = stub }
    func setMemberObligationSummaryStub(_ stub: Result<[ObligationSummary], RuulError>) { memberObligationSummaryStub = stub }
    func setGroupSettlementPlanForMemberStub(_ stub: Result<[SettlementPlanItem], RuulError>) { groupSettlementPlanForMemberStub = stub }
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
    func setGroupResourceDetailStub(_ stub: Result<GroupResourceDetail, RuulError>) { groupResourceDetailStub = stub }
    func setUpdateResourceStub(_ stub: Result<Void, RuulError>) { updateResourceStub = stub }
    func setGroupEventsForEntityStub(_ stub: Result<[GroupEvent], RuulError>) { groupEventsForEntityStub = stub }
    func setAssignAssetCustodianStub(_ stub: Result<UUID, RuulError>) { assignAssetCustodianStub = stub }
    func setReleaseAssetCustodianStub(_ stub: Result<UUID, RuulError>) { releaseAssetCustodianStub = stub }
    func setMarkAssetConditionStub(_ stub: Result<UUID, RuulError>) { markAssetConditionStub = stub }
    func setRecordAssetValuationStub(_ stub: Result<Void, RuulError>) { recordAssetValuationStub = stub }
    func setLockFundStub(_ stub: Result<UUID, RuulError>) { lockFundStub = stub }
    func setUnlockFundStub(_ stub: Result<UUID, RuulError>) { unlockFundStub = stub }
    func setSetFundThresholdStub(_ stub: Result<UUID, RuulError>) { setFundThresholdStub = stub }
    func setBookResourceStub(_ stub: Result<UUID, RuulError>) { bookResourceStub = stub }
    func setCancelBookingStub(_ stub: Result<UUID, RuulError>) { cancelBookingStub = stub }
    func setListBookingsForResourceStub(_ stub: Result<[GroupResourceBooking], RuulError>) { listBookingsForResourceStub = stub }
    func setGrantRightStub(_ stub: Result<UUID, RuulError>) { grantRightStub = stub }
    func setTransferRightStub(_ stub: Result<UUID, RuulError>) { transferRightStub = stub }
    func setRevokeRightStub(_ stub: Result<UUID, RuulError>) { revokeRightStub = stub }
    func setExpireRightStub(_ stub: Result<UUID, RuulError>) { expireRightStub = stub }
    func setAssignSlotStub(_ stub: Result<UUID, RuulError>) { assignSlotStub = stub }
    func setReleaseSlotStub(_ stub: Result<UUID, RuulError>) { releaseSlotStub = stub }
    func setExpireSlotStub(_ stub: Result<UUID, RuulError>) { expireSlotStub = stub }
    func setSetMembershipStateStub(_ stub: Result<Void, RuulError>) { setMembershipStateStub = stub }
    func setGroupFoundationStatusStub(_ stub: Result<GroupFoundationStatus, RuulError>) { groupFoundationStatusStub = stub }
    func setGroupDecisionRulesStub(_ stub: Result<GroupDecisionRules, RuulError>) { groupDecisionRulesStub = stub }
    func setSetDecisionRulesStub(_ stub: Result<GroupDecisionRules, RuulError>) { setDecisionRulesStub = stub }
    func setGroupGovernanceVersionsStub(_ stub: Result<[GroupGovernanceVersion], RuulError>) { groupGovernanceVersionsStub = stub }
    func setMemberReputationEventsStub(_ stub: Result<[GroupReputationEvent], RuulError>) { memberReputationEventsStub = stub }
    func setGroupSanctionsActiveStub(_ stub: Result<[GroupSanction], RuulError>) { groupSanctionsActiveStub = stub }
    func setIssueSanctionStub(_ stub: Result<UUID, RuulError>) { issueSanctionStub = stub }
    func setGroupDisputesActiveStub(_ stub: Result<[GroupDispute], RuulError>) { groupDisputesActiveStub = stub }
    func setDisputeSanctionStub(_ stub: Result<UUID, RuulError>) { disputeSanctionStub = stub }
    func setGroupEventsRecentStub(_ stub: Result<[GroupEvent], RuulError>) { groupEventsRecentStub = stub }
    func setGroupEventsForMemberStub(_ stub: Result<[GroupEvent], RuulError>) { groupEventsForMemberStub = stub }
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

    func inviteMember(groupId: UUID, email: String?, phone: String?, membershipType: String, message: String?) async throws -> InviteCreated {
        recorded.append(.inviteMember(groupId: groupId, email: email, phone: phone, membershipType: membershipType, message: message))
        return try inviteMemberStub.get()
    }

    func revokeInvite(inviteId: UUID, reason: String?) async throws {
        recorded.append(.revokeInvite(inviteId: inviteId, reason: reason))
        try revokeInviteStub.get()
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

    func paySanction(_ input: PaySanctionParams) async throws -> SettlementResult {
        recorded.append(.paySanction(input: input))
        return try paySanctionStub.get()
    }

    func recordContribution(_ input: RecordContributionParams) async throws -> UUID {
        recorded.append(.recordContribution(input: input))
        return try recordContributionStub.get()
    }

    func groupPoolBalance(groupId: UUID) async throws -> GroupPoolBalance {
        recorded.append(.groupPoolBalance(groupId: groupId))
        return try groupPoolBalanceStub.get()
    }

    func recordPoolCharge(_ input: RecordPoolChargeParams) async throws -> UUID {
        recorded.append(.recordPoolCharge(input: input))
        return try recordPoolChargeStub.get()
    }

    func recordPoolChargeBatch(_ input: RecordPoolChargeBatchParams) async throws -> Int {
        recorded.append(.recordPoolChargeBatch(input: input))
        return try recordPoolChargeBatchStub.get()
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

    func groupSettlementPlanForMember(groupId: UUID, membershipId: UUID) async throws -> [SettlementPlanItem] {
        recorded.append(.groupSettlementPlanForMember(groupId: groupId, membershipId: membershipId))
        return try groupSettlementPlanForMemberStub.get()
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

    // MARK: - V3-D.17

    private var ruleEvaluationSummaryStub: Result<GroupRuleEngineSummary, RuulError> = .success(
        GroupRuleEngineSummary(
            groupId: UUID(),
            since: Date(timeIntervalSince1970: 0),
            engineActive: true,
            totalEvaluations: 0,
            matchedCount: 0,
            unmatchedCount: 0,
            emittedActionsCount: 0,
            failedActionsCount: 0
        )
    )
    private var setGroupEngineActiveStub: Result<GroupEngineToggleResult, RuulError> = .success(
        GroupEngineToggleResult(groupId: UUID(), engineActive: true, changed: false)
    )
    private var groupRuleEngineQuotaStub: Result<GroupRuleEngineQuota?, RuulError> = .success(nil)

    func setRuleEvaluationSummaryStub(_ stub: Result<GroupRuleEngineSummary, RuulError>) { ruleEvaluationSummaryStub = stub }
    func setSetGroupEngineActiveStub(_ stub: Result<GroupEngineToggleResult, RuulError>) { setGroupEngineActiveStub = stub }
    func setGroupRuleEngineQuotaStub(_ stub: Result<GroupRuleEngineQuota?, RuulError>) { groupRuleEngineQuotaStub = stub }

    func ruleEvaluationSummary(groupId: UUID, since: Date) async throws -> GroupRuleEngineSummary {
        recorded.append(.ruleEvaluationSummary(groupId: groupId, since: since))
        return try ruleEvaluationSummaryStub.get()
    }

    func setGroupEngineActive(groupId: UUID, active: Bool) async throws -> GroupEngineToggleResult {
        recorded.append(.setGroupEngineActive(groupId: groupId, active: active))
        return try setGroupEngineActiveStub.get()
    }

    func groupRuleEngineQuota(groupId: UUID) async throws -> GroupRuleEngineQuota? {
        recorded.append(.groupRuleEngineQuota(groupId: groupId))
        return try groupRuleEngineQuotaStub.get()
    }

    // MARK: - V3-D.18

    private var listDecisionTemplatesStub: Result<[DecisionTemplate], RuulError> = .success([])
    private var executeDecisionStub: Result<ExecuteDecisionResult, RuulError> = .success(
        ExecuteDecisionResult(decisionId: UUID(), status: "executed")
    )
    private var decisionProvenanceStub: Result<DecisionProvenance, RuulError> = .success(
        DecisionProvenance(found: false, reason: "not_found")
    )
    private var decisionSummaryStub: Result<DecisionSummary, RuulError> = .success(
        DecisionSummary(
            groupId: UUID(), activeMembers: 0,
            open: 0, passed: 0, rejected: 0, executed: 0, cancelled: 0,
            avgTurnout: 0, participationRate: 0
        )
    )

    func setListDecisionTemplatesStub(_ stub: Result<[DecisionTemplate], RuulError>) { listDecisionTemplatesStub = stub }
    func setExecuteDecisionStub(_ stub: Result<ExecuteDecisionResult, RuulError>) { executeDecisionStub = stub }
    func setDecisionProvenanceStub(_ stub: Result<DecisionProvenance, RuulError>) { decisionProvenanceStub = stub }
    func setDecisionSummaryStub(_ stub: Result<DecisionSummary, RuulError>) { decisionSummaryStub = stub }

    func listDecisionTemplates() async throws -> [DecisionTemplate] {
        recorded.append(.listDecisionTemplates)
        return try listDecisionTemplatesStub.get()
    }

    func executeDecision(decisionId: UUID) async throws -> ExecuteDecisionResult {
        recorded.append(.executeDecision(decisionId: decisionId))
        return try executeDecisionStub.get()
    }

    func decisionProvenance(decisionId: UUID) async throws -> DecisionProvenance {
        recorded.append(.decisionProvenance(decisionId: decisionId))
        return try decisionProvenanceStub.get()
    }

    func decisionSummary(groupId: UUID) async throws -> DecisionSummary {
        recorded.append(.decisionSummary(groupId: groupId))
        return try decisionSummaryStub.get()
    }

    private var applyDecisionTemplateStub: Result<ApplyDecisionTemplateResult, RuulError> = .success(
        ApplyDecisionTemplateResult(decisionId: UUID(), templateKey: "decision.custom", executionMode: .manual)
    )

    func setApplyDecisionTemplateStub(_ stub: Result<ApplyDecisionTemplateResult, RuulError>) {
        applyDecisionTemplateStub = stub
    }

    func applyDecisionTemplate(decisionId: UUID, templateKey: String) async throws -> ApplyDecisionTemplateResult {
        recorded.append(.applyDecisionTemplate(decisionId: decisionId, templateKey: templateKey))
        return try applyDecisionTemplateStub.get()
    }

    // MARK: - V3-D.20

    private var membershipProvenanceStub: Result<MembershipProvenance, RuulError> = .success(
        MembershipProvenance(
            found: false, reason: "not_found",
            membershipId: nil, groupId: nil, userId: nil,
            currentState: nil, membershipType: nil, currentReason: nil,
            joinedAt: nil, confirmedAt: nil,
            pausedUntil: nil, suspendedUntil: nil, leftAt: nil, removedAt: nil, unbannedAt: nil,
            joinedVia: nil, invitedBy: nil,
            lastTransition: nil, sourceEvent: nil, sourceDecision: nil,
            sourceRuleTitle: nil, sourceConsequenceKind: nil
        )
    )
    private var approveMembershipRequestStub: Result<ApproveMembershipRequestResult, RuulError> = .success(
        ApproveMembershipRequestResult(membershipId: UUID(), groupId: UUID(), status: "active", changed: true)
    )
    private var listMembershipTransitionsStub: Result<[MembershipStateTransition], RuulError> = .success([])

    func setMembershipProvenanceStub(_ stub: Result<MembershipProvenance, RuulError>) { membershipProvenanceStub = stub }
    func setApproveMembershipRequestStub(_ stub: Result<ApproveMembershipRequestResult, RuulError>) { approveMembershipRequestStub = stub }
    func setListMembershipTransitionsStub(_ stub: Result<[MembershipStateTransition], RuulError>) { listMembershipTransitionsStub = stub }

    func membershipProvenance(membershipId: UUID) async throws -> MembershipProvenance {
        recorded.append(.membershipProvenance(membershipId: membershipId))
        return try membershipProvenanceStub.get()
    }

    func approveMembershipRequest(membershipId: UUID) async throws -> ApproveMembershipRequestResult {
        recorded.append(.approveMembershipRequest(membershipId: membershipId))
        return try approveMembershipRequestStub.get()
    }

    func listMembershipTransitions() async throws -> [MembershipStateTransition] {
        recorded.append(.listMembershipTransitions)
        return try listMembershipTransitionsStub.get()
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

    func groupResourceDetail(resourceId: UUID) async throws -> GroupResourceDetail {
        recorded.append(.groupResourceDetail(resourceId: resourceId))
        return try groupResourceDetailStub.get()
    }

    func updateResource(_ input: UpdateResourceParams) async throws {
        recorded.append(.updateResource(input: input))
        try updateResourceStub.get()
    }

    func groupEventsForEntity(_ input: GroupEventsForEntityParams) async throws -> [GroupEvent] {
        recorded.append(.groupEventsForEntity(input: input))
        return try groupEventsForEntityStub.get()
    }

    func assignAssetCustodian(_ input: AssignAssetCustodianParams) async throws -> UUID {
        recorded.append(.assignAssetCustodian(input: input))
        return try assignAssetCustodianStub.get()
    }

    func releaseAssetCustodian(_ input: ReleaseAssetCustodianParams) async throws -> UUID {
        recorded.append(.releaseAssetCustodian(input: input))
        return try releaseAssetCustodianStub.get()
    }

    func markAssetCondition(_ input: MarkAssetConditionParams) async throws -> UUID {
        recorded.append(.markAssetCondition(input: input))
        return try markAssetConditionStub.get()
    }

    func recordAssetValuation(_ input: RecordAssetValuationParams) async throws {
        recorded.append(.recordAssetValuation(input: input))
        try recordAssetValuationStub.get()
    }

    func lockFund(_ input: LockFundParams) async throws -> UUID {
        recorded.append(.lockFund(input: input))
        return try lockFundStub.get()
    }

    func unlockFund(_ input: UnlockFundParams) async throws -> UUID {
        recorded.append(.unlockFund(input: input))
        return try unlockFundStub.get()
    }

    func setFundThreshold(_ input: SetFundThresholdParams) async throws -> UUID {
        recorded.append(.setFundThreshold(input: input))
        return try setFundThresholdStub.get()
    }

    func bookResource(_ input: BookResourceParams) async throws -> UUID {
        recorded.append(.bookResource(input: input))
        return try bookResourceStub.get()
    }

    func cancelBooking(_ input: CancelBookingParams) async throws -> UUID {
        recorded.append(.cancelBooking(input: input))
        return try cancelBookingStub.get()
    }

    func listBookingsForResource(_ input: ListBookingsForResourceParams) async throws -> [GroupResourceBooking] {
        recorded.append(.listBookingsForResource(input: input))
        return try listBookingsForResourceStub.get()
    }

    func grantRight(_ input: GrantRightParams) async throws -> UUID {
        recorded.append(.grantRight(input: input))
        return try grantRightStub.get()
    }

    func transferRight(_ input: TransferRightParams) async throws -> UUID {
        recorded.append(.transferRight(input: input))
        return try transferRightStub.get()
    }

    func revokeRight(_ input: RevokeRightParams) async throws -> UUID {
        recorded.append(.revokeRight(input: input))
        return try revokeRightStub.get()
    }

    func expireRight(_ input: ExpireRightParams) async throws -> UUID {
        recorded.append(.expireRight(input: input))
        return try expireRightStub.get()
    }

    func assignSlot(_ input: AssignSlotParams) async throws -> UUID {
        recorded.append(.assignSlot(input: input))
        return try assignSlotStub.get()
    }

    func releaseSlot(_ input: ReleaseSlotParams) async throws -> UUID {
        recorded.append(.releaseSlot(input: input))
        return try releaseSlotStub.get()
    }

    func expireSlot(_ input: ExpireSlotParams) async throws -> UUID {
        recorded.append(.expireSlot(input: input))
        return try expireSlotStub.get()
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

    func groupGovernanceVersions(groupId: UUID, limit: Int) async throws -> [GroupGovernanceVersion] {
        recorded.append(.groupGovernanceVersions(groupId: groupId, limit: limit))
        return try groupGovernanceVersionsStub.get()
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

    func groupEventsForMember(groupId: UUID, membershipId: UUID, limit: Int) async throws -> [GroupEvent] {
        recorded.append(.groupEventsForMember(groupId: groupId, membershipId: membershipId, limit: limit))
        return try groupEventsForMemberStub.get()
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

    // MARK: - V3-D.21 — Inbox

    private var listMyInboxStub: Result<[InboxItem], RuulError> = .success([])
    private var markInboxReadStub: Result<Void, RuulError> = .success(())
    private var markAllInboxReadStub: Result<Int, RuulError> = .success(0)
    private var myInboxUnreadCountStub: Result<Int, RuulError> = .success(0)

    func stubListMyInbox(_ result: Result<[InboxItem], RuulError>) { listMyInboxStub = result }
    func stubMarkInboxRead(_ result: Result<Void, RuulError>) { markInboxReadStub = result }
    func stubMarkAllInboxRead(_ result: Result<Int, RuulError>) { markAllInboxReadStub = result }
    func stubMyInboxUnreadCount(_ result: Result<Int, RuulError>) { myInboxUnreadCountStub = result }

    func listMyInbox(_ input: ListMyInboxParams) async throws -> [InboxItem] {
        recorded.append(.listMyInbox(input: input))
        return try listMyInboxStub.get()
    }

    func markInboxRead(_ input: MarkInboxReadParams) async throws {
        recorded.append(.markInboxRead(input: input))
        try markInboxReadStub.get()
    }

    func markAllInboxRead(_ input: MarkAllInboxReadParams) async throws -> Int {
        recorded.append(.markAllInboxRead(input: input))
        return try markAllInboxReadStub.get()
    }

    func myInboxUnreadCount(_ input: MyInboxUnreadCountParams) async throws -> Int {
        recorded.append(.myInboxUnreadCount(input: input))
        return try myInboxUnreadCountStub.get()
    }

    // MARK: - V3-D.22 — Search MVP

    private var globalSearchStub: Result<[SearchResult], RuulError> = .success([])
    func stubGlobalSearch(_ result: Result<[SearchResult], RuulError>) { globalSearchStub = result }

    func globalSearch(_ input: GlobalSearchParams) async throws -> [SearchResult] {
        recorded.append(.globalSearch(input: input))
        return try globalSearchStub.get()
    }

    // MARK: - V3-D.24 — Request membership

    private var requestMembershipStub: Result<UUID, RuulError> = .success(UUID())
    func stubRequestMembership(_ result: Result<UUID, RuulError>) { requestMembershipStub = result }

    func requestMembership(_ input: RequestMembershipParams) async throws -> UUID {
        recorded.append(.requestMembership(input: input))
        return try requestMembershipStub.get()
    }

    // MARK: - V3-D.22 — Action Governance executor

    /// Default returns `.directAllowed` so existing repository tests
    /// (which now route writes through `request_or_execute_action`)
    /// keep observing the underlying RPC as before. Tests that want
    /// to assert decision-opening can override the stub.
    private var requestOrExecuteActionStub: Result<ActionOutcome, RuulError> = .success(
        .directAllowed(plan: ActionPlan(
            actionKey: "mock",
            executableRPC: nil,
            targetKind: nil,
            targetId: nil,
            reason: "mock_direct_allowed",
            isFounder: true,
            isAdmin: true,
            riskLevel: "low"
        ))
    )
    func stubRequestOrExecuteAction(_ result: Result<ActionOutcome, RuulError>) {
        requestOrExecuteActionStub = result
    }

    func requestOrExecuteAction(_ input: RequestOrExecuteActionParams) async throws -> ActionOutcome {
        recorded.append(.requestOrExecuteAction(actionKey: input.pActionKey, targetId: input.pTargetId))
        return try requestOrExecuteActionStub.get()
    }

    // MARK: - V3-D.24 P12A — Read Models

    func groupHomeSummary(groupId: UUID) async throws -> GroupHomeSummary {
        // No tests depend on this yet; surface a clear failure if invoked.
        throw RuulError.unexpected(message: "MockRuulRPCClient.groupHomeSummary not stubbed")
    }

    func resourceDetailSummary(resourceId: UUID) async throws -> ResourceDetailSummary {
        throw RuulError.unexpected(message: "MockRuulRPCClient.resourceDetailSummary not stubbed")
    }

    func eventDetailSummary(eventId: UUID) async throws -> CalendarEventDetailSummary {
        throw RuulError.unexpected(message: "MockRuulRPCClient.eventDetailSummary not stubbed")
    }

    func decisionLiveResult(decisionId: UUID) async throws -> DecisionLiveResult {
        throw RuulError.unexpected(message: "MockRuulRPCClient.decisionLiveResult not stubbed")
    }

    // R.0E.2 — my_world_summary (R.0H.1 iOS adopt)
    func myWorldSummary() async throws -> MyWorldSummary {
        if let stubbed = myWorldSummaryStub {
            return try stubbed.get()
        }
        throw RuulError.unexpected(message: "MockRuulRPCClient.myWorldSummary not stubbed")
    }

    // V3 D.24 P2A subtype wrappers — stubs (tests can override per case).
    func createFundResource(_ input: CreateFundResourceParams) async throws -> UUID {
        throw RuulError.unexpected(message: "MockRuulRPCClient.createFundResource not stubbed")
    }
    func createSpaceResource(_ input: CreateSpaceResourceParams) async throws -> UUID {
        throw RuulError.unexpected(message: "MockRuulRPCClient.createSpaceResource not stubbed")
    }
    func createAssetResource(_ input: CreateAssetResourceParams) async throws -> UUID {
        throw RuulError.unexpected(message: "MockRuulRPCClient.createAssetResource not stubbed")
    }
    func createRightResource(_ input: CreateRightResourceParams) async throws -> UUID {
        throw RuulError.unexpected(message: "MockRuulRPCClient.createRightResource not stubbed")
    }
    func createSlotResource(_ input: CreateSlotResourceParams) async throws -> UUID {
        throw RuulError.unexpected(message: "MockRuulRPCClient.createSlotResource not stubbed")
    }
    func createGenericResource(_ input: CreateGenericResourceParams) async throws -> UUID {
        throw RuulError.unexpected(message: "MockRuulRPCClient.createGenericResource not stubbed")
    }
}
