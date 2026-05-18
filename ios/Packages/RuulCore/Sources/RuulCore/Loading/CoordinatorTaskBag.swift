import Foundation

/// Container Sendable para gestionar long-lived `Task` handles dentro
/// de coordinators con cancellation automática en deinit.
///
/// **Problema que resuelve**: coordinators que se suscriben a un
/// realtime feed (Supabase channel, multi-device change feed, etc.)
/// arrancan una `Task` infinita en `init` y deben cancelarla en
/// `deinit`. Swift 6 `deinit` es `nonisolated`, así que el holder
/// del task debe ser Sendable — lo que requiere ya sea
/// `nonisolated(unsafe)` con un comentario explicativo, o un wrapper.
///
/// Esta clase encapsula el patrón: ownership de los handles,
/// cancellation atómica vía `OSAllocatedUnfairLock` (o `Mutex`
/// cuando esté disponible), y API `register`/`cancelAll`.
///
/// **Uso típico**:
/// ```swift
/// @Observable @MainActor
/// final class FoosCoordinator {
///     private let tasks = CoordinatorTaskBag()
///     init(feed: ChangeFeed) {
///         tasks.register(Task { [weak self] in
///             for await change in feed.changes {
///                 if Task.isCancelled { return }
///                 await self?.refresh()
///             }
///         })
///     }
///     deinit { tasks.cancelAll() }
/// }
/// ```
///
/// **Alternativa simple** (lo que muchos coordinators hacen hoy):
/// ```swift
/// nonisolated(unsafe) private var task: Task<Void, Never>?
/// deinit { task?.cancel() }
/// ```
/// Esto funciona pero requiere `nonisolated(unsafe)` por cada handle
/// y silencia el typesystem. `CoordinatorTaskBag` agrupa N handles
/// detrás de una API Sendable explícita.
public final class CoordinatorTaskBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    public init() {}

    /// Añade un task al bag. Cancellable después vía `cancelAll`. El
    /// bag retiene el handle hasta que se cancela o el bag se libera.
    public func register(_ task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        tasks.append(task)
    }

    /// Cancela todos los tasks registrados. Idempotente — llamar
    /// múltiples veces es seguro. Llamar desde deinit (nonisolated).
    public func cancelAll() {
        lock.lock()
        let snapshot = tasks
        tasks.removeAll()
        lock.unlock()
        for t in snapshot { t.cancel() }
    }

    deinit { cancelAll() }
}
