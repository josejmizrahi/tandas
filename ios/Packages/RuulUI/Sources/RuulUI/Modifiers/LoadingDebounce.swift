import SwiftUI

/// Retrasa la aparición de un loading state por N milisegundos para evitar
/// flashes en cargas rápidas. Si el contenido subyacente completa antes del
/// threshold, el spinner nunca se ve.
///
/// Anti-pattern que reemplaza: `.task { await coordinator.refresh() }` en
/// red rápida (caché caliente, response <100ms) hacía que el spinner
/// parpadeara: visible 50ms → desaparece. UX peor que no mostrar nada.
///
/// Default 250ms — por debajo del umbral percentual donde el usuario
/// nota una transición (~300ms según Nielsen). Suficiente para tapar
/// hits de caché pero no enmascarar latencia real.
public struct LoadingDebounceModifier: ViewModifier {
    private let delay: Duration

    public init(delay: Duration = .milliseconds(250)) {
        self.delay = delay
    }

    @State private var isVisible: Bool = false

    public func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .task(id: ObjectIdentifier(LoadingDebounceMarker.self)) {
                isVisible = false
                do {
                    try await Task.sleep(for: delay)
                    isVisible = true
                } catch {
                    // Task cancelado (view desapareció antes del threshold) →
                    // spinner nunca se mostró. Comportamiento deseado.
                }
            }
    }
}

private enum LoadingDebounceMarker {}

public extension View {
    /// Aplica debounce al loading view (default 250ms). Spinner solo
    /// aparece si el contenido tarda más que ese threshold.
    ///
    /// Uso típico (dentro de AsyncContentView, pero también disponible
    /// para callsites custom):
    /// ```swift
    /// ProgressView()
    ///     .ruulLoadingDebounce()
    /// ```
    func ruulLoadingDebounce(_ delay: Duration = .milliseconds(250)) -> some View {
        modifier(LoadingDebounceModifier(delay: delay))
    }
}
