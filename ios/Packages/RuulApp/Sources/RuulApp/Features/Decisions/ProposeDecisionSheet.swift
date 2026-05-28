import SwiftUI
import RuulCore

/// Sheet for opening a new decision (start_vote). Title + body +
/// method + type + optional explicit options. Leaving options empty
/// surfaces a Sí / No / Abstención hint — the backend will default to
/// no-option voting (vote_value yes/no/abstain/block).
public struct ProposeDecisionSheet: View {
    @Bindable var store: DecisionsStore
    let groupId: UUID
    /// V2-G2 sub-slice 3 — optional stores that the reference picker
    /// uses to populate its options for `sanction_appeal` /
    /// `mandate_revoke`. Optional so previews and call sites that
    /// don't need entity references can omit them.
    let sanctionsStore: SanctionsStore?
    let mandatesStore: MandatesStore?
    let membersStore: MembersStore?
    let rulesStore: RulesStore?

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false

    public init(
        store: DecisionsStore,
        groupId: UUID,
        sanctionsStore: SanctionsStore? = nil,
        mandatesStore: MandatesStore? = nil,
        membersStore: MembersStore? = nil,
        rulesStore: RulesStore? = nil
    ) {
        self.store = store
        self.groupId = groupId
        self.sanctionsStore = sanctionsStore
        self.mandatesStore = mandatesStore
        self.membersStore = membersStore
        self.rulesStore = rulesStore
    }

    public var body: some View {
        NavigationStack {
            Form {
                titleSection
                bodySection
                methodSection
                legitimacySection
                typeSection
                referencePickerSection
                optionsSection
                if let message = store.draftErrorMessage, !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.Decisions.proposeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: store.draftType) {
                // Lazy-refresh the relevant entity list when the type
                // changes so the picker has fresh rows. Avoids forcing
                // the caller to pre-load both stores upfront.
                switch store.draftType {
                case .sanctionAppeal:
                    await sanctionsStore?.refreshIfNeeded(groupId: groupId)
                case .mandateGrant, .mandateRevoke:
                    await mandatesStore?.refreshIfNeeded(groupId: groupId)
                case .membership:
                    await membersStore?.refreshIfNeeded(groupId: groupId)
                case .ruleChange:
                    await rulesStore?.refreshIfNeeded(groupId: groupId)
                default:
                    break
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.Decisions.proposeCancel)) {
                        store.isProposePresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: L10n.Decisions.proposeButton)) {
                        save()
                    }
                    .disabled(!store.canSaveDraftDecision || isSaving)
                }
            }
        }
    }

    @ViewBuilder
    private var titleSection: some View {
        Section(L10n.Decisions.proposeTitleLabel) {
            TextField(String(localized: L10n.Decisions.proposeTitlePlaceholder), text: $store.draftTitle, axis: .vertical)
                .lineLimit(2...4)
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        Section(L10n.Decisions.proposeBodyLabel) {
            TextField(
                String(localized: L10n.Decisions.proposeBodyPlaceholder),
                text: $store.draftBody,
                axis: .vertical
            )
            .lineLimit(3...8)
        }
    }

    @ViewBuilder
    private var methodSection: some View {
        Section(L10n.Decisions.proposeMethodSection) {
            ForEach(DecisionMethod.selectable) { method in
                Button {
                    store.draftMethod = method
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(method.label, systemImage: method.systemImageName)
                                .font(.body)
                            Text(method.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.draftMethod == method {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var legitimacySection: some View {
        Section {
            Picker(selection: $store.draftLegitimacySource) {
                ForEach(LegitimacySource.selectable) { source in
                    Label(source.label, systemImage: source.systemImageName)
                        .tag(source)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Text(store.draftLegitimacySource.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(L10n.Decisions.legitimacySection)
        }
    }

    @ViewBuilder
    private var typeSection: some View {
        Section {
            Picker(String(localized: L10n.Decisions.typeLabel), selection: $store.draftType) {
                ForEach(DecisionType.Group.allCases) { group in
                    let typesInGroup = DecisionType.selectable.filter { $0.group == group }
                    if !typesInGroup.isEmpty {
                        Section {
                            ForEach(typesInGroup) { type in
                                Label(type.label, systemImage: type.systemImageName)
                                    .tag(type)
                            }
                        } header: {
                            Text(group.label)
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            Text(store.draftType.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(L10n.Decisions.proposeTypeSection)
        }
    }

    /// V2-G2 sub-slice 3 — only rendered when the type binds to a
    /// specific entity. For `sanction_appeal` lists active sanctions
    /// from `SanctionsStore`; for `mandate_grant` / `mandate_revoke`
    /// lists active mandates from `MandatesStore`. Other reference
    /// kinds (`dissolution`) fall back to an informative hint until a
    /// later sub-slice ships the entity-specific picker.
    @ViewBuilder
    private var referencePickerSection: some View {
        switch store.draftType {
        case .sanctionAppeal:
            sanctionsReferenceSection
        case .mandateGrant, .mandateRevoke:
            mandatesReferenceSection
        case .membership:
            membershipReferenceSection
            membershipTargetStateSection
        case .ruleChange:
            ruleReferenceSection
            ruleChangeActionSection
        case .dissolution:
            unsupportedReferenceHint
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var sanctionsReferenceSection: some View {
        Section {
            let rows = sanctionsStore?.sanctions ?? []
            if rows.isEmpty {
                Text(L10n.Decisions.proposeReferenceSanctionEmpty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker(selection: $store.draftReferenceId) {
                    Text(String(localized: L10n.Decisions.voteOptionNoneRow)).tag(UUID?.none)
                    ForEach(rows) { sanction in
                        Label(sanction.reason, systemImage: "exclamationmark.shield")
                            .tag(UUID?.some(sanction.id))
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        } header: {
            Text(L10n.Decisions.proposeReferenceSanctionSection)
        }
    }

    @ViewBuilder
    private var mandatesReferenceSection: some View {
        Section {
            let rows = mandatesStore?.mandates ?? []
            if rows.isEmpty {
                Text(L10n.Decisions.proposeReferenceMandateEmpty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker(selection: $store.draftReferenceId) {
                    Text(String(localized: L10n.Decisions.voteOptionNoneRow)).tag(UUID?.none)
                    ForEach(rows) { mandate in
                        mandateRow(for: mandate)
                            .tag(UUID?.some(mandate.id))
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        } header: {
            Text(L10n.Decisions.proposeReferenceMandateSection)
        }
    }

    @ViewBuilder
    private func mandateRow(for mandate: GroupMandate) -> some View {
        let principal = String(localized: mandate.principalType.label)
        let type = String(localized: mandate.type.label)
        Label("\(principal) · \(type)", systemImage: mandate.type.systemImageName)
    }

    @ViewBuilder
    private var membershipReferenceSection: some View {
        Section {
            let rows = membersStore?.items.filter {
                $0.kind == .membership && $0.membershipId != nil
            } ?? []
            if rows.isEmpty {
                Text(L10n.Decisions.proposeReferenceMembershipEmpty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker(selection: $store.draftReferenceId) {
                    Text(String(localized: L10n.Decisions.voteOptionNoneRow)).tag(UUID?.none)
                    ForEach(rows, id: \.id) { item in
                        Label(item.displayName, systemImage: "person.crop.circle")
                            .tag(UUID?.some(item.membershipId!))
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        } header: {
            Text(L10n.Decisions.proposeReferenceMembershipSection)
        }
    }

    @ViewBuilder
    private var membershipTargetStateSection: some View {
        Section {
            Picker(selection: $store.draftMembershipTargetState) {
                Text(String(localized: L10n.Decisions.voteOptionNoneRow))
                    .tag(MembershipDecisionTargetState?.none)
                ForEach(MembershipDecisionTargetState.displayOrder) { state in
                    Label(state.label, systemImage: state.systemImageName)
                        .tag(MembershipDecisionTargetState?.some(state))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Text(L10n.Decisions.proposeMembershipTargetStateHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(L10n.Decisions.proposeMembershipTargetStateSection)
        }
    }

    @ViewBuilder
    private var ruleReferenceSection: some View {
        Section {
            let rows = rulesStore?.rules ?? []
            if rows.isEmpty {
                Text(L10n.Decisions.proposeReferenceRuleEmpty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker(selection: $store.draftReferenceId) {
                    Text(String(localized: L10n.Decisions.voteOptionNoneRow)).tag(UUID?.none)
                    ForEach(rows) { rule in
                        Label(rule.title, systemImage: rule.ruleType.systemImageName)
                            .tag(UUID?.some(rule.id))
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        } header: {
            Text(L10n.Decisions.proposeReferenceRuleSection)
        }
    }

    @ViewBuilder
    private var ruleChangeActionSection: some View {
        Section {
            Picker(selection: $store.draftRuleChangeAction) {
                Text(String(localized: L10n.Decisions.voteOptionNoneRow))
                    .tag(RuleChangeAction?.none)
                ForEach(RuleChangeAction.displayOrder) { action in
                    Label(action.label, systemImage: action.systemImageName)
                        .tag(RuleChangeAction?.some(action))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Text(L10n.Decisions.proposeRuleChangeActionHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(L10n.Decisions.proposeRuleChangeActionSection)
        }
    }

    @ViewBuilder
    private var unsupportedReferenceHint: some View {
        Section {
            Text(L10n.Decisions.proposeReferenceUnsupportedHint)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        Section {
            ForEach($store.draftOptions) { $option in
                TextField(String(localized: L10n.Decisions.proposeOptionPlaceholder), text: $option.label)
            }
            .onDelete { offsets in
                store.removeDraftOption(at: offsets)
            }
            Button {
                store.addDraftOption()
            } label: {
                Label(L10n.Decisions.proposeAddOption, systemImage: "plus")
            }
        } header: {
            Text(L10n.Decisions.proposeOptionsSection)
        } footer: {
            Text(L10n.Decisions.proposeOptionsHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            _ = await store.saveDraftDecision(groupId: groupId)
            isSaving = false
        }
    }
}
