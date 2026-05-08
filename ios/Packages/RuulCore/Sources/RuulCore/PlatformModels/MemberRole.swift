import Foundation

/// Roles a `Member` can hold inside a group. Stored as a jsonb array on
/// `group_members.roles`. A member can hold multiple roles simultaneously
/// (e.g. founder + member, treasurer + member, host + member).
public enum MemberRole: String, Codable, Sendable, Hashable, CaseIterable {
    /// Group creator. Has all permissions unless governance is reconfigured.
    case founder

    /// Default role for everyone who joins.
    case member

    /// Contextual: the host of an event. Set per-event, not per-group.
    case host

    /// V2 — administrator of the common fund.
    case treasurer

    /// V2 — can resolve disputes / mediate.
    case arbiter

    /// V2 — read-only role.
    case observer
}
