import Foundation

/// Every event the platform may emit. The rule engine matches `Rule.trigger
/// .eventType` against this enum.
///
/// Cases marked **(V1)** have a TriggerEvaluator implementation in
/// `_shared/ruleEngine.ts`. Other cases are declared so the model stays
/// V4-ready; the engine ignores rules whose trigger is not implemented yet.
// @codegen:enum
public enum SystemEventType: Codable, Sendable, Hashable {

    // MARK: - Event resource lifecycle
    case eventClosed
    case eventCreated
    case rsvpDeadlinePassed
    case hoursBeforeEvent

    // MARK: - RSVP / attendance
    case rsvpSubmitted
    case rsvpChangedSameDay
    case checkInRecorded
    case checkInMissed
    case eventDescriptionMissing

    // MARK: - Slot / Asset / Booking (Fase 2 — shared_resource)
    case slotAssigned
    case slotDeclined
    case slotExpired
    case slotSwapRequested
    case slotSwapApproved
    case bookingCreated
    case bookingCancelled
    case bookingExpired
    case assetCreated

    // MARK: - Fines + appeals
    case fineOfficialized
    case fineVoided
    case finePaid
    case fineReminderSent
    case appealCreated
    case appealResolved
    case voteOpened
    case voteCast
    case voteResolved

    // MARK: - Fund (Fase posterior)
    /// Emitted by `create_fund` (mig 00137) when a new fund resource
    /// lands. Lets ActivitySectionView surface "X creó el fondo Y" the
    /// same way assetCreated does for shared assets.
    case fundCreated
    case fundDeposit
    case fundThresholdReached

    // MARK: - Rotation / membership
    case positionChanged
    case memberJoined
    case memberLeft

    // MARK: - Rule mutations (audit only — not rule-engine triggers)
    /// Emitted when a rule is toggled on/off (UPDATE rules.enabled).
    case ruleEnabledChanged
    /// Emitted when a rule's fine amount is edited (UPDATE rules.action).
    case ruleAmountChanged

    // MARK: - Governance / pending changes (audit only)
    /// Emitted by `apply_pending_change` (mig 00089) after a vote
    /// resolves and the queued change has been applied. Lets subsequent
    /// invocations short-circuit and gives the audit trail a marker.
    case pendingChangeApplied

    case unknown(String)
}
