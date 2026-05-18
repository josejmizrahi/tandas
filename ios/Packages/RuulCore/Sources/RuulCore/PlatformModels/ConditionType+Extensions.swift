import Foundation

public extension ConditionType {
    public var isImplementedInV1: Bool {
        switch self {
        case .alwaysTrue, .responseStatusIs, .checkInExists,
             .checkInMinutesLate, .eventDescriptionMissing,
             .amountAbove,
             .damageAmountAbove, .transferAmountAbove,
             // Space rule conditions — evaluators landed in PR-3 of
             // SpaceRules roadmap (engine update mig 00268 + edge
             // function process-system-events redeploy).
             .cancelledWithinHours, .outsideAllowedHours,
             .actorHasRole, .actorHasPermission, .bookingDurationAbove,
             .damageSeverityAbove:
            return true
        case .minutesAfterScheduled, .hoursBeforeEvent,
             .memberHasMultipleFines, .memberFinesAbove,
             .memberMissedConsecutive, .eventDayOfWeek,
             .eventTimeWindow, .fundBalanceAbove,
             .fundBalanceBelow, .rotationPositionEquals,
             .slotIsUnassigned, .slotExpiresInHours,
             .daysBeforeExpiry:
            return false
        case .unknown:
            return false
        }
    }
}
