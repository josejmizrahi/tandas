import SwiftUI
import RuulCore

/// Compact "Reglas" card mounted in `GroupHomeView`. Shows top 3
/// rules + a count and a navigation row into `RulesListView`.
public struct GroupRulesCard: View {
    @Bindable var store: RulesStore
    let onTapMore: () -> Void
    let onAdd: () -> Void

    public init(store: RulesStore,
                onTapMore: @escaping () -> Void,
                onAdd: @escaping () -> Void) {
        self.store = store
        self.onTapMore = onTapMore
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
                Divider().padding(.leading, 36)
                Button(action: onTapMore) {
                    HStack {
                        Text(rulesCountLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

    private var rulesCountLabel: String {
        let n = store.rules.count
        return n == 1 ? String(localized: L10n.Rules.countSingular) : "\(n) reglas activas"
    }
}

#Preview("Populated") {
    let mock = makePreviewStore(seed: RulesPreviewData.all)
    return List {
        Section(L10n.Rules.title) {
            GroupRulesCard(store: mock, onTapMore: {}, onAdd: {})
        }
    }
}

#Preview("Empty") {
    let mock = makePreviewStore(seed: [])
    return List {
        Section(L10n.Rules.title) {
            GroupRulesCard(store: mock, onTapMore: {}, onAdd: {})
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
    func myProfile() async throws -> Profile { Profile(id: UUID()) }
    func updateMyProfile(_ input: UpdateMyProfileInput) async throws -> Profile { Profile(id: UUID()) }
}
