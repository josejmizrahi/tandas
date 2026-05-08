import Foundation

/// Errors thrown by ResourceRow decoders and ResourceRepository ops.
public enum ResourceRowError: Error, Sendable, Equatable {
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
}
