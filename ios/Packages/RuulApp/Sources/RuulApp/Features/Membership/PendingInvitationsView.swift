import SwiftUI
import RuulCore

/// Sheet con las invitaciones pendientes que el actor actual recibió.
/// Cada fila → "Aceptar" llama `accept_invitation` y refresca los contextos.
public struct PendingInvitationsView: View {
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var runner = ActionRunner()
    @State private var acceptingId: UUID?
    @State private var lastAcceptedName: String?

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
                message: "Cuando alguien te invite directamente a un contexto, aparecerá aquí."
                )
        } else {
            List {
                Section {
                    ForEach(store.invitations) { invitation in
                        row(for: invitation)
                    }
                } footer: {
                    if let lastAcceptedName {
                        Label("Te uniste a \(lastAcceptedName)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    }
                }
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

    private func accept(_ invitation: PendingInvitation) async {
        acceptingId = invitation.membershipId
        defer { acceptingId = nil }

        await runner.run {
            let actorId = container.currentActorStore.actorId
            _ = try await container.invitationsStore.accept(
                contextId: invitation.contextActorId,
                actorId: actorId
            )
            lastAcceptedName = invitation.contextDisplayName
            // Refrescar la lista de contextos y saltar al nuevo.
            await container.contextStore.load()
            if let new = container.contextStore.availableContexts.first(where: { $0.id == invitation.contextActorId }) {
                container.contextStore.switchTo(new)
            }
        }
    }
}

#Preview("Invitaciones pendientes") {
    PendingInvitationsView(container: .demo())
}
