import Foundation

public extension SystemEventType {
    /// True if Sprint 1a / V1 has a TriggerEvaluator implementation.
    var isImplementedInV1: Bool {
        switch self {
        case .eventClosed, .checkInRecorded, .rsvpChangedSameDay,
             .hoursBeforeEvent, .rsvpSubmitted, .rsvpDeadlinePassed,
             .eventDescriptionMissing,
             .appealCreated, .appealResolved,
             .voteOpened, .voteCast, .voteResolved,
             .fineOfficialized, .fineVoided, .finePaid, .fineReminderSent,
             .eventCreated, .memberJoined, .memberLeft:
            return true
        case .checkInMissed,
             .slotAssigned, .slotDeclined, .slotExpired,
             .slotSwapRequested, .slotSwapApproved,
             .bookingCreated, .bookingCancelled, .bookingExpired,
             .assetCreated,
             .fundDeposit, .fundThresholdReached,
             .positionChanged,
             .ruleEnabledChanged, .ruleAmountChanged,
             .pendingChangeApplied:
            return false
        case .unknown:
            return false
        }
    }
}
