import Foundation

extension ConditionType {
    public var isImplementedInV1: Bool {
        switch self {
        case .alwaysTrue, .responseStatusIs, .checkInExists,
             .checkInMinutesLate, .eventDescriptionMissing:
            return true
        case .minutesAfterScheduled, .hoursBeforeEvent,
             .memberHasMultipleFines, .memberFinesAbove,
             .memberMissedConsecutive, .eventDayOfWeek,
             .eventTimeWindow, .fundBalanceAbove,
             .fundBalanceBelow, .rotationPositionEquals:
            return false
        case .unknown:
            return false
        }
    }
}
