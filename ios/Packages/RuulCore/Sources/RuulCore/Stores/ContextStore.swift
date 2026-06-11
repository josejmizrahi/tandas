import Foundation
import Observation

/// F.3 — store del contexto activo. Hidrata los contextos disponibles desde
/// `context_candidates()` y persiste la selección entre lanzamientos.
///
/// Doctrina: seleccionas un contexto → toda la app opera desde él.
@MainActor
@Observable
public final class ContextStore {
    public private(set) var availableContexts: [AppContext] = []
    public private(set) var currentContext: AppContext?
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient
    private let defaults: UserDefaults

    /// Key de persistencia del contexto seleccionado.
    public static let persistedIdKey = "mvp2_current_context_id"

    public init(rpc: any RuulRPCClient, defaults: UserDefaults = .standard) {
        self.rpc = rpc
        self.defaults = defaults
    }

    /// Preview/test init con contextos fijos.
    public init(
        rpc: any RuulRPCClient,
        previewContexts: [AppContext],
        current: AppContext? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.rpc = rpc
        self.defaults = defaults
        self.availableContexts = previewContexts
        self.currentContext = current ?? previewContexts.first
        self.phase = .loaded
    }

    /// El contexto personal del usuario (siempre existe tras cargar).
    public var personalContext: AppContext? {
        availableContexts.first { $0.isPersonal }
    }

    /// Contextos colectivos/legales (sin el personal).
    public var collectiveContexts: [AppContext] {
        availableContexts.filter { !$0.isPersonal }
    }

    // MARK: - Carga

    /// Hidrata desde `context_candidates()` y restaura la selección persistida.
    public func load() async {
        if availableContexts.isEmpty { phase = .loading }
        do {
            let candidates = try await rpc.contextCandidates()
            availableContexts = candidates.appContexts
            // P1.13 — el "Contexto inicial" configurado en Ajustes gana en el
            // arranque frío (una vez por proceso). No-fatal si falla la lectura.
            if !didResolveDefaultContext {
                didResolveDefaultContext = true
                if currentContext == nil,
                   let settings = try? await rpc.personalSettingsSummary(),
                   let defaultId = settings.contexts.defaultContextActorId,
                   let match = availableContexts.first(where: { $0.id == defaultId }) {
                    currentContext = match
                    defaults.set(match.id.uuidString, forKey: Self.persistedIdKey)
                    phase = .loaded
                    return
                }
            }
            resolveSelectionAfterLoad()
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// P1.13 — el default configurado se evalúa una sola vez por proceso.
    private var didResolveDefaultContext = false

    // MARK: - Selección

    /// Cambia el contexto activo y persiste la selección.
    public func switchTo(_ context: AppContext) {
        guard availableContexts.contains(where: { $0.id == context.id }) else { return }
        currentContext = context
        defaults.set(context.id.uuidString, forKey: Self.persistedIdKey)
    }

    /// Limpia todo (al cerrar sesión).
    public func reset() {
        availableContexts = []
        currentContext = nil
        phase = .idle
        didResolveDefaultContext = false
        defaults.removeObject(forKey: Self.persistedIdKey)
    }

    private func resolveSelectionAfterLoad() {
        // 1. Mantener la selección en memoria si sigue existiendo.
        if let current = currentContext,
           let refreshed = availableContexts.first(where: { $0.id == current.id }) {
            currentContext = refreshed
            return
        }
        // 2. Restaurar la persistida.
        if let idString = defaults.string(forKey: Self.persistedIdKey),
           let id = UUID(uuidString: idString),
           let match = availableContexts.first(where: { $0.id == id }) {
            currentContext = match
            return
        }
        // 3. Fallback: primer colectivo, o el contexto personal.
        currentContext = collectiveContexts.first ?? personalContext
    }
}
