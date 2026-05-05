import Foundation

// @codegen:enum
public enum BadType: Codable {
    case a
    case b(String)  // associated value not allowed except trailing unknown
    case unknown(String)
}
