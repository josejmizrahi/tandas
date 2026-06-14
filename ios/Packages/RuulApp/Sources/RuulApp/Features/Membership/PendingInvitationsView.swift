import SwiftUI
import RuulCore

/// Sheet con las invitaciones pendientes que el actor actual recibió.
/// Cada fila → "Aceptar" llama `accept_invitation` y refresca los contextos.
/// Swipe → "Rechazar" llama `decline_invitation` (FE.1, P0.1).
public struct PendingInvitationsView: View {
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var runner = ActionRunner()
    @State private var acceptingId: UUID?
    @State private var lastAcceptedName: String?
    @State private var invitationToDecline: PendingInvitation?

    public init(container: DependencyContainer) {
        self.container = container
    }

    private var store: InvitationsStore { container.invitationsStore }

    public var body: some View {
        NavigationStack {
            Group {
                if case .failed(let message) = store.phase {
                    RuulErrorState(message: message) {
                        Task { await store.load(actorId: container.currentActorStore.actorId) }
                    }
                } else if store.invitations.isEmpty && !store.phase.isLoaded {
                    RuulLoadingState(title: "Cargando invitaciones…")
                } else {
                    invitationsList
                }
            }
            .navigationTitle("Invitaciones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .task {
                await store.load(actorId: container.currentActorStore.actorId)
            }
            .refreshable {
                await store.load(actorId: container.currentActorStore.actorId)
            }
            .actionErrorAlert(runner)
        }
        .ruulCompactSheet()
    }

    @ViewBuilder
    private var invitationsList: some View {
        if store.invitations.isEmpty {
            RuulEmptyState(
                title: "Sin invitaciones",
                systemImage: "tray",
                message: "Cuando alguien te invite directamente a un espacio, aparecerá aquí."
                )
        } else {
            List {
                Section {
                    ForEach(store.invitations) { invitation in
                        row(for: invitation)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    invitationToDecline = invitation
                                } label: {
                                    Label("Rechazar", systemImage: "xmark.circle")
                                }
                            }
                    }
                } footer: {
                    if let lastAcceptedName {
                        Label("Te uniste a \(lastAcceptedName)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    } else {
                        Text("Desliza una invitación para rechazarla.")
                    }
                }
            }
            .confirmationDialog(
                "¿Rechazar la invitación a \(invitationToDecline?.contextDisplayName ?? "")?",
                isPresented: Binding(
                    get: { invitationToDecline != nil },
                    set: { if !$0 { invitationToDecline = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Rechazar invitación", role: .destructive) {
                    guard let invitation = invitationToDecline else { return }
                    invitationToDecline = nil
                    Task { await decline(invitation) }
                }
                Button("Cancelar", role: .cancel) { invitationToDecline = nil }
            } message: {
                Text("Pueden volver a invitarte después si cambias de opinión.")
            }
        }
    }

    @ViewBuilder
    private func row(for invitation: PendingInvitation) -> some View {
        let context = AppContext(
            id: invitation.contextActorId,
            kind: invitation.contextActorKind,
            subtype: invitation.contextActorSubtype ?? "other",
            displayName: invitation.contextDisplayName
        )
        HStack(spacing: 12) {
            Image(systemName: context.symbolName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.badgeFillSubtle, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(invitation.contextDisplayName)
                    .font(.body.weight(.medium))
                if let invitedAt = invitation.invitedAt {
                    Text("Invitado \(invitedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await accept(invitation) }
            } label: {
                if acceptingId == invitation.membershipId {
                    ProgressView()
                } else {
                    Text("Aceptar")
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(acceptingId != nil)
        }
        .padding(.vertical, 2)
    }

    private func decline(_ invitation: PendingInvitation) async {
        await runner.run {
            try await container.invitationsStore.decline(
                contextId: invitation.contextActorId,
                actorId: container.currentActorStore.actorId
            )
        }
    }

    private func accept(_ invitation: PendingInvitation) async {
        acceptingId = invitation.membershipId
        defer { acceptingId = nil }

        let success = await runner.run {
            let actorId = container.currentActorStore.actorId
            _ = try await container.invitationsStore.accept(
                contextId: invitation.contextActorId,
                actorId: actorId
            )
            lastAcceptedName = invitation.contextDisplayName
            // Refrescar la lista de espacios y saltar al nuevo.
            await container.contextStore.load()
            if let new = container.contextStore.availableContexts.first(where: { $0.id == invitation.contextActorId }) {
                container.contextStore.switchTo(new)
            }
        }
        // 7.F.3 (audit 2026-06-14) — dismiss automático tras aceptar (mismo
        // patrón que JoinByCodeView del Slice 7.C.3): el contexto ya quedó
        // activo, llevar al usuario directo al espacio en vez de dejarlo
        // mirando la lista de invitaciones (que ya no tiene esta entry).
        if success && store.invitations.isEmpty {
            dismiss()
        }
    }
}

#Preview("Invitaciones pendientes") {
    PendingInvitationsView(container: .demo())
}
