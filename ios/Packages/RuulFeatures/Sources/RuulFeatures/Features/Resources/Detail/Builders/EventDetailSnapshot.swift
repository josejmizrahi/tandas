import Foundation
import RuulCore

// MARK: - RotationSnapshotInput

/// Value-type carrier for rotation capability state passed into
/// `EventBlockBuilder`. Assembled by `EventDetailHost` from
/// `resource_series.metadata.capability_configs.rotation` (mig 00336).
///
/// Builders are pure: they receive this already-decoded struct so they
/// don't need an async call inside `build(source:viewer:now:)`.
public struct RotationSnapshotInput: Sendable, Hashable {
    /// Ordered participant user-ids (UUIDs from the series rotation config).
    public let participants: [UUID]
    /// Rotation order strategy ("sequential" or "random"). Determines
    /// which formula the builder applies to pick the next host.
    public let order: String
    /// Behaviour when the nominated host can't attend.
    public let replacementPolicy: String
    /// Cycle-offset introduced in mig 00336. Shifts the rotation cursor
    /// so groups can start from a specific participant without resetting
    /// the cycle number. Defaults to 0 for pre-mig configs.
    public let cycleOffset: Int

    public init(
        participants: [UUID],
        order: String = "sequential",
        replacementPolicy: String = "skip_to_next",
        cycleOffset: Int = 0
    ) {
        self.participants = participants
        self.order = order
        self.replacementPolicy = replacementPolicy
        self.cycleOffset = cycleOffset
    }
}

// MARK: - EventDetailSnapshot

/// Thin host-assembled value type combining all data `EventBlockBuilder`
/// needs to produce a `ResourceBlocks` tree without performing async I/O.
///
/// The host (`EventDetailHost`) assembles this struct from:
///   - `EventInteractor.event` — the live event row
///   - `EventInteractor.myRSVP` — the viewer's RSVP record
///   - `RotationSnapshotInput` — decoded from `resource_series.metadata`
///   - `memberDirectory` — loaded by the outer detail page
///
/// Builders are pure; keeping I/O out of them is a Phase D doctrinal
/// requirement. Hosts re-run the builder when the underlying entity
/// mutates (via `.onChange(of:)`) and push fresh `ResourceBlocks` to
/// the view.
public struct EventDetailSnapshot: Sendable, Hashable {
    /// Full live event row from `EventInteractor.event`.
    public let event: Event
    /// Viewer's RSVP record; nil means the viewer hasn't responded.
    public let myRSVP: RSVP?
    /// Rotation config decoded from `resource_series`. nil when the
    /// event has no series, or the series has no rotation cap_config.
    public let rotationConfig: RotationSnapshotInput?
    /// Total cycle number for this event occurrence. Used with
    /// `rotationConfig.cycleOffset` to resolve the next-host index.
    /// Mirrors `events.cycle_number`; nil for one-off events.
    public let cycleNumber: Int?
    /// Pre-loaded member directory — UUID → displayable member+profile.
    /// Builder resolves participant names at build time to avoid async
    /// calls in a pure transformation.
    public let memberDirectory: [UUID: MemberWithProfile]
    /// True when the viewer's `auth.users.id` matches the event's
    /// `host_id`. Avoids passing userId into the builder so it stays
    /// a pure function of the snapshot.
    public let viewerIsHost: Bool

    public init(
        event: Event,
        myRSVP: RSVP?,
        rotationConfig: RotationSnapshotInput?,
        cycleNumber: Int?,
        memberDirectory: [UUID: MemberWithProfile],
        viewerIsHost: Bool
    ) {
        self.event = event
        self.myRSVP = myRSVP
        self.rotationConfig = rotationConfig
        self.cycleNumber = cycleNumber
        self.memberDirectory = memberDirectory
        self.viewerIsHost = viewerIsHost
    }
}
