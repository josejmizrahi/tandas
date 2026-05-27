import SwiftUI
import RuulCore

/// Single-group home screen for the Foundation shell. Owns the
/// refresh triggers for `CurrentGroupStore` (summary) + `MoneyStore`
/// (balance + obligations), and hosts the three Foundation actions:
/// register expense, settle, invite. Leave-group is in the toolbar menu.
struct GroupHomeView: View {
    let container: DependencyContainer
    let group: GroupListItem

    @Environment(\.dismiss) private var dismiss

    @State private var isShowingExpenseSheet: Bool = false
    @State private var isShowingSettlementSheet: Bool = false
    @State private var isShowingInviteSheet: Bool = false
    @State private var isConfirmingLeave: Bool = false
    @State private var leaveError: UserFacingError?

    /// Drives the `MemberHistoryView` navigation push. Set when a row
    /// inside the embedded `MembersListView` is tapped. SwiftUI's
    /// `navigationDestination(item:)` consumes the binding.
    @State private var pendingHistorySelection: MembershipBoundaryItem?

    var body: some View {
        List {
            summarySection
            foundationStatusSection
            purposeSection
            decisionRulesSection
            rulesSection
            resourcesSection
            moneySection
            membersSection
            actionsSection
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: MembersDestination.self) { _ in
            MembersListView(
                store: container.membersStore,
                groupId: group.id,
                onSelectMember: { item in
                    pendingHistorySelection = item
                }
            )
        }
        .navigationDestination(item: $pendingHistorySelection) { item in
            MemberHistoryView(
                store: container.reputationStore,
                groupId: group.id,
                memberItem: item
            )
        }
        .navigationDestination(for: RulesDestination.self) { _ in
            RulesListView(store: container.rulesStore, groupId: group.id)
        }
        .navigationDestination(for: ResourcesDestination.self) { _ in
            ResourcesListView(store: container.resourcesStore, groupId: group.id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        isConfirmingLeave = true
                    } label: {
                        Label("Salir del grupo", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Label("Más", systemImage: "ellipsis.circle")
                }
            }
        }
        .refreshable {
            await refresh()
        }
        .task {
            await container.currentGroupStore.setGroup(group)
            await container.moneyStore.refresh(groupId: group.id, membershipId: group.membershipId)
            await container.purposeStore.refreshIfNeeded(groupId: group.id)
            await container.rulesStore.refreshIfNeeded(groupId: group.id)
            await container.resourcesStore.refreshIfNeeded(groupId: group.id)
            await container.decisionRulesStore.refreshIfNeeded(groupId: group.id)
            await container.foundationStatusStore.refresh(groupId: group.id)
        }
        .sheet(isPresented: purposeSheetBinding) {
            EditPurposeView(store: container.purposeStore, groupId: group.id)
        }
        .sheet(isPresented: decisionRulesSheetBinding) {
            EditDecisionRulesView(store: container.decisionRulesStore, groupId: group.id)
        }
        .sheet(isPresented: rulesCreateSheetBinding) {
            EditRuleView(store: container.rulesStore, groupId: group.id)
        }
        .sheet(isPresented: resourcesCreateSheetBinding) {
            CreateResourceView(store: container.resourcesStore, groupId: group.id)
        }
        .sheet(isPresented: $isShowingExpenseSheet) {
            RecordExpenseSheet(
                container: container,
                groupId: group.id,
                myMembershipId: group.membershipId
            ) {
                isShowingExpenseSheet = false
                Task { await refresh() }
            }
        }
        .sheet(isPresented: $isShowingSettlementSheet) {
            RecordSettlementSheet(
                container: container,
                groupId: group.id,
                myMembershipId: group.membershipId
            ) {
                isShowingSettlementSheet = false
                Task { await refresh() }
            }
        }
        .sheet(isPresented: $isShowingInviteSheet) {
            InviteMemberSheet(
                container: container,
                groupId: group.id
            ) {
                isShowingInviteSheet = false
            }
        }
        .alert("Salir del grupo", isPresented: $isConfirmingLeave) {
            Button("Cancelar", role: .cancel) {}
            Button("Salir", role: .destructive) {
                Task { await leave() }
            }
        } message: {
            Text("Dejarás de ver lo que pase aquí. Puedes volver con otra invitación.")
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
    }

    // MARK: - Sections

    @ViewBuilder
    private var summarySection: some View {
        Section {
            if let summary = container.currentGroupStore.summary {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Label("\(summary.memberCount)", systemImage: "person.3")
                        if summary.openObligations > 0 {
                            Label("\(summary.openObligations) deudas", systemImage: "creditcard")
                        }
                        if summary.openDecisions > 0 {
                            Label("\(summary.openDecisions) decisiones", systemImage: "checkmark.seal")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    if let purpose = group.purposeSummary, !purpose.isEmpty {
                        Text(purpose)
                            .font(.body)
                    }
                }
                .padding(.vertical, 4)
            } else if case .failed(let message) = container.currentGroupStore.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    ProgressView()
                    Text("Cargando…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var purposeSection: some View {
        Section(L10n.Purpose.title) {
            GroupPurposeCard(store: container.purposeStore)
        }
    }

    @ViewBuilder
    private var decisionRulesSection: some View {
        Section(L10n.DecisionRules.title) {
            DecisionRulesCard(store: container.decisionRulesStore)
        }
    }

    @ViewBuilder
    private var foundationStatusSection: some View {
        Section(L10n.Foundation.title) {
            FoundationStatusCard(
                store: container.foundationStatusStore,
                onSelect: { kind in
                    handleFoundationTap(kind)
                }
            )
        }
    }

    private func handleFoundationTap(_ kind: FoundationPrimitiveKind) {
        switch kind {
        case .members, .boundary:
            // Both rows lead to the same create-affordance: invite a
            // member. The invite sheet is hosted on GroupHomeView.
            isShowingInviteSheet = true
        case .purpose:
            container.purposeStore.beginEditing(kind: .declared)
        case .rules:
            container.rulesStore.beginCreating()
        case .resources:
            container.resourcesStore.beginCreating()
        }
    }

    @ViewBuilder
    private var resourcesSection: some View {
        Section(L10n.Resources.title) {
            GroupResourcesCard(
                store: container.resourcesStore,
                onAdd: { container.resourcesStore.beginCreating() }
            )
            if container.resourcesStore.hasResources {
                NavigationLink(value: ResourcesDestination()) {
                    Text(container.resourcesStore.resources.count == 1
                         ? String(localized: L10n.Resources.countSingular)
                         : "\(container.resourcesStore.resources.count) recursos activos")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var rulesSection: some View {
        Section(L10n.Rules.title) {
            GroupRulesCard(
                store: container.rulesStore,
                onAdd: { container.rulesStore.beginCreating() }
            )
            if container.rulesStore.hasRules {
                NavigationLink(value: RulesDestination()) {
                    Text(container.rulesStore.rules.count == 1
                         ? String(localized: L10n.Rules.countSingular)
                         : "\(container.rulesStore.rules.count) reglas activas")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var moneySection: some View {
        Section("Dinero") {
            MoneyBlock(container: container)
        }
    }

    @ViewBuilder
    private var membersSection: some View {
        Section {
            NavigationLink(value: MembersDestination()) {
                Label {
                    let count = container.currentGroupStore.summary?.memberCount
                    Text(count.map { "\($0) miembros" } ?? "Miembros")
                } icon: {
                    Image(systemName: "person.2")
                }
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            Button {
                isShowingExpenseSheet = true
            } label: {
                Label("Registrar gasto", systemImage: "plus.circle")
            }
            Button {
                isShowingSettlementSheet = true
            } label: {
                Label("Liquidar al grupo", systemImage: "checkmark.circle")
            }
            Button {
                isShowingInviteSheet = true
            } label: {
                Label("Invitar a alguien", systemImage: "person.crop.circle.badge.plus")
            }
        }
    }

    // MARK: - Actions

    private func refresh() async {
        await container.currentGroupStore.refresh()
        await container.moneyStore.refresh(groupId: group.id, membershipId: group.membershipId)
        await container.decisionRulesStore.refresh(groupId: group.id)
        await container.foundationStatusStore.refresh(groupId: group.id)
    }

    /// `Hashable` token for the Members destination so the existing
    /// `NavigationStack` (declared on `RuulAppShell`) can push the
    /// list view via `NavigationLink(value:)`.
    private struct MembersDestination: Hashable {}

    /// Same pattern for the Rules destination.
    private struct RulesDestination: Hashable {}

    /// And Resources.
    private struct ResourcesDestination: Hashable {}

    /// Bridges the `isEditPresented` flag on the shared PurposeStore
    /// to the View's `.sheet(isPresented:)` API (mirrors the same
    /// pattern used by GroupListView for the profile sheet).
    private var purposeSheetBinding: Binding<Bool> {
        Binding(
            get: { container.purposeStore.isEditPresented },
            set: { container.purposeStore.isEditPresented = $0 }
        )
    }

    /// Same pattern for the Rules create sheet. The empty-state
    /// "Agregar" button on the GroupRulesCard flips this flag (so
    /// users can create the first rule without first navigating into
    /// the full RulesListView).
    private var rulesCreateSheetBinding: Binding<Bool> {
        Binding(
            get: { container.rulesStore.isCreatePresented },
            set: { container.rulesStore.isCreatePresented = $0 }
        )
    }

    private var resourcesCreateSheetBinding: Binding<Bool> {
        Binding(
            get: { container.resourcesStore.isCreatePresented },
            set: { container.resourcesStore.isCreatePresented = $0 }
        )
    }

    /// Same pattern as `purposeSheetBinding` — drives the
    /// `EditDecisionRulesView` sheet via the shared store flag.
    private var decisionRulesSheetBinding: Binding<Bool> {
        Binding(
            get: { container.decisionRulesStore.isEditPresented },
            set: { container.decisionRulesStore.isEditPresented = $0 }
        )
    }

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
}
