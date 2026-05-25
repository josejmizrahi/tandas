import Foundation

/// Polymorphic "in use right now" projection for a group's persistent
/// resources. Sources (server-side):
///
/// - `asset_current_custodian_view` — assets currently held by a
///   custodian (mig 00201). Custody = persistent designated holder.
/// - `space_occupancy_view` — spaces with a member checked in (mig
///   00267). Occupancy = someone is currently there.
///
/// Slot in-use semantics are intentionally not surfaced here (the
/// existing slot status enum can't distinguish "claimed for a future
/// window" from "in use now" without joining bookings against current
/// time — the founder's rule "no heurísticas frágiles" applies).
///
/// Each projection carries enough to render an `InUseCluster` row
/// (icon by type + title + holder name + since-time) and to navigate
/// to the resource detail on tap.
public struct InUseProjection: Identifiable, Hashable, Sendable {
    /// The underlying `resources.id` — stable across asset/space.
    public let id: UUID
    public let groupId: UUID
    public let resourceType: ResourceType
    /// Human-readable name read from `resources.metadata.name`
    /// (or `.title` as fallback for V1 mirrored events).
    public let title: String
    /// `group_members.id` of the holder (custodian for assets, the
    /// currently-checked-in member for spaces).
    public let holderMemberId: UUID
    /// Timestamp from `assigned_at` (asset) / `checked_in_at` (space).
    public let since: Date

    public init(
        id: UUID,
        groupId: UUID,
        resourceType: ResourceType,
        title: String,
        holderMemberId: UUID,
        since: Date
    ) {
        self.id = id
        self.groupId = groupId
        self.resourceType = resourceType
        self.title = title
        self.holderMemberId = holderMemberId
        self.since = since
    }
}
