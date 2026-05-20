import Foundation

/// Sendable, equatable error envelope rendered by `AsyncContentView` via
/// `ContentUnavailableView` (or by feature-level error chrome).
public struct CoordinatorError: Equatable, Sendable {
    public let title: String
    public let message: String?
    public let isRetryable: Bool

    public init(title: String, message: String? = nil, isRetryable: Bool = true) {
        self.title = title
        self.message = message
        self.isRetryable = isRetryable
    }

    /// Convenience constructor desde Swift Error. Pasa el error por
    /// `RuulErrorTranslator` para no exponer strings raw del sistema
    /// (PostgREST codes, URLError descriptions, GoTrue JWT messages).
    /// Antes el message decía cosas como "URLError(.notConnectedToInternet)"
    /// que el usuario regular no entiende.
    public static func from(_ error: Error, fallback: String = "Algo salió mal") -> CoordinatorError {
        CoordinatorError(
            title: fallback,
            message: error.ruulUserMessage,
            isRetryable: true
        )
    }

    /// Mensaje genérico de red (usar cuando capturás URLError o equivalente).
    public static let network = CoordinatorError(
        title: "Sin conexión",
        message: "Verifica tu internet y vuelve a intentar.",
        isRetryable: true
    )
}
