import SwiftUI
import RuulCore

/// Settings.app-style root for a single group. Pure surface for the
/// B1 slice — most rows route to existing edit sheets (Propósito,
/// Decisiones del grupo) or push into already-built list/edit views
/// (Reglas, Política de sanciones via SanctionsListView). Rows whose
/// backend isn't ready yet surface a neutral "Próximamente" alert
/// instead of dead-ending. The destructive "Salir del grupo" is the
/// only real action this view owns directly.
///
/// Pushed from `GroupHomeView`'s "Más" menu. The shell (D3) will
/// later host it under the tab "Ajustes" of the per-group tab bar.
public struct GroupSettingsView: View {
    let container: DependencyContainer
    let group: GroupListItem

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingLeave: Bool = false
    @State private var leaveError: UserFacingError?
    @State private var comingSoon: ComingSoonRow?

    public init(container: DependencyContainer, group: GroupListItem) {
        self.container = container
        self.group = group
    }

    public var body: some View {
        List {
            foundationSection
            belongingSection
            organizationSection
            moneyResourcesSection
            notificationsSection
            privacySection
            dangerSection
        }
        .navigationTitle(L10n.GroupSettings.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: GroupSettingsDestination.self) { destination in
            switch destination {
            case .rules:
                RulesListView(store: container.rulesStore, groupId: group.id)
            case .sanctionsPolicy:
                SanctionsListView(
                    container: container,
                    store: container.sanctionsStore,
                    membersStore: container.membersStore,
                    groupId: group.id,
                    myMembershipId: group.membershipId,
                    onDispute: { sanctionId in
                        container.disputesStore.beginDisputingSanction(sanctionId)
                    }
                )
            case .culture:
                CulturalNormsListView(store: container.culturalNormsStore, groupId: group.id)
            case .mandates:
                MandatesListView(
                    store: container.mandatesStore,
                    membersStore: container.membersStore,
                    groupId: group.id
                )
            case .boundaryPolicy:
                BoundaryPolicyView(store: container.boundaryPolicyStore, groupId: group.id)
            case .rituals:
                RitualsListView(store: container.ritualsStore, groupId: group.id)
            case .roles:
                RolesListView(store: container.rolesStore, groupId: group.id)
            case .dissolution:
                DissolutionStatusView(store: container.dissolutionStore, groupId: group.id)
            case .notifications:
                NotificationSettingsView(store: container.notificationSettingsStore, groupId: group.id)
            case .privacy:
                GroupPrivacyView(store: container.privacyStore, groupId: group.id)
            }
        }
        .sheet(isPresented: purposeSheetBinding) {
            EditPurposeView(store: container.purposeStore, groupId: group.id)
        }
        .sheet(isPresented: decisionRulesSheetBinding) {
            EditDecisionRulesView(store: container.decisionRulesStore, groupId: group.id)
        }
        .alert(
            Text(L10n.GroupSettings.comingSoonTitle),
            isPresented: comingSoonBinding
        ) {
            Button(String(localized: L10n.GroupSettings.close)) {
                comingSoon = nil
            }
        } message: {
            Text(L10n.GroupSettings.comingSoonBody)
        }
        .alert(
            Text(L10n.GroupSettings.leaveConfirmTitle),
            isPresented: $isConfirmingLeave
        ) {
            Button(role: .cancel) {} label: { Text(L10n.GroupSettings.cancel) }
            Button(role: .destructive) {
                Task { await leave() }
            } label: {
                Text(L10n.GroupSettings.leaveAction)
            }
        } message: {
            Text(L10n.GroupSettings.leaveConfirmMessage)
        }
        .alert(
            leaveError?.title ?? "",
            isPresented: Binding(
                get: { leaveError != nil },
                set: { if !$0 { leaveError = nil } }
            ),
            actions: { Button("OK") { leaveError = nil } },
            message: { Text(leaveError?.message ?? "") }
        )
        .task {
            await container.foundationStatusStore.refreshIfNeeded(groupId: group.id)
            await container.purposeStore.refreshIfNeeded(groupId: group.id)
            await container.rulesStore.refreshIfNeeded(groupId: group.id)
            await container.decisionRulesStore.refreshIfNeeded(groupId: group.id)
            await container.sanctionsStore.refreshIfNeeded(groupId: group.id)
            await container.culturalNormsStore.refreshIfNeeded(groupId: group.id)
            await container.mandatesStore.refreshIfNeeded(groupId: group.id)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var foundationSection: some View {
        Section(L10n.GroupSettings.foundationSection) {
            HStack(spacing: 12) {
                Image(systemName: foundationIcon)
                    .foregroundStyle(foundationTint)
                    .frame(width: 24)
                Text(foundationHint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private var foundationHint: LocalizedStringResource {
        switch container.foundationStatusStore.phase {
        case .idle, .loading:
            return L10n.GroupSettings.foundationLoading
        case .failed:
            return L10n.GroupSettings.foundationPendingHint
        case .loaded:
            let isReady = container.foundationStatusStore.status?.isReady == true
            return isReady ? L10n.GroupSettings.foundationReadyHint : L10n.GroupSettings.foundationPendingHint
        }
    }

    private var foundationIcon: String {
        let isReady = container.foundationStatusStore.status?.isReady == true
        return isReady ? "checkmark.seal" : "exclamationmark.triangle"
    }

    private var foundationTint: Color {
        let isReady = container.foundationStatusStore.status?.isReady == true
        return isReady ? .green : .orange
    }

    @ViewBuilder
    private var belongingSection: some View {
        Section(L10n.GroupSettings.belongingSection) {
            NavigationLink(value: GroupSettingsDestination.boundaryPolicy) {
                Label(L10n.GroupSettings.boundaryPolicyRow, systemImage: "door.left.hand.closed")
            }
            comingSoonRow(.membershipTypes, label: L10n.GroupSettings.membershipTypesRow, systemImage: "person.crop.rectangle.stack")
            NavigationLink(value: GroupSettingsDestination.roles) {
                Label {
                    Text(L10n.GroupSettings.rolesRow)
                } icon: {
                    Image(systemName: "person.crop.rectangle.badge.checkmark")
                }
            }
            NavigationLink(value: GroupSettingsDestination.mandates) {
                Label(L10n.GroupSettings.mandatesRow, systemImage: "signature")
            }
        }
    }

    @ViewBuilder
    private var organizationSection: some View {
        Section(L10n.GroupSettings.organizationSection) {
            Button {
                container.purposeStore.beginEditing(kind: .declared)
            } label: {
                row(label: L10n.GroupSettings.purposeRow, systemImage: "flag")
            }
            NavigationLink(value: GroupSettingsDestination.rules) {
                Label(L10n.GroupSettings.rulesRow, systemImage: "list.bullet.rectangle")
            }
            Button {
                container.decisionRulesStore.beginEditing()
            } label: {
                row(label: L10n.GroupSettings.decisionRulesRow, systemImage: "person.3.sequence")
            }
            NavigationLink(value: GroupSettingsDestination.culture) {
                Label(L10n.GroupSettings.cultureRow, systemImage: "heart")
            }
            NavigationLink(value: GroupSettingsDestination.rituals) {
                Label(L10n.GroupSettings.ritualsRow, systemImage: "sparkles")
            }
        }
    }

    @ViewBuilder
    private var moneyResourcesSection: some View {
        Section(L10n.GroupSettings.moneyResourcesSection) {
            comingSoonRow(.currency, label: L10n.GroupSettings.currencyRow, systemImage: "dollarsign.circle")
            comingSoonRow(.fundsPolicy, label: L10n.GroupSettings.fundsPolicyRow, systemImage: "banknote")
            NavigationLink(value: GroupSettingsDestination.sanctionsPolicy) {
                Label(L10n.GroupSettings.sanctionsPolicyRow, systemImage: "exclamationmark.shield")
            }
        }
    }

    @ViewBuilder
    private var notificationsSection: some View {
        Section(L10n.GroupSettings.notificationsSection) {
            NavigationLink(value: GroupSettingsDestination.notifications) {
                Label {
                    Text(L10n.GroupSettings.notificationsRow)
                } icon: {
                    Image(systemName: "bell")
                }
            }
        }
    }

    @ViewBuilder
    private var privacySection: some View {
        Section(L10n.GroupSettings.privacySection) {
            NavigationLink(value: GroupSettingsDestination.privacy) {
                Label {
                    Text(L10n.GroupSettings.privacyRow)
                } icon: {
                    Image(systemName: "lock")
                }
            }
        }
    }

    @ViewBuilder
    private var dangerSection: some View {
        Section(L10n.GroupSettings.dangerSection) {
            Button(role: .destructive) {
                isConfirmingLeave = true
            } label: {
                Label(L10n.GroupSettings.leaveRow, systemImage: "rectangle.portrait.and.arrow.right")
            }
            NavigationLink(value: GroupSettingsDestination.dissolution) {
                Label(L10n.GroupSettings.dissolveRow, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func row(label: LocalizedStringResource, systemImage: String) -> some View {
        HStack {
            Label(label, systemImage: systemImage)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func comingSoonRow(
        _ which: ComingSoonRow,
        label: LocalizedStringResource,
        systemImage: String
    ) -> some View {
        Button {
            comingSoon = which
        } label: {
            row(label: label, systemImage: systemImage)
        }
    }

    // MARK: - Bindings

    private var purposeSheetBinding: Binding<Bool> {
        Binding(
            get: { container.purposeStore.isEditPresented },
            set: { container.purposeStore.isEditPresented = $0 }
        )
    }

    private var decisionRulesSheetBinding: Binding<Bool> {
        Binding(
            get: { container.decisionRulesStore.isEditPresented },
            set: { container.decisionRulesStore.isEditPresented = $0 }
        )
    }

    private var comingSoonBinding: Binding<Bool> {
        Binding(
            get: { comingSoon != nil },
            set: { if !$0 { comingSoon = nil } }
        )
    }

    // MARK: - Actions

    private func leave() async {
        do {
            try await container.groupRepository.leaveGroup(groupId: group.id, reason: nil)
            container.moneyStore.clear()
            await container.currentGroupStore.setGroup(nil)
            await container.groupsStore.refresh()
            dismiss()
        } catch {
            self.leaveError = UserFacingError.from(error)
        }
    }

    // MARK: - Destinations

    private enum GroupSettingsDestination: Hashable {
        case rules
        case sanctionsPolicy
        case culture
        case mandates
        case boundaryPolicy
        case rituals
        case roles
        case dissolution
        case notifications
        case privacy
    }

    private enum ComingSoonRow: Hashable {
        case membershipTypes
        case currency
        case fundsPolicy
    }
}
