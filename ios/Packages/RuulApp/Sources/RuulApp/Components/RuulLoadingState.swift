import SwiftUI

/// R.5V.2 — Estado de carga consistente. Wrapper de `ProgressView`.
///
/// **Drop-in replacement** para `LoadingStateView` (legacy en `StateViews.swift`).
/// V.8 migrará los ~30 usuarios a este componente.
///
/// Doctrina UX §V.1: native first, `ProgressView` + label semántico.
public struct RuulLoadingState: View {
    public let title: String

    public init(title: String = "Cargando…") {
        self.title = title
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .foregroundStyle(Theme.Text.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    RuulLoadingState()
}
