import Foundation

public extension ConditionType {
    public var isImplementedInV1: Bool {
        switch self {
        case .alwaysTrue, .responseStatusIs, .checkInExists,
             .checkInMinutesLate, .eventDescriptionMissing,
             .amountAbove,
             .damageAmountAbove, .transferAmountAbove:
            return true
        case .minutesAfterScheduled, .hoursBeforeEvent,
             .memberHasMultipleFines, .memberFinesAbove,
             .memberMissedConsecutive, .eventDayOfWeek,
             .eventTimeWindow, .fundBalanceAbove,
             .fundBalanceBelow, .rotationPositionEquals,
             .slotIsUnassigned, .slotExpiresInHours,
             .daysBeforeExpiry,
             // Space rule conditions — shapes in catalog (mig 00268)
             // but evaluators land in PR-3 of SpaceRules roadmap.
             .cancelledWithinHours, .outsideAllowedHours,
             .actorHasRole, .bookingDurationAbove,
             .damageSeverityAbove:
            return false
        case .unknown:
            return false
        }
    }
}
