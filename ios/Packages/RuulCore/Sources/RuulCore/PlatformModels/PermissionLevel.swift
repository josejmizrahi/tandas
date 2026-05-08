import Foundation

// @codegen:enum
public enum PermissionLevel: Codable, Sendable, Hashable {
    /// Only the founder of the group can perform the action.
    case founder

    /// Any active member of the group can perform the action.
    case anyMember

    /// A successful majority vote (>= 50% threshold by default) is required.
    case majorityVote

    /// A successful supermajority vote (>= 66% threshold by default) is required.
    case supermajorityVote

    /// Only the host of the contextual event can perform the action.
    /// Useful for actions like `closeEvents` where the actor is determined
    /// by the resource being acted on.
    case host

    /// Only the treasurer (V2 role) can perform the action.
    case treasurer

    case unknown(String)
}
