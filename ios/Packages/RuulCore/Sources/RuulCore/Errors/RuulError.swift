import Foundation

/// Error raíz usado en todo RuulCore + RuulApp. Envuelve `BackendError`
/// (raises de los RPCs MVP2) y casos client-side ortogonales.
public enum RuulError: Error, Sendable, Equatable {
    case backend(BackendError)
    case network(message: String)
    case decoding(message: String)
    case cancelled
    case unexpected(message: String)
}

extension RuulError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .backend(let inner): return String(describing: inner)
        case .network(let m), .decoding(let m), .unexpected(let m): return m
        case .cancelled: return "cancelled"
        }
    }
}
