import Foundation

public extension ConsequenceType {
    public var isImplementedInV1: Bool {
        switch self {
        case .fine, .emitWarning, .requireApproval, .lockBookings,
             // Space rule consequences — evaluators landed in PR-3
             // of SpaceRules roadmap.
             .releaseBooking, .denyAction, .bumpPriority:
            return true
        default:
            return false
        }
    }
}
