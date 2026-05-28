import SwiftUI
import RuulCore

/// Compact "Propósito" card for `GroupHomeView`. Renders one row per
/// existing kind (declared/operative/emotional) plus a tap-to-add
/// affordance for missing kinds. All taps open
/// `EditPurposeView` via `store.beginEditing(kind:)`.
public struct GroupPurposeCard: View {
    @Bindable var store: PurposeStore

    public init(store: PurposeStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(GroupPurposeKind.displayOrder, id: \.self) { kind in
                row(for: kind)
                if kind != GroupPurposeKind.displayOrder.last {
                    Divider().padding(.leading, 36)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for kind: GroupPurposeKind) -> some View {
        Button {
            store.beginEditing(kind: kind)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind.systemImageName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let purpose = store.purpose(for: kind), !purpose.trimmedBody.isEmpty {
                        Text(purpose.trimmedBody)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                    } else {
                        Text(kind.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: store.purpose(for: kind) == nil ? "plus.circle" : "chevron.right")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(store.purpose(for: kind) == nil ? "Agregar" : "Editar"))
    }
}

#Preview("Empty") {
    let mock = makePreviewStore(seed: [])
    return List {
        Section { GroupPurposeCard(store: mock) }
    }
}

#Preview("Declared only") {
    let mock = makePreviewStore(seed: [
        GroupPurpose(id: UUID(), groupId: UUID(), kind: .declared, body: "Jugar poker los viernes en casa de Jose.")
    ])
    return List {
        Section { GroupPurposeCard(store: mock) }
    }
}

#Preview("All three kinds") {
    let mock = makePreviewStore(seed: [
        GroupPurpose(id: UUID(), groupId: UUID(), kind: .declared,  body: "Jugar poker los viernes."),
        GroupPurpose(id: UUID(), groupId: UUID(), kind: .operative, body: "Cada quien aporta $500 al fondo; el ganador se lleva el bote."),
        GroupPurpose(id: UUID(), groupId: UUID(), kind: .emotional, body: "Que nos sintamos como hermanos.")
    ])
    return List {
        Section { GroupPurposeCard(store: mock) }
    }
}

@MainActor
private func makePreviewStore(seed: [GroupPurpose]) -> PurposeStore {
    let client = PurposeStubClient(seed: seed)
    let repo = CanonicalPurposeRepository(rpc: client)
    let store = PurposeStore(repository: repo)
    Task { await store.refresh(groupId: UUID()) }
    return store
}

/// Tiny in-memory client used only by the previews above so they
/// render without touching Supabase.
private struct PurposeStubClient: RuulRPCClient, @unchecked Sendable {
    let seed: [GroupPurpose]

    func groupPurposesActive(groupId: UUID) async throws -> [GroupPurpose] { seed }
    func setGroupPurpose(_ input: SetGroupPurposeInput) async throws -> GroupPurpose {
        GroupPurpose(id: UUID(), groupId: input.pGroupId,
                     kind: GroupPurposeKind(rawValue: input.pKind) ?? .declared,
                     body: input.pBody)
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
    func groupDissolutionActive(groupId: UUID) async throws -> GroupDissolution? { nil }
    func proposeDissolution(_ input: ProposeDissolutionInput) async throws -> UUID { UUID() }
    func finalizeDissolution(_ input: FinalizeDissolutionInput) async throws {}
    func myNotificationPreferences(groupId: UUID) async throws -> [NotificationPreferenceRow] { [] }
    func setNotificationPreference(_ input: SetNotificationPreferenceInput) async throws {}
    func groupVisibility(groupId: UUID) async throws -> String { "private" }
    func setGroupVisibility(_ input: SetGroupVisibilityInput) async throws -> String { input.pVisibility }
}
