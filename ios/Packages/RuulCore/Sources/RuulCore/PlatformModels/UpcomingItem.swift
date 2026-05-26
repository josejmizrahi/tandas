import Foundation

/// Polymorphic "thing-in-time" surfaced by the situational stream's
/// "Próximo" cluster.
///
/// The 5-cluster doctrine (`doctrine_group_space_situational`) defines
/// each cluster as a *situation*, not a resource type. Pre-2026-05-25
/// the Próximo cluster was hardcoded to `[Event]` — a scalability
/// bottleneck as V1 expanded to slot/asset/space/right.
///
/// This enum lets the cluster absorb any time-anchored source without
/// changing position or name. Each case carries the typed projection
/// the row needs to render; the coordinator merges sources and sorts
/// by `occursAt`.
///
/// V1 cases (wired today):
///   - `.event` — upcoming Event via EventRepository
///   - `.voteClosing` — open Vote whose `closesAt` is imminent
///   - `.slotRotation` — Slot whose `startsAt` is in the future
///
/// Deferred cases (blocked on backend):
///   - `.spaceBooking` — needs new BookingRepository method
///   - `.fineGraceDeadline` — needs `fine_review_periods.expires_at`
///     exposed in a view
///   - `.assetReturn` — needs `asset_checkout_view` with
///     `expected_return_at`
///   - `.recurrentEventNext` — needs next-instance RPC
///
/// Adding a new case = touching this file + one loader in the
/// coordinator + one branch in the cluster row renderer. No
/// architectural rewiring per type.
public enum UpcomingItem: Identifiable, Sendable, Hashable {
    case event(Event)
    case voteClosing(Vote)
    case slotRotation(slot: Slot, holderName: String?, assetName: String?)

    /// Stable identity for `ForEach`. The discriminator prefix prevents
    /// collisions if two different sources happen to share a UUID.
    public var id: String {
        switch self {
        case .event(let e):
            return "event:\(e.id.uuidString)"
        case .voteClosing(let v):
            return "vote:\(v.id.uuidString)"
        case .slotRotation(let s, _, _):
            return "slot:\(s.id.uuidString)"
        }
    }

    /// Time anchor — used by the coordinator to merge-sort heterogeneous
    /// upcoming items into one timeline ordered ascending.
    public var occursAt: Date {
        switch self {
        case .event(let e):           return e.startsAt
        case .voteClosing(let v):     return v.closesAt
        case .slotRotation(let s, _, _): return s.startsAt
        }
    }
}
