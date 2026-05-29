import SwiftUI
import RuulCore

/// Canonical hub for the per-group "El grupo" tab (D3). Settings.app-
/// style list organised by human verb, not by ontology. Every primitive
/// that doesn't naturally live in Inicio / Dinero / Personas has its
/// home here, so the 22 V1 primitives all have a single, findable
/// entry point.
///
/// Section order (locked):
///
/// 1. Identidad         — quiénes somos y qué queremos
/// 2. Recursos          — qué tenemos
/// 3. En proceso        — qué está pasando (governance live)
/// 4. Vida del grupo    — qué ya pasó / se repite
/// 5. Estructura        — cómo nos organizamos (roles + mandatos)
/// 6. Configuración     — settings técnicos + zona destructiva
///
/// Foundation readiness card stays pinned to the top as long as the
/// group isn't ready; once it is, the card collapses entirely.
public struct GroupSettingsView: View {
    let container: DependencyContainer
    let group: GroupListItem

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingLeave: Bool = false
    @State private var leaveError: UserFacingError?

    public init(container: DependencyContainer, group: GroupListItem) {
        self.container = container
        self.group = group
    }

    public var body: some View {
        List {
            foundationSection
            identitySection
            resourcesSection
            inProgressSection
            lifeSection
            structureSection
            configSection
        }
        .navigationTitle(L10n.GroupTabs.group)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: GroupSettingsDestination.self) { destination in
            destinationView(for: destination)
        }
        .sheet(isPresented: purposeSheetBinding) {
            EditPurposeView(store: container.purposeStore, groupId: group.id)
        }
        .sheet(isPresented: decisionRulesSheetBinding) {
            EditDecisionRulesView(store: container.decisionRulesStore, groupId: group.id)
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
            await container.resourcesStore.refreshIfNeeded(groupId: group.id)
        }
    }

    // MARK: - Foundation card (pinned top while not ready)

    @ViewBuilder
    private var foundationSection: some View {
        if let status = container.foundationStatusStore.status, status.isReady {
            EmptyView()
        } else {
            Section(L10n.GroupSettings.foundationSection) {
                FoundationStatusCard(
                    store: container.foundationStatusStore,
                    onSelect: handleFoundationTap
                )
            }
        }
    }

    // MARK: - 1. Identidad

    @ViewBuilder
    private var identitySection: some View {
        Section("Identidad") {
            Button {
                container.purposeStore.beginEditing(kind: .declared)
            } label: {
                row(label: "Propósito", systemImage: "flag")
            }
            Button {
                container.decisionRulesStore.beginEditing()
            } label: {
                row(label: "Cómo decidimos", systemImage: "person.3.sequence")
            }
            NavigationLink(value: GroupSettingsDestination.rules) {
                Label("Reglas", systemImage: "list.bullet.rectangle")
            }
            NavigationLink(value: GroupSettingsDestination.culture) {
                Label("Cultura", systemImage: "heart")
            }
            NavigationLink(value: GroupSettingsDestination.boundaryPolicy) {
                Label("Frontera", systemImage: "door.left.hand.closed")
            }
            NavigationLink(value: GroupSettingsDestination.groupProfile) {
                Label("Perfil del grupo", systemImage: "person.crop.rectangle")
            }
        }
    }

    // MARK: - 2. Recursos del grupo

    @ViewBuilder
    private var resourcesSection: some View {
        Section("Recursos del grupo") {
            NavigationLink(value: GroupSettingsDestination.resources) {
                Label("Lo que tenemos", systemImage: "square.stack.3d.up")
            }
            NavigationLink(value: GroupSettingsDestination.contributions) {
                Label("Quién aportó qué", systemImage: "hands.sparkles")
            }
        }
    }

    // MARK: - 3. En proceso

    @ViewBuilder
    private var inProgressSection: some View {
        Section("En proceso") {
            NavigationLink(value: GroupSettingsDestination.decisions) {
                Label("Decisiones", systemImage: "checkmark.seal")
            }
            NavigationLink(value: GroupSettingsDestination.disputes) {
                Label("Disputas", systemImage: "hand.raised")
            }
            NavigationLink(value: GroupSettingsDestination.sanctionsPolicy) {
                Label("Sanciones", systemImage: "exclamationmark.shield")
            }
        }
    }

    // MARK: - 4. Vida del grupo

    @ViewBuilder
    private var lifeSection: some View {
        Section("Vida del grupo") {
            NavigationLink(value: GroupSettingsDestination.rituals) {
                Label("Rituales", systemImage: "sparkles")
            }
            NavigationLink(value: GroupSettingsDestination.history) {
                Label("Historia del grupo", systemImage: "clock.arrow.circlepath")
            }
            NavigationLink(value: GroupSettingsDestination.reputationFeed) {
                Label("Reputación del grupo", systemImage: "star.bubble")
            }
        }
    }

    // MARK: - 5. Estructura

    @ViewBuilder
    private var structureSection: some View {
        Section("Estructura") {
            NavigationLink(value: GroupSettingsDestination.roles) {
                Label("Roles y permisos", systemImage: "person.crop.circle.badge.checkmark")
            }
            NavigationLink(value: GroupSettingsDestination.mandates) {
                Label("Mandatos", systemImage: "signature")
            }
        }
    }

    // MARK: - 6. Configuración (+ danger)

    @ViewBuilder
    private var configSection: some View {
        Section("Configuración") {
            NavigationLink(value: GroupSettingsDestination.notifications) {
                Label(L10n.GroupSettings.notificationsRow, systemImage: "bell")
            }
            NavigationLink(value: GroupSettingsDestination.privacy) {
                Label(L10n.GroupSettings.privacyRow, systemImage: "lock")
            }
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

    // MARK: - Destination switch

    @ViewBuilder
    private func destinationView(for destination: GroupSettingsDestination) -> some View {
        switch destination {
        case .rules:
            RulesListView(
                store: container.rulesStore,
                evaluationsStore: container.ruleEvaluationsStore,
                groupId: group.id
            )
        case .culture:
            CulturalNormsListView(
                store: container.culturalNormsStore,
                groupId: group.id,
                onPromotedToRule: {
                    Task { await container.rulesStore.refresh(groupId: group.id) }
                }
            )
        case .boundaryPolicy:
            BoundaryPolicyView(store: container.boundaryPolicyStore, groupId: group.id)
        case .groupProfile:
            GroupProfileView(container: container, group: group)
        case .resources:
            ResourcesListView(
                store: container.resourcesStore,
                membersStore: container.membersStore,
                groupId: group.id
            )
        case .contributions:
            ContributionsListView(
                store: container.contributionsStore,
                groupId: group.id,
                myMembershipId: group.membershipId
            )
        case .decisions:
            DecisionsListView(
                store: container.decisionsStore,
                groupId: group.id,
                onSelectReference: { link in
                    container.deepLinkRouter.apply(link)
                },
                sanctionsStore: container.sanctionsStore,
                mandatesStore: container.mandatesStore,
                membersStore: container.membersStore,
                rulesStore: container.rulesStore,
                decisionRulesStore: container.decisionRulesStore
            )
        case .disputes:
            DisputesListView(
                store: container.disputesStore,
                groupId: group.id,
                container: container,
                myMembershipId: group.membershipId
            )
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
        case .rituals:
            RitualsListView(store: container.ritualsStore, groupId: group.id)
        case .history:
            GroupHistoryView(
                store: container.eventsStore,
                groupId: group.id,
                onSelectEvent: { event in
                    if let link = HistoryEventRouting.deepLink(for: event, groupId: group.id) {
                        container.deepLinkRouter.apply(link)
                    }
                }
            )
        case .reputationFeed:
            ReputationFeedView(
                store: container.reputationFeedStore,
                membersStore: container.membersStore,
                groupId: group.id
            )
        case .roles:
            RolesListView(store: container.rolesStore, groupId: group.id)
        case .mandates:
            MandatesListView(
                store: container.mandatesStore,
                membersStore: container.membersStore,
                groupId: group.id
            )
        case .notifications:
            NotificationSettingsView(store: container.notificationSettingsStore, groupId: group.id)
        case .privacy:
            GroupPrivacyView(store: container.privacyStore, groupId: group.id)
        case .dissolution:
            DissolutionStatusView(store: container.dissolutionStore, groupId: group.id)
        }
    }

    // MARK: - Row helper (used by sheet-triggered rows that can't be NavigationLink)

    @ViewBuilder
    private func row(label: String, systemImage: String) -> some View {
        HStack {
            Label(label, systemImage: systemImage)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Foundation taps

    private func handleFoundationTap(_ kind: FoundationPrimitiveKind) {
        switch kind {
        case .members, .boundary:
            // Foundation card surfaces the gap; resolution lives in
            // Personas tab (Members) or Frontera (Boundary). No
            // direct push from here for now.
            break
        case .purpose:
            container.purposeStore.beginEditing(kind: .declared)
        case .rules:
            container.rulesStore.beginCreating()
        case .resources:
            container.resourcesStore.beginCreating()
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
        case culture
        case boundaryPolicy
        case groupProfile
        case resources
        case contributions
        case decisions
        case disputes
        case sanctionsPolicy
        case rituals
        case history
        case reputationFeed
        case roles
        case mandates
        case notifications
        case privacy
        case dissolution
    }
}
