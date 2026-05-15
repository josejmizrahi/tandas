import Foundation

/// Every condition the rule engine knows how to evaluate. Rules combine
/// multiple conditions with AND.
///
/// Cases marked **(V1)** have a ConditionEvaluator implementation in
/// `_shared/ruleEngine.ts`. Other cases throw `NotImplementedError` server-
/// side; rules using them are skipped with a structured log line.
// @codegen:enum
public enum ConditionType: Codable, Sendable, Hashable {

    // MARK: - V1 conditions (used by template "Cena recurrente")

    /// (V1) Always true. Used when a rule has no preconditions.
    case alwaysTrue
    /// (V1) Member RSVP equals a configured status.
    /// Config: `{ "status": "pending" | "going" | "maybe" | "declined" | "waitlisted" }`
    case responseStatusIs
    /// (V1) A check-in row exists / does not exist for the member.
    /// Config: `{ "exists": true | false }`
    case checkInExists
    /// (V1) Minutes late at check-in vs the event start time.
    /// Config: `{ "thresholdMinutes": Int }` — true when `lateMinutes >= threshold`.
    case checkInMinutesLate
    /// (V1) Event description / menú is empty.
    case eventDescriptionMissing

    // MARK: - Time-based

    /// X minutes after the event's scheduled start time.
    case minutesAfterScheduled
    /// X hours before the event starts. Used as a synthetic trigger config
    /// rather than a condition in V1.
    case hoursBeforeEvent

    // MARK: - Member history (Fase posterior)

    case memberHasMultipleFines
    case memberFinesAbove
    case memberMissedConsecutive

    // MARK: - Event meta

    case eventDayOfWeek
    case eventTimeWindow

    // MARK: - Fund (Fase posterior)

    case fundBalanceAbove
    case fundBalanceBelow

    // MARK: - Rotation

    case rotationPositionEquals

    // MARK: - Slot / Asset / Booking (Fase 2 — shared_resource)

    /// (Phase 2) Slot has no booking attached. Drives auto-assign rules.
    case slotIsUnassigned
    /// (Phase 2) Slot starts within X hours from now.
    /// Config: `{ "hours": 24 }`
    case slotExpiresInHours

    // MARK: - Money (mig 00193, expense_threshold_warning pilot)

    /// True when the target's ledger amount (cents) exceeds the configured
    /// threshold. Config: `{ "threshold_cents": 200000 }` (= $2000 MXN).
    /// Reads `target.context.amount_cents` populated by the
    /// `ledgerEntryCreated` trigger evaluator.
    case amountAbove

    case unknown(String)
}
