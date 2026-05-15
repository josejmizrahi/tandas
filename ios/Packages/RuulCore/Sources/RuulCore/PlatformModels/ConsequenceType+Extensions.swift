import Foundation

public extension ConsequenceType {
    public var isImplementedInV1: Bool {
        switch self {
        case .fine, .emitWarning: return true
        default:                  return false
        }
    }
}
