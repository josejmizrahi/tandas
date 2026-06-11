import Foundation
import Observation

/// Invitaciones pendientes que el actor actual recibió. Long-lived en el
/// `DependencyContainer` porque el surface es transversal (banner en el
/// switcher, sección en `NoContextsView`, etc.). Refresca on-demand y al
/// volver del background.
@MainActor
@Observable
public final class InvitationsStore {
    public private(set) var invitations: [PendingInvitation] = []
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    /// Preview init.
    public init(rpc: any RuulRPCClient, previewInvitations: [PendingInvitation]) {
        self.rpc = rpc
        self.invitations = previewInvitations
        self.phase = .loaded
    }

    public var hasPending: Bool { !invitations.isEmpty }

    /// Carga las invitaciones pendientes para el actor dado. No-op silencioso
    /// si no hay actor (todavía no pasaron los gates).
    public func load(actorId: UUID?) async {
        guard let actorId else { return }
        if invitations.isEmpty { phase = .loading }
        do {
            invitations = try await rpc.listMyPendingInvitations(actorId: actorId)
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Acepta una invitación y la remueve del listado local.
    public func accept(contextId: UUID, actorId: UUID?) async throws -> AcceptInvitationResult {
        let result = try await rpc.acceptInvitation(contextId: contextId)
        invitations.removeAll { $0.contextActorId == contextId }
        // Refresh para alinearnos con el backend (por si concurrió otro cambio).
        await load(actorId: actorId)
        return result
    }

    /// FE.1 (P0.1) — rechaza una invitación y la remueve del listado local.
    public func decline(contextId: UUID, actorId: UUID?) async throws {
        try await rpc.declineInvitation(contextId: contextId)
        invitations.removeAll { $0.contextActorId == contextId }
        // Refresh para alinearnos con el backend (por si concurrió otro cambio).
        await load(actorId: actorId)
    }

    public func reset() {
        invitations = []
        phase = .idle
    }
}
