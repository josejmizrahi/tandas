import Foundation

/// Ciclo de vida tri-estado de los stores `@Observable`.
/// `failed` lleva el mensaje ya listo para UI (`UserFacingError`).
public enum StorePhase: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case failed(message: String)

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
