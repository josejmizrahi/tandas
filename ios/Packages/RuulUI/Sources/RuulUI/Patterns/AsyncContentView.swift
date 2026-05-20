import SwiftUI
import RuulCore

/// Canonical wrapper for coordinator-driven content lifecycle.
///
/// Reemplaza el patrón disperso `if error / else if loading / else if empty
/// / else content` que cada vista re-escribía. Recibe un `LoadPhase<Value>`
/// y renderiza la primitiva del DS apropiada para cada estado:
///
/// | Phase                                      | Renderiza                              |
/// |--------------------------------------------|----------------------------------------|
/// | `.idle`                                    | `Color.clear` (placeholder neutral)    |
/// | `.loading`                                 | `RuulLoadingState` con debounce 250ms  |
/// | `.refreshing(value)`                       | `loaded(value)` + `RuulInlineProgress` |
/// | `.loaded(value)`                           | `loaded(value)`                        |
/// | `.empty`                                   | `empty()` (default: `EmptyView`)       |
/// | `.failed(err, previous: nil)`              | `ErrorStateView` full-screen + retry   |
/// | `.failed(err, previous: value)`            | `loaded(value)` + error banner top     |
///
/// **Anti-flash:** durante `.loading`, el spinner solo aparece después de
/// 250ms — cargas más rápidas no causan parpadeo. La transición a `.loaded`
/// usa `.smooth` para no chocar visualmente.
///
/// **Stale-on-error:** si un refresh falla pero teníamos datos previos,
/// el usuario sigue viendo la última snapshot con un banner discreto en
/// vez de pasar a una pantalla de error completa.
///
/// **Uso típico**:
/// ```swift
/// AsyncContentView(
///     phase: coordinator.phase,
///     onRetry: { await coordinator.refresh() },
///     empty: {
///         EmptyStateView(
///             systemImage: "list.bullet.clipboard",
///             title: "Sin acuerdos",
///             message: "Crea el primero para empezar.",
///             primaryAction: ("Crear", { ... })
///         )
///     },
///     loaded: { rules in
///         ScrollView { ForEach(rules) { ruleCard($0) } }
///     }
/// )
/// .refreshable { await coordinator.refresh() }
/// ```
public struct AsyncContentView<Value: Sendable, LoadedContent: View, EmptyContent: View>: View {
    private let phase: LoadPhase<Value>
    private let onRetry: (() async -> Void)?
    private let loadingMessage: String?
    private let empty: () -> EmptyContent
    private let loaded: (Value) -> LoadedContent

    public init(
        phase: LoadPhase<Value>,
        onRetry: (() async -> Void)? = nil,
        loadingMessage: String? = nil,
        @ViewBuilder empty: @escaping () -> EmptyContent,
        @ViewBuilder loaded: @escaping (Value) -> LoadedContent
    ) {
        self.phase = phase
        self.onRetry = onRetry
        self.loadingMessage = loadingMessage
        self.empty = empty
        self.loaded = loaded
    }

    public var body: some View {
        ZStack {
            switch phase {
            case .idle:
                Color.clear
            case .loading:
                RuulLoadingState(message: loadingMessage)
                    .ruulLoadingDebounce()
            case .refreshing(let value):
                loaded(value)
                    .overlay(alignment: .top) { RuulInlineProgress() }
            case .loaded(let value):
                loaded(value)
            case .empty:
                empty()
            case .failed(let err, .some(let value)):
                loaded(value)
                    .overlay(alignment: .top) {
                        ErrorBanner(error: err, retry: retryClosure)
                    }
            case .failed(let err, .none):
                ErrorStateView(error: err, retry: retryClosure)
            }
        }
        .animation(.smooth, value: phase.isInitialLoading)
        .animation(.smooth, value: phase.hasValue)
    }

    private var retryClosure: (() -> Void)? {
        guard let onRetry else { return nil }
        return { Task { await onRetry() } }
    }
}

// MARK: - Convenience inits

public extension AsyncContentView where EmptyContent == EmptyView {
    /// Conveniencia para vistas escalares (detail, form, scalar value) donde
    /// el caso `.empty` no aplica — si el `LoadPhase` factory nunca pasa
    /// un `isEmpty` que dispare `.empty`, este init evita boilerplate.
    init(
        phase: LoadPhase<Value>,
        onRetry: (() async -> Void)? = nil,
        loadingMessage: String? = nil,
        @ViewBuilder loaded: @escaping (Value) -> LoadedContent
    ) {
        self.init(
            phase: phase,
            onRetry: onRetry,
            loadingMessage: loadingMessage,
            empty: { EmptyView() },
            loaded: loaded
        )
    }
}

// MARK: - Equatable animation key

private extension LoadPhase {
    /// Used solo para `.animation(value:)` — disparar el spring solo
    /// cuando cambia el "shape" de la fase, no el contenido.
    var hasValue: Bool {
        switch self {
        case .loaded, .refreshing: return true
        case .failed(_, let prev): return prev != nil
        case .idle, .loading, .empty: return false
        }
    }
}
