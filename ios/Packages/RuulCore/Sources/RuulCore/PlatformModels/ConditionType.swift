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

    // MARK: - Right (mig 00203, right_expiration_warning template)

    /// (Phase 2) Right expires within N days. Reads
    /// `target.context.days_until_expiry` projected by the
    /// `rightExpiringSoon` trigger evaluator (mig 00203 cron),
    /// or falls back to `context.resource.metadata.expires_at`.
    /// Config: `{ "days_before": 7 }` — true when
    /// `0 < daysUntilExpiry <= days_before`.
    case daysBeforeExpiry

    // MARK: - Money (mig 00193, expense_threshold_warning pilot)

    /// True when the target's ledger amount (cents) exceeds the configured
    /// threshold. Config: `{ "threshold_cents": 200000 }` (= $2000 MXN).
    /// Reads `target.context.amount_cents` populated by the
    /// `ledgerEntryCreated` trigger evaluator.
    case amountAbove

    /// True when `target.context.estimated_cost_cents` exceeds the
    /// configured threshold. Drives the `damage_approval_required` +
    /// `damage_logged_warning` templates (Plans/Active/AssetRules.md §3).
    /// Config: `{ "threshold_cents": 500000 }`.
    case damageAmountAbove

    /// True when `target.context.valuation_cents` exceeds the configured
    /// threshold. Reads the asset's latest `asset_valuation_view` value
    /// projected by the `assetTransferred` evaluator. Drives the
    /// `transfer_large_vote` template. Config: `{ "threshold_cents": 5000000 }`.
    case transferAmountAbove

    // MARK: - Space rule conditions (mig 00268 — SpaceRules.md §3.2)

    /// True when the cancellation occurs within `hours` of the booking's
    /// `starts_at`. Reads `target.context.booking_starts_at` projected by
    /// the `bookingCancelled` evaluator (PR-3). Drives the
    /// `space_cancellation_late_fine` template.
    /// Config: `{ "hours": 24 }`.
    case cancelledWithinHours

    /// True when the booking's `starts_at` hour falls outside the
    /// `[start_hour, end_hour)` window in the resource's timezone. Reads
    /// `target.context.booking_starts_at`. Drives the
    /// `space_outside_allowed_hours_deny` template.
    /// Config: `{ "start_hour": 8, "end_hour": 22 }` (24h clock).
    case outsideAllowedHours

    /// True when the actor (member that fired the trigger) carries the
    /// configured role. Reads `target.context.actor_roles` projected from
    /// `group_members.roles` jsonb. Drives the
    /// `space_founder_priority_bump` template.
    /// Config: `{ "role": "founder" }`.
    ///
    /// V7 doctrine: label-only check — does NOT consult the permission
    /// catalog. Prefer `actorHasPermission` for capability-based gates.
    /// `actorHasRole` stays for rules that care about role identity
    /// rather than capability.
    case actorHasRole

    /// True when the actor (target.member_id) holds at least one role
    /// granting the configured permission. Reads
    /// `target.context.actor_permissions` projected by the trigger via
    /// `list_member_permissions(member_id)` (mig 00300). Doctrinal
    /// counterpart to `actorHasRole` — respects role/permission
    /// separation. Config: `{ "permission": "modifyGovernance" }`.
    case actorHasPermission

    /// True when the booking's `ends_at - starts_at` exceeds the
    /// configured minutes. Reads `target.context.booking_duration_minutes`.
    /// Drives the `space_long_booking_vote` template.
    /// Config: `{ "minutes": 120 }`.
    case bookingDurationAbove

    /// True when the damage atom's severity is at or above the configured
    /// level (minor < moderate < major < total). Reads
    /// `target.context.severity`. Drives the
    /// `space_damage_temporary_closure_vote` template (and reused by
    /// asset variants). Config: `{ "level": "major" }`.
    case damageSeverityAbove

    case unknown(String)
}
