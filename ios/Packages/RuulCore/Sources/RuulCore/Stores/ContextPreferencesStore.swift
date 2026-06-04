import Foundation

/// F.NAV.0 — Store long-lived de favoritos + contextos recientes del caller.
/// Lo consume HomeView (Continuar) y ContextsView (Favoritos + Recientes).
@MainActor
@Observable
public final class ContextPreferencesStore {
    public private(set) var favorites: [ContextPreference] = []
    public private(set) var recents: [ContextPreference] = []
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func load(recentsLimit: Int = 5) async {
        if favorites.isEmpty && recents.isEmpty { phase = .loading }
        do {
            async let favs = rpc.listContextFavorites()
            async let rec  = rpc.listRecentContexts(limit: recentsLimit)
            let (loadedFavs, loadedRecents) = try await (favs, rec)
            favorites = loadedFavs
            recents = loadedRecents
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Marca / desmarca un contexto como favorito y refresca la lista.
    public func setFavorite(_ contextActorId: UUID, isFavorite: Bool) async throws {
        try await rpc.markContextFavorite(contextActorId: contextActorId, isFavorite: isFavorite)
        await load()
    }

    /// Registra visita al contexto. NO bloquea la UI (best-effort).
    public func recordVisit(_ contextActorId: UUID) async {
        do {
            try await rpc.markContextVisited(contextActorId: contextActorId)
        } catch {
            // best-effort — no rompemos navegación si falla
        }
    }

    public func reset() {
        favorites = []
        recents = []
        phase = .idle
    }
}
