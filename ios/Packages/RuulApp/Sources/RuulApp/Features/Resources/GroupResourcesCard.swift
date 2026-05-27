import SwiftUI
import RuulCore

/// Compact "Recursos" card mounted in `GroupHomeView`. Shows top 3
/// rows or an empty-state add prompt. The NavigationLink into
/// `ResourcesListView` lives in GroupHomeView (same pattern as
/// rules/members).
public struct GroupResourcesCard: View {
    @Bindable var store: ResourcesStore
    let onAdd: () -> Void

    public init(store: ResourcesStore, onAdd: @escaping () -> Void) {
        self.store = store
        self.onAdd = onAdd
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.hasResources {
                ForEach(store.topResources) { resource in
                    ResourceRowView(resource: resource, compact: true)
                    if resource.id != store.topResources.last?.id {
                        Divider().padding(.leading, 36)
                    }
                }
            } else {
                Button(action: onAdd) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.tint)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.Resources.emptyTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(L10n.Resources.emptyDescription)
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
}

#Preview("Populated") {
    let mock = makePreviewStore(seed: ResourcesPreviewData.all)
    return List {
        Section(L10n.Resources.title) {
            GroupResourcesCard(store: mock, onAdd: {})
        }
    }
}

#Preview("Empty") {
    let mock = makePreviewStore(seed: [])
    return List {
        Section(L10n.Resources.title) {
            GroupResourcesCard(store: mock, onAdd: {})
        }
    }
}

@MainActor
private func makePreviewStore(seed: [GroupResource]) -> ResourcesStore {
    let client = ResourcesStubClient(seed: seed)
    let repo = CanonicalResourcesRepository(rpc: client)
    let store = ResourcesStore(repository: repo)
    Task { await store.refresh(groupId: UUID()) }
    return store
}

private struct ResourcesStubClient: RuulRPCClient, @unchecked Sendable {
    let seed: [GroupResource]
    func groupResourcesActive(groupId: UUID) async throws -> [GroupResource] { seed }
    func createGroupResource(_ input: CreateGroupResourceInput) async throws -> GroupResource {
        GroupResource(id: UUID(), groupId: input.pGroupId, resourceType: .other, name: input.pName)
    }
    func archiveGroupResource(_ input: ArchiveGroupResourceInput) async throws {}

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
    func myProfile() async throws -> Profile { Profile(id: UUID()) }
    func updateMyProfile(_ input: UpdateMyProfileInput) async throws -> Profile { Profile(id: UUID()) }
}
