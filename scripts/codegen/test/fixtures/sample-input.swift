import Foundation

// @codegen:enum
public enum SampleType: Codable, Sendable, Hashable {
    /// Doc comment on a case — parser ignores.
    case alpha
    case beta
    case gammaRay

    case unknown(String)
}
