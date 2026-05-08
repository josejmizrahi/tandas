import Foundation

/// Errors thrown by ResourceRow decoders and ResourceRepository ops.
public enum ResourceRowError: LocalizedError, Sendable, Equatable {
    /// The row's resource_type doesn't match the type the caller asked to decode as.
    /// e.g. caller invoked `decodeAsEvent()` on a row whose resource_type is `.slot`.
    case typeMismatch(expected: ResourceType, got: ResourceType)

    /// A required key is missing from the metadata jsonb.
    case missingMetadataKey(String)

    /// The metadata jsonb couldn't be decoded into the target struct.
    case metadataDecodeFailed(String)

    /// The remote fetch failed.
    case fetchFailed(String)

    /// Resource with the given id wasn't found (or RLS hid it).
    case notFound

    public var errorDescription: String? {
        switch self {
        case .typeMismatch:                   return "Tipo de recurso inesperado."
        case .missingMetadataKey(let key):    return "Falta información en el recurso (\(key))."
        case .metadataDecodeFailed(let detail): return "No se pudo leer el recurso (\(detail))."
        case .fetchFailed:                    return "No se pudo cargar la información."
        case .notFound:                       return "Recurso no encontrado."
        }
    }
}
