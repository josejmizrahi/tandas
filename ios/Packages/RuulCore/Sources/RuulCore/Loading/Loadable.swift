import Foundation

/// Marker protocol para coordinators que exponen un ciclo de carga
/// estándar al UI. Permite a `AsyncContentView` y a tests genéricos
/// consumir cualquier coordinator sin conocer su tipo concreto.
///
/// El protocolo es opcional — adoptarlo no es obligatorio para usar
/// `AsyncContentView` (cualquier vista puede pasar un `LoadPhase` ad
/// hoc). Sirve principalmente para:
///
/// 1. **Documentar la convención** de que `phase` es el único punto
///    de verdad para la UI; los campos `isLoading`/`error`/`data`
///    son detalle interno aunque sean `public`.
/// 2. **Permitir helpers genéricos** sobre coordinators (e.g. snapshot
///    de UI testing, o un middleware que loguea transitions
///    `phase` → `phase`).
///
/// Cumple cualquier `@Observable @MainActor` class que expone un
/// `phase: LoadPhase<Value>` computed y un `refresh() async` method.
@MainActor
public protocol Loadable: AnyObject {
    associatedtype Value: Sendable

    /// Estado actual de la carga. Computed adapter típicamente vía
    /// `LoadPhase.fromCollection(...)` o `LoadPhase.from(...)`.
    var phase: LoadPhase<Value> { get }

    /// Dispara una recarga (primera o subsecuente). Implementaciones
    /// deben flippear `isLoading` y `hasLoaded` internamente para
    /// que `phase` refleje el estado correcto durante la operación.
    func refresh() async
}

public extension Loadable {
    /// Conveniencia: retry-friendly closure que `AsyncContentView`
    /// puede consumir directamente.
    var retryAction: () async -> Void {
        { [weak self] in await self?.refresh() }
    }
}
