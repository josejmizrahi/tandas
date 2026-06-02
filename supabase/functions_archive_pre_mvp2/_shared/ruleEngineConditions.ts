// Condition evaluators — split out from ruleEngine.ts for readability
// (mig governance-review item #2). The engine remains a thin
// orchestrator; the registry below is the source of truth for every
// supported ConditionType.
//
// Adding a new condition: implement the ConditionEvaluator function,
// register it in CONDITIONS keyed by the matching ConditionType enum
// case, and (if it's reserved for a future phase) drop the case from
// CONDITION_PHASE in ruleEngine.ts so the "not implemented" warn stops
// firing.

import type {
  ConditionType,
  RuleCondition,
  RuleTarget,
} from "./platformTypes.ts";
import type { RSVPLike, RuleContext } from "./ruleEngine.ts";

export type ConditionEvaluator = (
  condition: RuleCondition,
  target: RuleTarget,
  context: RuleContext,
) => Promise<boolean>;

export const CONDITIONS: Partial<Record<ConditionType, ConditionEvaluator>> = {
  alwaysTrue: async () => true,

  // (V1) target.context.rsvp.status === config.status
  responseStatusIs: async (cond, target) => {
    const expected = cond.config.status as string | undefined;
    const rsvp = target.context.rsvp as RSVPLike | null | undefined;
    if (!expected) return false;
    return (rsvp?.status ?? "pending") === expected;
  },

  // (V1) Whether a check-in row exists for the target member.
  checkInExists: async (cond, target) => {
    const expected = cond.config.exists as boolean | undefined;
    const present = target.context.check_in != null;
    return expected ? present : !present;
  },

  // (V1) target.context.minutes_late >= config.thresholdMinutes
  checkInMinutesLate: async (cond, target) => {
    const threshold = (cond.config.thresholdMinutes as number | undefined) ?? 0;
    const lateMinutes = (target.context.minutes_late as number | null | undefined) ?? -1;
    return lateMinutes >= threshold;
  },

  // (mig 00193) target.context.amount_cents > config.threshold_cents.
  // Strict inequality so a rule with threshold 200000 fires on 200001 cents
  // but not on exactly 200000. Used by the `expense_threshold_warning`
  // template.
  amountAbove: async (cond, target) => {
    const threshold = (cond.config.threshold_cents as number | undefined) ?? 0;
    const amount = (target.context.amount_cents as number | null | undefined) ?? 0;
    return amount > threshold;
  },

  // (V1) Used by "anfitrión sin menú" rule.
  eventDescriptionMissing: async (_cond, target) => {
    const description = target.context.description as string | null | undefined;
    return !description || description.trim().length === 0;
  },

  // (Phase 2) Slot has no booking attached. Used by `shared_no_show`:
  // fires after slotExpired to fine the assigned holder when nobody used
  // their cupo. Reads `resources.metadata.booking_id` polymorphically —
  // the slot resource carries the booking attachment in its metadata.
  // Falls back to target.context.booking_id if the trigger evaluator
  // already projected it (avoids re-reading when caller has the value).
  slotIsUnassigned: async (_cond, target, context) => {
    const fromTarget = target.context.booking_id;
    if (fromTarget !== undefined) return fromTarget == null;
    if (!context.resource) return false;
    const bookingId = context.resource.metadata.booking_id;
    return bookingId == null;
  },

  // (Phase 2) Slot is within X hours of expiring. "Expires" =
  // `metadata.starts_at` (when the right-of-use lapses for the assigned
  // holder). Config: `{ "hours": 24 }` — true when 0 < hoursUntilExpiry
  // <= hours. Negative deltas (slot already started) return false so the
  // condition behaves as a forward-looking warning gate.
  slotExpiresInHours: async (cond, _target, context) => {
    if (!context.resource) return false;
    const hours = (cond.config.hours as number | undefined) ?? 24;
    const startsAt = context.resource.metadata.starts_at as string | undefined;
    if (!startsAt) return false;
    const expiresAtMs = new Date(startsAt).getTime();
    if (Number.isNaN(expiresAtMs)) return false;
    const hoursUntilExpiry = (expiresAtMs - context.now.getTime()) / 3_600_000;
    return hoursUntilExpiry > 0 && hoursUntilExpiry <= hours;
  },

  // (mig 00203) target.context.days_until_expiry <= config.days_before.
  // Used by the `right_expiration_warning` template to gate the warning
  // to the final N days of the cron's broader window (cron fires at
  // 14 days; default template threshold = 7). Falls back to the
  // resource's metadata.expires_at if the trigger evaluator didn't
  // project days_until_expiry (defensive — shouldn't happen with the
  // mig 00203 cron, but keeps the evaluator usable for hand-emitted
  // rightExpiringSoon events).
  daysBeforeExpiry: async (cond, target, context) => {
    const threshold = (cond.config.days_before as number | undefined) ?? 7;
    const projected = target.context.days_until_expiry as number | null | undefined;
    if (typeof projected === "number") {
      return projected <= threshold;
    }
    const expiresAt = context.resource?.metadata.expires_at as string | undefined;
    if (!expiresAt) return false;
    const expiresAtMs = new Date(expiresAt).getTime();
    if (Number.isNaN(expiresAtMs)) return false;
    const daysUntilExpiry = (expiresAtMs - context.now.getTime()) / 86_400_000;
    return daysUntilExpiry > 0 && daysUntilExpiry <= threshold;
  },

  // (mig 00226, AssetRules.md §4.2) Mirrors amountAbove but reads the
  // damageReported payload key (estimated_cost_cents) instead of
  // ledger_entry amount_cents. Strict > so a threshold of 500000 fires
  // on 500001 cents but not on exactly 500000.
  damageAmountAbove: async (cond, target) => {
    const threshold = (cond.config.threshold_cents as number | undefined) ?? 0;
    const cost = (target.context.estimated_cost_cents as number | null | undefined) ?? 0;
    return cost > threshold;
  },

  // (mig 00226, AssetRules.md §4.2) Reads the projected valuation_cents
  // from target.context (the assetTransferred trigger evaluator
  // populated it via sink.latestAssetValuationCents). Returns false
  // when no valuation is recorded — the rule short-circuits so an
  // un-valued asset doesn't fire transfer-large rules.
  transferAmountAbove: async (cond, target) => {
    const threshold = (cond.config.threshold_cents as number | undefined) ?? 0;
    const valuation = target.context.valuation_cents as number | null | undefined;
    if (typeof valuation !== "number") return false;
    return valuation > threshold;
  },

  // ===========================================================================
  // Space rule conditions (mig 00268, Plans/Active/SpaceRules.md §3.2)
  // ===========================================================================

  // (PR-3) True when the cancellation occurred within `hours` of the
  // booking's `starts_at`. Reads target.context.cancelled_at (atom's
  // occurred_at) vs booking_starts_at (projected by bookingCancelled
  // trigger). Returns false when starts_at is unknown (atom was
  // emitted on a deleted booking, etc.) — open-ended bookings can't
  // be "late cancellations" by definition.
  cancelledWithinHours: async (cond, target) => {
    const hours = (cond.config.hours as number | undefined) ?? 24;
    const startsAtRaw = target.context.booking_starts_at as string | null | undefined;
    const cancelledAtRaw = target.context.cancelled_at as string | null | undefined;
    if (!startsAtRaw || !cancelledAtRaw) return false;
    const startsMs = new Date(startsAtRaw).getTime();
    const cancelledMs = new Date(cancelledAtRaw).getTime();
    if (Number.isNaN(startsMs) || Number.isNaN(cancelledMs)) return false;
    // Cancellation must be BEFORE the booking start (cancelling after
    // start isn't "late cancellation" — it's a no-show, different rule).
    const hoursBeforeStart = (startsMs - cancelledMs) / 3_600_000;
    return hoursBeforeStart > 0 && hoursBeforeStart < hours;
  },

  // (PR-3) True when the booking's start_at hour falls outside
  // `[start_hour, end_hour)`. Reads target.context.booking_starts_at;
  // returns false when missing. Hour comparison runs in UTC — the cron
  // and the booker share the resource's timezone is a Phase 4 follow-up
  // (today we approximate with UTC; matches the rest of the engine).
  outsideAllowedHours: async (cond, target) => {
    const startHour = (cond.config.start_hour as number | undefined) ?? 8;
    const endHour   = (cond.config.end_hour   as number | undefined) ?? 22;
    const startsAtRaw = target.context.booking_starts_at as string | null | undefined;
    if (!startsAtRaw) return false;
    const d = new Date(startsAtRaw);
    if (Number.isNaN(d.getTime())) return false;
    const hour = d.getUTCHours();
    return hour < startHour || hour >= endHour;
  },

  // (PR-3) True when the actor (target.member_id) carries the configured
  // role. Reads target.context.actor_roles projected from
  // group_members.roles by the spaceWaitlistJoined trigger. Returns
  // false when actor_roles isn't projected (defensive — shouldn't
  // happen with PR-3 triggers but keeps the condition usable for hand-
  // emitted atoms).
  //
  // V7 doctrine: this condition is label-only — it doesn't consult the
  // permission catalog. Prefer `actorHasPermission` for new rules that
  // gate on a specific capability (modifyGovernance, transferRight,
  // etc.). `actorHasRole` stays for rules that care about role identity
  // (e.g. "Founder gets priority bump in waitlist") rather than
  // capability — those are still legitimate scenarios.
  actorHasRole: async (cond, target) => {
    const role = cond.config.role as string | undefined;
    if (!role) return false;
    const roles = target.context.actor_roles as string[] | null | undefined;
    if (!Array.isArray(roles)) return false;
    return roles.includes(role);
  },

  // (V7) True when the actor (target.member_id) holds a role that grants
  // the configured permission. Reads target.context.actor_permissions
  // projected from list_member_permissions(member_id) by the trigger.
  // Doctrinal alternative to actorHasRole for capability-based gates
  // — respects role/permission separation. Returns false when
  // actor_permissions isn't projected.
  actorHasPermission: async (cond, target) => {
    const permission = cond.config.permission as string | undefined;
    if (!permission) return false;
    const perms = target.context.actor_permissions as string[] | null | undefined;
    if (!Array.isArray(perms)) return false;
    return perms.includes(permission);
  },

  // (PR-3) True when target.context.booking_duration_minutes >
  // config.minutes. The bookingCreated trigger projects the duration
  // from starts_at/ends_at. Open-ended bookings (no ends_at) return
  // false — duration is undefined, the rule short-circuits.
  bookingDurationAbove: async (cond, target) => {
    const threshold = (cond.config.minutes as number | undefined) ?? 0;
    const duration = target.context.booking_duration_minutes as number | null | undefined;
    if (typeof duration !== "number") return false;
    return duration > threshold;
  },

  // (PR-3) True when severity >= configured level. Reads
  // target.context.severity (projected by damageReported trigger,
  // mig 00226). Ordering: minor < moderate < major < total. Reused
  // across space + asset rule shapes (same atom, same semantic).
  damageSeverityAbove: async (cond, target) => {
    const level = (cond.config.level as string | undefined) ?? "major";
    const sev = target.context.severity as string | null | undefined;
    if (!sev) return false;
    const order: Record<string, number> = { minor: 1, moderate: 2, major: 3, total: 4 };
    const sevRank = order[sev] ?? 0;
    const thresholdRank = order[level] ?? 0;
    return sevRank >= thresholdRank;
  },
};
