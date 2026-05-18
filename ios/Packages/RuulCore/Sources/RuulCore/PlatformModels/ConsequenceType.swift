import Foundation

/// Every consequence the rule engine can execute when a rule's conditions
/// match. Rules can chain multiple consequences (all execute).
///
/// Cases marked **(V1)** have a ConsequenceExecutor implementation in
/// `_shared/ruleEngine.ts`. Other cases throw `NotImplementedError`; rules
/// using them are skipped with a structured log line so the architecture
/// stays V4-ready without silently failing in production.
// @codegen:enum
public enum ConsequenceType: Codable, Sendable, Hashable {

    // MARK: - V1 (only `fine` is implemented)

    /// (V1) Create a row in `fines` table with status `proposed`. The
    /// fine_review_periods row gives host 24h to review before auto-
    /// officializing.
    /// Config (flat fee): `{ "amount": 200 }`
    /// Config (escalating): `{ "baseAmount": 200, "stepAmount": 50, "stepMinutes": 30 }`
    case fine

    // MARK: - Reserved for future phases

    case loseTurn
    case losePriority
    case serviceCompensation
    case blockTemporary
    case reciprocity
    case logOnly
    case sumPoints
    case subtractPoints
    case sendNotification
    case startVote
    case createEvent
    case assignSlot
    case transferRight
    case callWebhook

    // MARK: - Money / Governance (mig 00193, expense_threshold_warning pilot)

    /// Emits a `warningEmitted` system_event scoped to the rule's target.
    /// Surfaces in the activity feed; visible to admins via rule_evaluations.
    /// No money, no vote — pure visibility signal. Per Governance.md §5.1.
    case emitWarning

    // MARK: - Right resource_type write-side (mig 00200)

    /// Sets a right's status to `revoked` via the canonical `revoke_right`
    /// RPC. The right resource must be of resource_type='right'; the rule's
    /// trigger SHOULD have fired on a right atom (rightExpired, repeated
    /// rightSuspended, etc.). Config: `{ "reason": "…" }` — optional;
    /// the rule's name is used when omitted. Service_role-safe (mig 00200).
    case revokeRight
    /// Sets `metadata.suspended_until` on a right via `suspend_right` RPC.
    /// Same target shape as `revokeRight`. Config: `{ "until": "<iso>",
    /// "reason": "…" }` — both optional.
    case suspendRight

    // MARK: - Asset rule consequences (mig 00226 — AssetRules.md §3.3)

    /// Inserts a `user_actions` row of type `assetActionApproval` for
    /// the asset's group admins. UI surfaces it in the Inbox; an admin
    /// reviews and resolves manually in V1. Idempotent on (rule_id,
    /// resource_id, source_atom_id) — re-running the rule doesn't
    /// double-create the inbox row. Config: `{}` — none today.
    case requireApproval

    /// Flips `resources.metadata.bookings_locked = true` on the asset
    /// and emits a `warningEmitted` audit atom referencing the rule.
    /// Soft policy per Constitution §9 — doesn't block the booking RPC,
    /// rules + UI react to the flag. Idempotent: re-firing on an
    /// already-locked asset is a no-op. Config: `{}` — none today.
    case lockBookings

    // MARK: - Space rule consequences (mig 00268 — SpaceRules.md §3.3)

    /// Calls `expire_booking(booking_id, reason)` to terminate the
    /// active booking that triggered the rule. Emits `bookingExpired`
    /// + (when target is a space) `spaceReleased`. Drives the
    /// `space_no_check_in_release` template — auto-frees a booking
    /// when nobody checked in within the grace window.
    /// Config: `{ "reason": "no_check_in" }`.
    case releaseBooking

    /// Soft block per TalmudicGovernance §4.G — instead of silently
    /// swallowing the triggering action, returns an explicit error to
    /// the caller via `target.context.deny_message`. Used by
    /// `space_outside_allowed_hours_deny` to surface "fuera de horario"
    /// errors that the UI captures and shows to the user. The action's
    /// atom does NOT get rolled back (atom is truth) — denyAction
    /// fires AFTER the trigger and registers the rejection as a
    /// `warningEmitted` companion atom for audit.
    /// Config: `{ "message_es": "Esta acción no está permitida" }`.
    case denyAction

    /// Modifies the `priority` payload of the next `spaceWaitlistJoined`
    /// row for the actor by `priority_delta`. Drives the
    /// `space_founder_priority_bump` template — gives founders +100
    /// priority so they jump the waitlist. Idempotent: re-applying the
    /// same bump on the same atom is a no-op (engine tracks
    /// `metadata.priority_bumped_by` to avoid double-counting).
    /// Config: `{ "priority_delta": 100 }`.
    case bumpPriority

    case unknown(String)
}
