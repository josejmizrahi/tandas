import Foundation
import Observation

/// F.2 — resuelve la identidad MVP2 del usuario autenticado:
/// `auth.uid()` → person actor vía `ensure_person_actor()` (idempotente).
///
/// Hasta que `actor` no carga, el shell no muestra contenido: todos los RPCs
/// del contrato requieren que el person actor exista.
@MainActor
@Observable
public final class CurrentActorStore {
    public private(set) var actor: CurrentActor?
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    /// Preview/test init.
    public init(rpc: any RuulRPCClient, previewActor: CurrentActor) {
        self.rpc = rpc
        self.actor = previewActor
        self.phase = .loaded
    }

    public var actorId: UUID? { actor?.id }

    /// Llama `ensure_person_actor()`. Idempotente — seguro de re-llamar en
    /// cada arranque de sesión.
    public func load() async {
        phase = .loading
        do {
            actor = try await rpc.ensurePersonActor()
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Actualiza el perfil del usuario.
    public func updateProfile(fullName: String?, preferredName: String?) async throws {
        actor = try await rpc.updateMyProfile(
            fullName: fullName,
            preferredName: preferredName,
            avatarUrl: nil
        )
    }

    /// Limpia el estado al cerrar sesión.
    public func reset() {
        actor = nil
        phase = .idle
    }
}
