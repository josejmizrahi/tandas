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
    func inviteMember(groupId: UUID, email: String?, phone: String?, membershipType: String, message: String?) async throws -> UUID { UUID() }
    func acceptInvite(code: String) async throws -> AcceptInviteResult { .init(groupId: UUID(), membershipId: UUID()) }
    func leaveGroup(groupId: UUID, reason: String?) async throws {}
    func recordExpense(_ draft: ExpenseDraft, clientId: String?) async throws -> UUID { UUID() }
    func recordSettlement(_ draft: SettlementDraft, clientId: String?) async throws -> SettlementResult {
        .init(settlementId: UUID(), transactionId: UUID())
    }
    func listMyGroups() async throws -> [GroupListItem] { [] }
    func groupSummary(groupId: UUID) async throws -> CanonicalGroupSummary {
        .init(groupId: groupId, memberCount: 0, openDecisions: 0, openDisputes: 0, openObligations: 0, recentEvents: [])
    }
    func memberBalance(groupId: UUID, membershipId: UUID) async throws -> Decimal { 0 }
    func memberObligationSummary(groupId: UUID, membershipId: UUID) async throws -> [ObligationSummary] { [] }
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
    func groupResourcesActive(groupId: UUID) async throws -> [GroupResource] { [] }
    func createGroupResource(_ input: CreateGroupResourceInput) async throws -> GroupResource {
        GroupResource(id: UUID(), groupId: input.pGroupId, resourceType: .other, name: input.pName)
    }
    func archiveGroupResource(_ input: ArchiveGroupResourceInput) async throws {}
    func setResourceOwnership(_ input: SetResourceOwnershipParams) async throws {}
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
    func memberReputationEvents(groupId: UUID, subjectMembershipId: UUID, limit: Int) async throws -> [GroupReputationEvent] { [] }
    func groupSanctionsActive(groupId: UUID, limit: Int) async throws -> [GroupSanction] { [] }
    func issueSanction(_ input: IssueSanctionInput) async throws -> UUID { UUID() }
    func groupDisputesActive(groupId: UUID, limit: Int) async throws -> [GroupDispute] { [] }
    func disputeSanction(_ input: DisputeSanctionInput) async throws -> UUID { UUID() }
    func groupEventsRecent(groupId: UUID, limit: Int, before: Date?) async throws -> [GroupEvent] { [] }
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
}
