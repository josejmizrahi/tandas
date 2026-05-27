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

    var body: some View {
        List {
            summarySection
            moneySection
            actionsSection
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
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
    private var moneySection: some View {
        Section("Dinero") {
            MoneyBlock(container: container)
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
