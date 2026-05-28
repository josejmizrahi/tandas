import SwiftUI
import RuulCore

/// Compact "Reglas" card mounted in `GroupHomeView`. Shows top 3
/// rules + a count and a navigation row into `RulesListView`.
public struct GroupRulesCard: View {
    @Bindable var store: RulesStore
    let onAdd: () -> Void

    public init(store: RulesStore, onAdd: @escaping () -> Void) {
        self.store = store
        self.onAdd = onAdd
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.hasRules {
                ForEach(store.topRules) { rule in
                    RuleRowView(rule: rule, compact: true)
                    if rule.id != store.topRules.last?.id {
                        Divider().padding(.leading, 36)
                    }
                }
            } else {
                Button(action: onAdd) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.tint)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.Rules.emptyTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(L10n.Rules.emptyDescription)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "plus.circle")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    public var countLabel: String {
        let n = store.rules.count
        return n == 1 ? String(localized: L10n.Rules.countSingular) : "\(n) reglas activas"
    }
}

#Preview("Populated") {
    let mock = makePreviewStore(seed: RulesPreviewData.all)
    return List {
        Section(L10n.Rules.title) {
            GroupRulesCard(store: mock, onAdd: {})
        }
    }
}

#Preview("Empty") {
    let mock = makePreviewStore(seed: [])
    return List {
        Section(L10n.Rules.title) {
            GroupRulesCard(store: mock, onAdd: {})
        }
    }
}

@MainActor
private func makePreviewStore(seed: [GroupRule]) -> RulesStore {
    let client = RulesStubClient(seed: seed)
    let repo = CanonicalRulesRepository(rpc: client)
    let store = RulesStore(repository: repo)
    Task { await store.refresh(groupId: UUID()) }
    return store
}

private struct RulesStubClient: RuulRPCClient, @unchecked Sendable {
    let seed: [GroupRule]
    func groupRulesActive(groupId: UUID) async throws -> [GroupRule] { seed }
    func createTextRule(_ input: CreateTextRuleInput) async throws -> CreateTextRuleResult {
        CreateTextRuleResult(ruleId: UUID(), versionId: UUID())
    }
    func archiveRule(_ input: ArchiveRuleInput) async throws {}

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
    func groupResourcesActive(groupId: UUID) async throws -> [GroupResource] { [] }
    func createGroupResource(_ input: CreateGroupResourceInput) async throws -> GroupResource {
        GroupResource(id: UUID(), groupId: input.pGroupId, resourceType: .other, name: input.pName)
    }
    func archiveGroupResource(_ input: ArchiveGroupResourceInput) async throws {}
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
        GroupDecisionRules(groupId: input.pGroupId,
                           defaultStyle: DecisionStyle(rawValue: input.pDefaultStyle) ?? .majority,
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
    func groupMandatesActive(groupId: UUID) async throws -> [GroupMandate] { [] }
    func grantMandate(_ input: GrantMandateParams) async throws -> UUID { UUID() }
    func revokeMandate(_ input: RevokeMandateParams) async throws {}
    func groupContributionsActive(groupId: UUID, membershipId: UUID?, resourceId: UUID?) async throws -> [GroupContribution] { [] }
    func logContribution(_ input: LogContributionParams) async throws -> UUID { UUID() }
    func groupReputationEvents(groupId: UUID, limit: Int) async throws -> [GroupReputationEvent] { [] }
    func recordReputationEvent(_ input: RecordReputationEventParams) async throws -> GroupReputationEvent {
        GroupReputationEvent(id: UUID(), groupId: input.pGroupId, subjectMembershipId: input.pSubjectMembershipId, kind: .other)
    }
    func myProfile() async throws -> Profile { Profile(id: UUID()) }
    func updateMyProfile(_ input: UpdateMyProfileInput) async throws -> Profile { Profile(id: UUID()) }
    func listDecisionsActive(groupId: UUID) async throws -> [GroupDecisionSummary] { [] }
    func listDecisionsHistory(groupId: UUID, limit: Int) async throws -> [GroupDecisionSummary] { [] }
    func decisionDetail(decisionId: UUID) async throws -> GroupDecisionDetail {
        GroupDecisionDetail(id: decisionId, groupId: UUID(), title: "")
    }
    func startVote(_ input: StartVoteParams) async throws -> UUID { UUID() }
    func castVote(_ input: CastVoteParams) async throws -> UUID { UUID() }
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
}
