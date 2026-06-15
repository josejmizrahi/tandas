import SwiftUI
import RuulCore

/// R.10.A — Transfer flow (R.7.x) UI: modifier + picker + helpers
/// (code move, zero behavior change).
///
/// Doctrina: R.5V native-first · "Section is the card".
/// Movido del monolito previo (1518–1639 + helpers de transfer en main).
///
/// R.7.x: `resource.transfer` requires governance via decision. UI flow:
///   - openTransferPicker: carga miembros activos del contexto.
///   - TransferRecipientPicker: List+Section nativo para elegir destinatario.
///   - confirmationDialog: explica que se necesita aprobación colectiva.
///   - requestGovernanceAction(actionKey:"resource.transfer", payload:{to_actor_id}).
///   - Sheet con DecisionDetailView del decision recién creado.

struct ResourceDetailV2TransferFlowModifier: ViewModifier {
    @Binding var isShowingPicker: Bool
    @Binding var members: [ContextMember]
    @Binding var recipientId: UUID?
    @Binding var isShowingGovernanceSheet: Bool
    @Binding var pendingDecisionId: UUID?
    let resource: Resource?
    let context: AppContext
    let container: DependencyContainer
    let governanceMessage: String
    let onConfirmRecipient: () -> Void
    let onRequestGovernance: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isShowingPicker) {
                ResourceDetailV2TransferRecipientPicker(
                    members: members,
                    recipientId: $recipientId,
                    resourceName: resource?.displayName ?? "Recurso",
                    onCancel: { isShowingPicker = false },
                    onContinue: onConfirmRecipient
                )
            }
            .confirmationDialog(
                "Esta acción requiere aprobación",
                isPresented: $isShowingGovernanceSheet,
                titleVisibility: .visible
            ) {
                Button("Crear decisión") { onRequestGovernance() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(governanceMessage)
            }
            .sheet(item: Binding(
                get: { pendingDecisionId.map { ResourceDetailV2TransferDecisionSheetWrapper(id: $0) } },
                set: { pendingDecisionId = $0?.id }
            )) { wrapper in
                NavigationStack {
                    DecisionDetailView(decisionId: wrapper.id, context: context, container: container)
                }
            }
    }
}

/// R.7.x — wrapper Identifiable para `.sheet(item:)` del push DecisionDetailView.
struct ResourceDetailV2TransferDecisionSheetWrapper: Identifiable {
    let id: UUID
}

/// R.7.x — picker dedicado para elegir el destinatario del transfer.
/// Apple-native: `List + Section`. Confirma habilitando "Continuar" sólo cuando
/// hay recipient seleccionado.
struct ResourceDetailV2TransferRecipientPicker: View {
    let members: [ContextMember]
    @Binding var recipientId: UUID?
    let resourceName: String
    let onCancel: () -> Void
    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if members.isEmpty {
                    Section {
                        Text("No hay miembros disponibles para recibir la propiedad.")
                            .foregroundStyle(Theme.Text.secondary)
                    }
                } else {
                    Section {
                        ForEach(members) { member in
                            Button {
                                recipientId = member.actorId
                            } label: {
                                HStack {
                                    Label {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(member.displayName)
                                                .foregroundStyle(Theme.Text.primary)
                                            if let type = member.membershipType {
                                                Text(type.capitalized)
                                                    .font(.caption)
                                                    .foregroundStyle(Theme.Text.secondary)
                                            }
                                        }
                                    } icon: {
                                        Image(systemName: "person.crop.circle")
                                            .foregroundStyle(Theme.Tint.primary)
                                    }
                                    Spacer()
                                    if recipientId == member.actorId {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.Tint.primary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Elegí destinatario")
                    } footer: {
                        Text("La transferencia se propondrá como decisión para aprobación colectiva.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Transferir \(resourceName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continuar", action: onContinue)
                        .disabled(recipientId == nil)
                }
            }
        }
    }
}
