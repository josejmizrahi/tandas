import Foundation

/// Roles a `Member` can hold inside a group. Stored as a jsonb array on
/// `group_members.roles`. A member can hold multiple roles simultaneously
/// (e.g. founder + member, treasurer + member, host + member).
public enum MemberRole: String, Codable, Sendable, Hashable, CaseIterable {
    /// Group creator — identity badge. Immutable for the group's life
    /// (post mig 00262 split from `admin`). Carries the founder default
    /// permission bundle which today is identical to `admin`'s bundle,
    /// but the two are conceptually separate: founder = identity,
    /// admin = capability.
    case founder

    /// Operational administrator — capability role (separated from
    /// `founder` in mig 00262). Bundle: modifyGovernance, modifyRules,
    /// modifyMembers, assignRoles, removeMember, voidFine, closeAppeal,
    /// createVotes. New groups seed founder+admin on the creator;
    /// older groups received the catalog entry via 00262 and the
    /// per-member backfill via mig 00289 (Sprint A).
    case admin

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
