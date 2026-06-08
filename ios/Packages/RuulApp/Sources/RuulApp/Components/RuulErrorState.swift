import SwiftUI

/// R.5V.2 — Error state consistente con retry. Wrapper de `ContentUnavailableView`.
///
/// **Drop-in replacement** para `ErrorStateView` (legacy en `StateViews.swift`).
/// V.8 migrará los ~30 usuarios a este componente.
///
/// Doctrina UX §V.1: native first, `ContentUnavailableView` + glassProminent retry button.
public struct RuulErrorState: View {
    public let title: String
    public let message: String
    public let retry: (() -> Void)?

    public init(
        title: String = "Algo salió mal",
        message: String,
        retry: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Tint.warning)
        } description: {
            Text(message)
        } actions: {
            if let retry {
                Button("Reintentar", action: retry)
                    .buttonStyle(.glassProminent)
            }
        }
    }
}

#Preview {
    RuulErrorState(
        message: "No pudimos conectar con el servidor.",
        retry: {}
    )
}
