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

    // MARK: - Slot resource (Fase 2)
    case slotAssigned
    case slotDeclined
    case slotExpired

    // MARK: - Fines + appeals
    case fineOfficialized
    case finePaid
    case fineReminderSent
    case appealCreated
    case appealResolved
    case voteOpened
    case voteCast
    case voteResolved

    // MARK: - Fund (Fase posterior)
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

    case unknown(String)
}
