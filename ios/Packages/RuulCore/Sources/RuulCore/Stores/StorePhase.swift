import Foundation

/// Tri-state lifecycle for the Foundation `@Observable` stores.
///
/// Named `StorePhase` (not `LoadPhase`) to avoid colliding with the
/// generic `LoadPhase<Value>` declared in `Loading/LoadPhase.swift` —
/// that one carries the value inside the case and is used by the legacy
/// coordinator-driven views; this one is a pure status flag because the
/// stores already hold their data in separate `@Observable` properties.
///
/// `failed` carries a `UserFacingError`-ready message string so views
/// can render directly without re-mapping; the original `RuulError` is
/// logged at the store boundary.
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
