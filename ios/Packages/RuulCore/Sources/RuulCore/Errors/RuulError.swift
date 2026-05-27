import Foundation

/// Top-level error type used everywhere in RuulCore + Features. Wraps
/// `CanonicalBackendError` (parsed Postgrest raise messages) and a few
/// orthogonal client-side cases (network, decoding, cancellation).
public enum RuulError: Error, Sendable, Equatable {
    case backend(CanonicalBackendError)
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
