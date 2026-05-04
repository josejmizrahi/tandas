import Foundation

/// Every event the platform may emit. The rule engine matches `Rule.trigger
/// .eventType` against this enum.
///
/// Cases marked **(V1)** have a TriggerEvaluator implementation in
/// `_shared/ruleEngine.ts`. Other cases are declared so the model stays
/// V4-ready; the engine ignores rules whose trigger is not implemented yet.
public enum SystemEventType: String, Codable, Sendable, Hashable, CaseIterable {

    // MARK: - Event resource lifecycle

    /// (V1) Host pressed "Cerrar evento" — fires `evaluate-event-rules`
    /// immediately so proposed fines appear without cron lag.
    case eventClosed             = "eventClosed"
    /// Event was created. Not used by V1 rules but emitted on every create
    /// so analytics + future rules can hook in.
    case eventCreated            = "eventCreated"
    /// (V1) RSVP deadline passed — synthetic, scheduled by cron.
    case rsvpDeadlinePassed      = "rsvpDeadlinePassed"
    /// (V1) Synthetic — emitted by the cron N hours before an event starts,
    /// so rules like "host sin menú" can check at -24h.
    case hoursBeforeEvent        = "hoursBeforeEvent"

    // MARK: - RSVP / attendance

    /// (V1) Member submitted or updated their RSVP.
    case rsvpSubmitted           = "rsvpSubmitted"
    /// (V1) Member changed their RSVP after it became "same-day".
    case rsvpChangedSameDay      = "rsvpChangedSameDay"
    /// (V1) Someone arrived (host or self check-in).
    case checkInRecorded         = "checkInRecorded"
    /// Confirmed-going member never checked in — synthetic, computed at
    /// event close time. V1 handles via `eventClosed` + `checkInExists=false`
    /// condition; this case exists for future rules that want a dedicated
    /// trigger.
    case checkInMissed           = "checkInMissed"
    /// Host hasn't filled in the event description/menú yet. Used by the
    /// optional V1 rule "Anfitrión sin menú" (default OFF).
    case eventDescriptionMissing = "eventDescriptionMissing"

    // MARK: - Slot resource (Fase 2)

    case slotAssigned            = "slotAssigned"
    case slotDeclined            = "slotDeclined"
    case slotExpired             = "slotExpired"

    // MARK: - Fines + appeals

    case fineOfficialized        = "fineOfficialized"
    case finePaid                = "finePaid"
    case appealCreated           = "appealCreated"
    case appealResolved          = "appealResolved"
    case voteCast                = "voteCast"

    // MARK: - Fund (Fase posterior)

    case fundDeposit             = "fundDeposit"
    case fundThresholdReached    = "fundThresholdReached"

    // MARK: - Rotation / membership

    case positionChanged         = "positionChanged"
    case memberJoined            = "memberJoined"
    case memberLeft              = "memberLeft"

    /// True if Sprint 1a / V1 has a TriggerEvaluator implementation.
    public var isImplementedInV1: Bool {
        switch self {
        case .eventClosed, .checkInRecorded, .rsvpChangedSameDay,
             .hoursBeforeEvent, .rsvpSubmitted, .rsvpDeadlinePassed,
             .eventDescriptionMissing,
             .appealCreated, .appealResolved, .voteCast,
             .fineOfficialized, .finePaid,
             .eventCreated, .memberJoined, .memberLeft:
            return true
        case .checkInMissed,
             .slotAssigned, .slotDeclined, .slotExpired,
             .fundDeposit, .fundThresholdReached,
             .positionChanged:
            return false
        }
    }
}
