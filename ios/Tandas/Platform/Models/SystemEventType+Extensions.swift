import Foundation

extension SystemEventType {
    /// True if Sprint 1a / V1 has a TriggerEvaluator implementation.
    public var isImplementedInV1: Bool {
        switch self {
        case .eventClosed, .checkInRecorded, .rsvpChangedSameDay,
             .hoursBeforeEvent, .rsvpSubmitted, .rsvpDeadlinePassed,
             .eventDescriptionMissing,
             .appealCreated, .appealResolved,
             .voteOpened, .voteCast, .voteResolved,
             .fineOfficialized, .finePaid, .fineReminderSent,
             .eventCreated, .memberJoined, .memberLeft:
            return true
        case .checkInMissed,
             .slotAssigned, .slotDeclined, .slotExpired,
             .fundDeposit, .fundThresholdReached,
             .positionChanged,
             .ruleEnabledChanged, .ruleAmountChanged:
            return false
        case .unknown:
            return false
        }
    }
}
