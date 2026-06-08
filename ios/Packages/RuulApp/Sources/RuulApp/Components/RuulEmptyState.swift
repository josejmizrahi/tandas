import SwiftUI

/// R.5V.2 — Empty state consistente. Wrapper de `ContentUnavailableView`.
///
/// **Drop-in replacement** para `EmptyStateView` (legacy en `StateViews.swift`).
/// V.8 migrará los ~30 usuarios a este componente.
///
/// Doctrina UX §V.1: native first, `ContentUnavailableView` Apple-native (iOS 17+).
public struct RuulEmptyState: View {
    public let title: String
    public let systemImage: String
    public let message: String?

    public init(title: String, systemImage: String, message: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    public var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: message.map { Text($0) }
        )
    }
}

#Preview {
    RuulEmptyState(
        title: "Sin documentos",
        systemImage: "doc",
        message: "Esta casa todavía no tiene documentos adjuntos."
    )
}
