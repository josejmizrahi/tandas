import Foundation

/// Every condition the rule engine knows how to evaluate. Rules combine
/// multiple conditions with AND.
///
/// Cases marked **(V1)** have a ConditionEvaluator implementation in
/// `_shared/ruleEngine.ts`. Other cases throw `NotImplementedError` server-
/// side; rules using them are skipped with a structured log line.
public enum ConditionType: String, Codable, Sendable, Hashable, CaseIterable {

    // MARK: - V1 conditions (used by template "Cena recurrente")

    /// (V1) Always true. Used when a rule has no preconditions.
    case alwaysTrue              = "alwaysTrue"
    /// (V1) Member RSVP equals a configured status.
    /// Config: `{ "status": "pending" | "going" | "maybe" | "declined" | "waitlisted" }`
    case responseStatusIs        = "responseStatusIs"
    /// (V1) A check-in row exists / does not exist for the member.
    /// Config: `{ "exists": true | false }`
    case checkInExists           = "checkInExists"
    /// (V1) Minutes late at check-in vs the event start time.
    /// Config: `{ "thresholdMinutes": Int }` — true when `lateMinutes >= threshold`.
    case checkInMinutesLate      = "checkInMinutesLate"
    /// (V1) Event description / menú is empty.
    case eventDescriptionMissing = "eventDescriptionMissing"

    // MARK: - Time-based

    /// X minutes after the event's scheduled start time.
    case minutesAfterScheduled   = "minutesAfterScheduled"
    /// X hours before the event starts. Used as a synthetic trigger config
    /// rather than a condition in V1.
    case hoursBeforeEvent        = "hoursBeforeEvent"

    // MARK: - Member history (Fase posterior)

    case memberHasMultipleFines  = "memberHasMultipleFines"
    case memberFinesAbove        = "memberFinesAbove"
    case memberMissedConsecutive = "memberMissedConsecutive"

    // MARK: - Event meta

    case eventDayOfWeek          = "eventDayOfWeek"
    case eventTimeWindow         = "eventTimeWindow"

    // MARK: - Fund (Fase posterior)

    case fundBalanceAbove        = "fundBalanceAbove"
    case fundBalanceBelow        = "fundBalanceBelow"

    // MARK: - Rotation

    case rotationPositionEquals  = "rotationPositionEquals"

    public var isImplementedInV1: Bool {
        switch self {
        case .alwaysTrue, .responseStatusIs, .checkInExists,
             .checkInMinutesLate, .eventDescriptionMissing:
            return true
        default:
            return false
        }
    }
}
