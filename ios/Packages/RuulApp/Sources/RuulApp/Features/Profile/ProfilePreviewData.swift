import Foundation
import RuulCore

/// Fixtures + in-memory stubs that let `EditProfileView` and
/// `ProfileOnboardingNudge` render in Xcode previews without touching
/// Supabase. Mirrors the `MembersPreviewData` pattern (the data lives
/// in RuulApp so the canonical RuulCore stays lean).
enum ProfilePreviewData {

    static let empty = Profile(
        id: UUID(),
        username: nil,
        displayName: nil,
        avatarURL: nil,
        bio: nil,
        createdAt: Date(timeIntervalSinceNow: -86_400),
        updatedAt: Date(timeIntervalSinceNow: -86_400)
    )

    static let completed = Profile(
        id: UUID(),
        username: "jose_mizrahi",
        displayName: "Jose Mizrahi",
        avatarURL: nil,
        bio: "Founder · Ruul",
        createdAt: Date(timeIntervalSinceNow: -86_400 * 30),
        updatedAt: Date()
    )

    static let longName = Profile(
        id: UUID(),
        username: "christopher_avc",
        displayName: "Christopher Alexander de la Vega y Castillo del Mar",
        avatarURL: nil,
        bio: nil,
        createdAt: Date(),
        updatedAt: Date()
    )

    /// Returns a `ProfileStore` already in `.loaded` state with no
    /// display_name so the nudge renders.
    @MainActor
    static func emptyStore() -> ProfileStore {
        let store = makeStore(seed: empty)
        // Drive a synchronous "loaded" so requiresProfileCompletion fires
        // without awaiting an async refresh in previews.
        Task { await store.refresh() }
        return store
    }

    /// Returns a `ProfileStore` already in `.loaded` state with a
    /// usable display_name (nudge stays hidden).
    @MainActor
    static func completedStore() -> ProfileStore {
        let store = makeStore(seed: completed)
        Task { await store.refresh() }
        return store
    }

    @MainActor
    private static func makeStore(seed: Profile) -> ProfileStore {
        let client = StaticProfileRPCClient(seed: seed)
        let repository = CanonicalProfileRepository(rpc: client)
        return ProfileStore(repository: repository)
    }
}

/// Minimal `RuulRPCClient` impl that only services profile calls and
/// fatals on everything else — that is fine for previews because the
/// preview surface only touches the two profile RPCs. Real builds
/// always use `SupabaseRuulRPCClient`.
private struct StaticProfileRPCClient: RuulRPCClient, @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        var profile: Profile
        init(_ profile: Profile) { self.profile = profile }
    }

    private let box: Box

    init(seed: Profile) {
        self.box = Box(seed)
    }

    func myProfile() async throws -> Profile { box.profile }

    func updateMyProfile(_ input: UpdateMyProfileInput) async throws -> Profile {
        let updated = Profile(
            id: box.profile.id,
            username: input.pUsername,
            displayName: input.pDisplayName,
            avatarURL: input.pAvatarUrl.flatMap(URL.init(string:)),
            bio: input.pBio,
            createdAt: box.profile.createdAt,
            updatedAt: Date()
        )
        box.profile = updated
        return updated
    }

    // The rest of the protocol — previews never invoke these.
    func createGroup(name: String, slug: String?, category: String?, purposeDeclared: String?) async throws -> UUID { UUID() }
    func inviteMember(groupId: UUID, email: String?, phone: String?, membershipType: String, message: String?) async throws -> InviteCreated {
        InviteCreated(inviteId: UUID(), code: "PREVIEW1", placeholderMembershipId: UUID())
    }
    func revokeInvite(inviteId: UUID, reason: String?) async throws {}
    func acceptInvite(code: String) async throws -> AcceptInviteResult { .init(groupId: UUID(), membershipId: UUID()) }
    func leaveGroup(groupId: UUID, reason: String?) async throws {}
    func recordExpense(_ draft: ExpenseDraft, clientId: String?) async throws -> UUID { UUID() }
    func recordSettlement(_ draft: SettlementDraft, clientId: String?) async throws -> SettlementResult {
        .init(settlementId: UUID(), transactionId: UUID())
    }
    func paySanction(_ input: PaySanctionParams) async throws -> SettlementResult {
        .init(settlementId: UUID(), transactionId: UUID())
    }
    func recordContribution(_ input: RecordContributionParams) async throws -> UUID { UUID() }
    func groupPoolBalance(groupId: UUID) async throws -> GroupPoolBalance {
        GroupPoolBalance(groupId: groupId, contributionsIn: 0, settlementsIn: 0, payoutsOut: 0, reversalsNet: 0, net: 0, unit: "MXN")
    }
    func recordPoolCharge(_ input: RecordPoolChargeParams) async throws -> UUID { UUID() }
    func recordPoolChargeBatch(_ input: RecordPoolChargeBatchParams) async throws -> Int { input.pTargetMembershipIds.count }
    func listMyGroups() async throws -> [GroupListItem] { [] }
    func groupSummary(groupId: UUID) async throws -> CanonicalGroupSummary {
        .init(groupId: groupId, memberCount: 0, openDecisions: 0, openDisputes: 0, openObligations: 0, recentEvents: [])
    }
    func memberBalance(groupId: UUID, membershipId: UUID) async throws -> Decimal { 0 }
    func memberObligationSummary(groupId: UUID, membershipId: UUID) async throws -> [ObligationSummary] { [] }
    func groupSettlementPlanForMember(groupId: UUID, membershipId: UUID) async throws -> [SettlementPlanItem] { [] }
    func listMemberPermissions(groupId: UUID, userId: UUID?) async throws -> [String] { [] }
    func groupMembers(groupId: UUID) async throws -> [MemberListItem] { [] }
    func groupMembershipBoundary(groupId: UUID) async throws -> [MembershipBoundaryItem] { [] }
    func groupPurposesActive(groupId: UUID) async throws -> [GroupPurpose] { [] }
    func setGroupPurpose(_ input: SetGroupPurposeInput) async throws -> GroupPurpose {
        GroupPurpose(id: UUID(), groupId: input.pGroupId, kind: .declared, body: input.pBody)
    }
    func groupRulesActive(groupId: UUID) async throws -> [GroupRule] { [] }
    func createTextRule(_ input: CreateTextRuleInput) async throws -> CreateTextRuleResult {
        CreateTextRuleResult(ruleId: UUID(), versionId: UUID())
    }
    func archiveRule(_ input: ArchiveRuleInput) async throws {}
    func listRuleShapes() async throws -> [RuleShape] { [] }
    func validateRuleShape(_ input: ValidateRuleShapeInput) async throws -> RuleShapeValidationResult {
        RuleShapeValidationResult(valid: true, errors: [], shapeKey: nil, triggerEventType: nil)
    }
    func createEngineRule(_ input: CreateEngineRuleInput) async throws -> CreateEngineRuleResult {
        CreateEngineRuleResult(ruleId: UUID(), versionId: UUID())
    }
    func groupRulesEngine(groupId: UUID) async throws -> [EngineRule] { [] }
    func groupRuleEvaluations(groupId: UUID, limit: Int, before: Date?) async throws -> [GroupRuleEvaluation] { [] }
    func groupRuleEvaluationSummary(groupId: UUID, windowHours: Int) async throws -> GroupRuleEvaluationSummary {
        GroupRuleEvaluationSummary(evaluationsCount: 0)
    }
    func systemEventEngineProvenance(eventUuid: UUID) async throws -> SystemEventProvenance {
        SystemEventProvenance(found: false, reason: "no_engine_origin")
    }

    func ruleEvaluationSummary(groupId: UUID, since: Date) async throws -> GroupRuleEngineSummary {
        GroupRuleEngineSummary(
            groupId: groupId,
            since: since,
            engineActive: true,
            totalEvaluations: 0,
            matchedCount: 0,
            unmatchedCount: 0,
            emittedActionsCount: 0,
            failedActionsCount: 0
        )
    }

    func setGroupEngineActive(groupId: UUID, active: Bool) async throws -> GroupEngineToggleResult {
        GroupEngineToggleResult(groupId: groupId, engineActive: active, changed: false)
    }

    func groupRuleEngineQuota(groupId: UUID) async throws -> GroupRuleEngineQuota? {
        nil
    }

    func listDecisionTemplates() async throws -> [DecisionTemplate] { [] }

    func executeDecision(decisionId: UUID) async throws -> ExecuteDecisionResult {
        ExecuteDecisionResult(decisionId: decisionId, status: "executed")
    }

    func decisionProvenance(decisionId: UUID) async throws -> DecisionProvenance {
        DecisionProvenance(found: false, reason: "preview_stub")
    }

    func decisionSummary(groupId: UUID) async throws -> DecisionSummary {
        DecisionSummary(
            groupId: groupId, activeMembers: 0,
            open: 0, passed: 0, rejected: 0, executed: 0, cancelled: 0,
            avgTurnout: 0, participationRate: 0
        )
    }

    func applyDecisionTemplate(decisionId: UUID, templateKey: String) async throws -> ApplyDecisionTemplateResult {
        ApplyDecisionTemplateResult(decisionId: decisionId, templateKey: templateKey, executionMode: .manual)
    }

    func membershipProvenance(membershipId: UUID) async throws -> MembershipProvenance {
        MembershipProvenance(
            found: false, reason: "preview_stub",
            membershipId: nil, groupId: nil, userId: nil,
            currentState: nil, membershipType: nil, currentReason: nil,
            joinedAt: nil, confirmedAt: nil,
            pausedUntil: nil, suspendedUntil: nil, leftAt: nil, removedAt: nil, unbannedAt: nil,
            joinedVia: nil, invitedBy: nil,
            lastTransition: nil, sourceEvent: nil, sourceDecision: nil,
            sourceRuleTitle: nil, sourceConsequenceKind: nil
        )
    }

    func approveMembershipRequest(membershipId: UUID) async throws -> ApproveMembershipRequestResult {
        ApproveMembershipRequestResult(membershipId: membershipId, groupId: UUID(), status: "active", changed: true)
    }

    func listMembershipTransitions() async throws -> [MembershipStateTransition] { [] }
    func groupSanctionPaymentStatus(sanctionId: UUID) async throws -> SanctionPaymentStatus {
        SanctionPaymentStatus(
            sanctionId: sanctionId,
            amountOriginal: 0,
            amountOutstanding: 0,
            amountPaid: 0,
            obligationStatus: "no_obligation",
            sanctionStatus: "active"
        )
    }
    func proposeSanctionPaymentPlan(_ input: ProposeSanctionPaymentPlanParams) async throws -> UUID { UUID() }
    func cancelSanctionPaymentPlan(_ input: CancelSanctionPaymentPlanParams) async throws {}
    func groupSanctionPaymentPlanActive(sanctionId: UUID) async throws -> SanctionPaymentPlan {
        SanctionPaymentPlan(active: false)
    }
    func groupResourcesActive(groupId: UUID) async throws -> [GroupResource] { [] }
    func createGroupResource(_ input: CreateGroupResourceInput) async throws -> GroupResource {
        GroupResource(id: UUID(), groupId: input.pGroupId, resourceType: .other, name: input.pName)
    }
    func archiveGroupResource(_ input: ArchiveGroupResourceInput) async throws {}
    func setResourceOwnership(_ input: SetResourceOwnershipParams) async throws {}
    func groupResourceDetail(resourceId: UUID) async throws -> GroupResourceDetail {
        GroupResourceDetail(
            resource: GroupResource(id: resourceId, groupId: UUID(), resourceType: .asset, name: "")
        )
    }
    func updateResource(_ input: UpdateResourceParams) async throws {}
    func groupEventsForEntity(_ input: GroupEventsForEntityParams) async throws -> [GroupEvent] { [] }
    func assignAssetCustodian(_ input: AssignAssetCustodianParams) async throws -> UUID { UUID() }
    func releaseAssetCustodian(_ input: ReleaseAssetCustodianParams) async throws -> UUID { UUID() }
    func markAssetCondition(_ input: MarkAssetConditionParams) async throws -> UUID { UUID() }
    func recordAssetValuation(_ input: RecordAssetValuationParams) async throws {}
    func lockFund(_ input: LockFundParams) async throws -> UUID { UUID() }
    func unlockFund(_ input: UnlockFundParams) async throws -> UUID { UUID() }
    func setFundThreshold(_ input: SetFundThresholdParams) async throws -> UUID { UUID() }
    func bookResource(_ input: BookResourceParams) async throws -> UUID { UUID() }
    func cancelBooking(_ input: CancelBookingParams) async throws -> UUID { UUID() }
    func listBookingsForResource(_ input: ListBookingsForResourceParams) async throws -> [GroupResourceBooking] { [] }
    func grantRight(_ input: GrantRightParams) async throws -> UUID { UUID() }
    func transferRight(_ input: TransferRightParams) async throws -> UUID { UUID() }
    func revokeRight(_ input: RevokeRightParams) async throws -> UUID { UUID() }
    func expireRight(_ input: ExpireRightParams) async throws -> UUID { UUID() }
    func assignSlot(_ input: AssignSlotParams) async throws -> UUID { UUID() }
    func releaseSlot(_ input: ReleaseSlotParams) async throws -> UUID { UUID() }
    func expireSlot(_ input: ExpireSlotParams) async throws -> UUID { UUID() }
    func setMembershipState(_ input: SetMembershipStateParams) async throws {}
    func groupFoundationStatus(groupId: UUID) async throws -> GroupFoundationStatus {
        GroupFoundationStatus(
            groupId: groupId,
            members: .init(status: .incomplete),
            boundary: .init(status: .incomplete),
            purpose: .init(status: .incomplete),
            rules: .init(status: .incomplete),
            resources: .init(status: .incomplete),
            overallStatus: .notReady
        )
    }
    func groupDecisionRules(groupId: UUID) async throws -> GroupDecisionRules {
        GroupDecisionRules(groupId: groupId, defaultStyle: .majority, isDefault: true)
    }
    func setDecisionRules(_ input: SetDecisionRulesInput) async throws -> GroupDecisionRules {
        let method = input.pDefaultMethod.flatMap { DecisionMethod(rawValue: $0) }
            ?? DecisionMethod.forStyle(DecisionStyle(rawValue: input.pDefaultStyle) ?? .majority)
        let legitimacy = input.pDefaultLegitimacySource.flatMap { LegitimacySource(rawValue: $0) }
            ?? LegitimacySource.defaultFor(method: method)
        return GroupDecisionRules(groupId: input.pGroupId,
                                  defaultStyle: DecisionStyle(rawValue: input.pDefaultStyle) ?? method.legacyStyle,
                                  defaultMethod: method,
                                  defaultLegitimacySource: legitimacy,
                                  quorumMin: input.pQuorumMin,
                                  notes: input.pNotes,
                                  isDefault: false)
    }
    func groupGovernanceVersions(groupId: UUID, limit: Int) async throws -> [GroupGovernanceVersion] { [] }
    func memberReputationEvents(groupId: UUID, subjectMembershipId: UUID, limit: Int) async throws -> [GroupReputationEvent] { [] }
    func groupSanctionsActive(groupId: UUID, limit: Int) async throws -> [GroupSanction] { [] }
    func issueSanction(_ input: IssueSanctionInput) async throws -> UUID { UUID() }
    func groupDisputesActive(groupId: UUID, limit: Int) async throws -> [GroupDispute] { [] }
    func disputeSanction(_ input: DisputeSanctionInput) async throws -> UUID { UUID() }
    func groupEventsRecent(groupId: UUID, limit: Int, before: Date?) async throws -> [GroupEvent] { [] }
    func groupEventsForMember(groupId: UUID, membershipId: UUID, limit: Int) async throws -> [GroupEvent] { [] }
    func groupMoneyMovements(groupId: UUID, limit: Int, filter: [String]?, beforeSeq: Int64?) async throws -> [MoneyMovement] { [] }
    func groupCulturalNormsActive(groupId: UUID) async throws -> [GroupCulturalNorm] { [] }
    func proposeCulturalNorm(_ input: ProposeCulturalNormParams) async throws -> UUID { UUID() }
    func endorseCulturalNorm(normId: UUID) async throws -> Int { 1 }
    func retireCulturalNorm(_ input: RetireCulturalNormParams) async throws {}
    func promoteNormToRule(_ input: PromoteNormToRuleInput) async throws -> PromoteNormToRuleResult {
        PromoteNormToRuleResult(ruleId: UUID(), versionId: UUID(), normId: input.pNormId)
    }
    func groupMandatesActive(groupId: UUID) async throws -> [GroupMandate] { [] }
    func grantMandate(_ input: GrantMandateParams) async throws -> UUID { UUID() }
    func revokeMandate(_ input: RevokeMandateParams) async throws {}
    func groupContributionsActive(groupId: UUID, membershipId: UUID?, resourceId: UUID?) async throws -> [GroupContribution] { [] }
    func logContribution(_ input: LogContributionParams) async throws -> UUID { UUID() }
    func verifyContribution(_ input: VerifyContributionParams) async throws {}
    func groupReputationEvents(groupId: UUID, limit: Int) async throws -> [GroupReputationEvent] { [] }
    func recordReputationEvent(_ input: RecordReputationEventParams) async throws -> GroupReputationEvent {
        GroupReputationEvent(id: UUID(), groupId: input.pGroupId, subjectMembershipId: input.pSubjectMembershipId, kind: .other)
    }
    func listDecisionsActive(groupId: UUID) async throws -> [GroupDecisionSummary] { [] }
    func listDecisionsHistory(groupId: UUID, limit: Int) async throws -> [GroupDecisionSummary] { [] }
    func decisionDetail(decisionId: UUID) async throws -> GroupDecisionDetail {
        GroupDecisionDetail(id: decisionId, groupId: UUID(), title: "")
    }
    func startVote(_ input: StartVoteParams) async throws -> UUID { UUID() }
    func castVote(_ input: CastVoteParams) async throws -> UUID { UUID() }
    func castRankedVote(_ input: CastRankedVoteParams) async throws -> UUID { UUID() }
    func finalizeVote(decisionId: UUID) async throws -> String { "passed" }
    func cancelVote(_ input: CancelVoteParams) async throws {}
    func disputeDetail(disputeId: UUID) async throws -> GroupDisputeDetail {
        GroupDisputeDetail(id: disputeId, groupId: UUID(), title: "")
    }
    func listDisputeEvents(disputeId: UUID, limit: Int) async throws -> [GroupDisputeEvent] { [] }
    func openDispute(_ input: OpenDisputeInput) async throws -> UUID { UUID() }
    func appendDisputeEvent(_ input: AppendDisputeEventInput) async throws -> UUID { UUID() }
    func recordDisputeResolution(_ input: RecordDisputeResolutionInput) async throws {}
    func escalateDisputeToVote(_ input: EscalateDisputeToVoteInput) async throws -> UUID { UUID() }
    func listGroupResourceSeries(groupId: UUID, ritualsOnly: Bool, includePast: Bool) async throws -> [GroupResourceSeries] { [] }
    func createResourceSeries(_ input: CreateResourceSeriesInput) async throws -> UUID { UUID() }
    func updateResourceSeries(_ input: UpdateResourceSeriesInput) async throws {}
    func groupBoundaryPolicy(groupId: UUID) async throws -> GroupBoundaryPolicy {
        GroupBoundaryPolicy(groupId: groupId)
    }
    func setGroupBoundaryPolicy(_ input: SetGroupBoundaryPolicyInput) async throws -> GroupBoundaryPolicy {
        GroupBoundaryPolicy(groupId: input.pGroupId, isDefault: false)
    }
    func listGroupRoles(groupId: UUID) async throws -> [GroupRole] { [] }
    func listPermissionsCatalog() async throws -> [PermissionCatalogEntry] { [] }
    func createCustomRole(_ input: CreateCustomRoleInput) async throws -> UUID { UUID() }
    func updateRolePermissions(_ input: UpdateRolePermissionsInput) async throws {}
    func assignRoleToMember(_ input: AssignRoleToMemberInput) async throws {}
    func revokeRoleFromMember(_ input: RevokeRoleFromMemberInput) async throws {}
    func groupDissolutionActive(groupId: UUID) async throws -> GroupDissolution? { nil }
    func proposeDissolution(_ input: ProposeDissolutionInput) async throws -> UUID { UUID() }
    func finalizeDissolution(_ input: FinalizeDissolutionInput) async throws {}
    func myNotificationPreferences(groupId: UUID) async throws -> [NotificationPreferenceRow] { [] }
    func setNotificationPreference(_ input: SetNotificationPreferenceInput) async throws {}
    func registerMyNotificationToken(_ input: RegisterMyNotificationTokenInput) async throws -> UUID { UUID() }
    func groupVisibility(groupId: UUID) async throws -> String { "private" }
    func setGroupVisibility(_ input: SetGroupVisibilityInput) async throws -> String { input.pVisibility }
    func listMyInbox(_ input: ListMyInboxParams) async throws -> [InboxItem] { [] }
    func markInboxRead(_ input: MarkInboxReadParams) async throws {}
    func markAllInboxRead(_ input: MarkAllInboxReadParams) async throws -> Int { 0 }
    func myInboxUnreadCount(_ input: MyInboxUnreadCountParams) async throws -> Int { 0 }
    func globalSearch(_ input: GlobalSearchParams) async throws -> [SearchResult] { [] }
    func requestMembership(_ input: RequestMembershipParams) async throws -> UUID { UUID() }
    func requestOrExecuteAction(_ input: RequestOrExecuteActionParams) async throws -> ActionOutcome {
        .unsupported(reason: "preview_mock", actionKey: input.pActionKey)
    }
}
