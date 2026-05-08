import Foundation

/// Generic platform resource — anything a group interacts with.
///
/// V1 implementations:
/// - `Event` (via the `Event+Resource` extension; lives in the `events` table)
/// - `ResourceRow` (concrete envelope reading directly from the `resources` table)
///
/// V2+ types — declared in `ResourceType` (slot/fund/position/asset/contribution)
/// — wear this protocol via either an `Event`-style domain struct + extension
/// or as `ResourceRow` envelopes when they have no per-type Swift home yet.
///
/// **Why not Codable on the protocol?** `Event` has its own bespoke wire shape
/// (flat columns mapping to `events`); `ResourceRow` has the polymorphic shape
/// (flat columns + `metadata` jsonb mapping to `resources`). They round-trip to
/// different SQL tables and a single Codable witness would fight both. Concrete
/// types stay Codable; the protocol is the abstract shape only.
///
/// **Why `resourceStatus: String` instead of `status: String`?** Concrete types
/// like `Event` already declare `status: EventStatus` (typed enum). Adding a
/// computed `status: String` via extension creates a name conflict with the
/// stored property. The protocol uses `resourceStatus` to sidestep the clash;
/// `Event` exposes both `status: EventStatus` (typed, primary) and
/// `resourceStatus: String` (bridge). `ResourceRow` exposes both as well —
/// `status: String` reads the column directly and `resourceStatus` aliases it.
public protocol Resource: Identifiable, Sendable {
    var id: UUID { get }
    var groupId: UUID { get }
    var resourceType: ResourceType { get }
    /// Free-form status string. Per-type enums (e.g. `EventStatus`) bridge via rawValue.
    var resourceStatus: String { get }
    var createdAt: Date { get }
    var updatedAt: Date { get }
}
