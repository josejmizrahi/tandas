import SwiftUI
import RuulCore

/// F.CONTEXT.5 — Acción ambiente para navegar a otro contexto desde cualquier
/// vista anidada dentro del NavigationStack de `ContextsListView`. La
/// implementación real se inyecta arriba (resetea el path y push del target);
/// los consumidores sólo llaman `action(context)`.
///
/// Usado por:
/// - BreadcrumbView (tap en ancestro)
/// - cualquier futura tarjeta de "Posibles relacionados" / cross-context jump
public struct NavigateToContextAction: Sendable {
    private let action: @Sendable (AppContext) -> Void

    public init(_ action: @escaping @Sendable (AppContext) -> Void) {
        self.action = action
    }

    public func callAsFunction(_ context: AppContext) {
        action(context)
    }
}

private struct NavigateToContextKey: EnvironmentKey {
    static let defaultValue: NavigateToContextAction? = nil
}

extension EnvironmentValues {
    /// `nil` cuando la vista vive fuera de un host que lo inyecte (preview,
    /// tab no-Contextos…). Los consumidores deben usar `if let` antes de
    /// invocar.
    public var navigateToContext: NavigateToContextAction? {
        get { self[NavigateToContextKey.self] }
        set { self[NavigateToContextKey.self] = newValue }
    }
}
