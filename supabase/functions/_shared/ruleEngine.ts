// Rule engine — pure logic, no Supabase calls. The two callable functions
// (process-system-events + evaluate-event-rules) wire it to the database.
//
// Determinism contract:
//   - Evaluators read only from the `RuleContext` they're given.
//   - No Date.now() — time-sensitive logic uses `context.now`.
//   - Same inputs → same outputs. Easy to unit-test with fixtures.
//
// Sprint 1a implements 4 trigger evaluators (the ones used by the 5 default
// "Cena recurrente" rules), 5 condition evaluators, and 1 consequence
// executor (`fine`). Other types are scaffolded but throw NotImplementedError.

import {
  ConditionType,
  ConsequenceType,
  ExecutionResult,
  Rule,
  RuleCondition,
  RuleConsequence,
  RuleTarget,
  RuleTrigger,
  SystemEvent,
  SystemEventType,
  UUID,
} from "./platformTypes.ts";
import { logStructured } from "./log.ts";

// =============================================================================
// Reserved-type → phase_target mapping
//
// When the engine encounters a Trigger/Condition/Consequence it does not
// implement, it emits a structured warn log with `phase_target` so a future
// dev can distinguish "this feature is reserved for Fase X" from "this is a
// real bug". Phase semantics:
//
//   phase_2   → Recurso compartido template (palco/cabaña, slots, rotation)
//   phase_3   → Tanda template (rotating savings, fund balance)
//   phase_4   → Custom rule editor (advanced conditions/consequences)
//   unknown   → enum case has no phase plan; treat as bug
//
// Types absent from these tables resolve to "unknown" — the signal that
// someone added a SystemEventType / ConditionType / ConsequenceType case
// without slotting it into a roadmap phase.
// =============================================================================

const TRIGGER_PHASE: Partial<Record<SystemEventType, string>> = {
  // Phase 2: Recurso compartido
  slotAssigned: "phase_2",
  slotDeclined: "phase_2",
  // slotExpired evaluator implemented in Slice 2.2 — emit-slot-system-events
  // cron drives it. Falls through to "unknown" if absent from this map.
  positionChanged: "phase_2",
  checkInMissed: "phase_2",
  // Phase 3: Tanda
  fundDeposit: "phase_3",
  fundThresholdReached: "phase_3",
  // V1 emitters that no rule consumes today fall through to "unknown" —
  // intentional, so an authoring slip surfaces as a real signal.
};

const CONDITION_PHASE: Partial<Record<ConditionType, string>> = {
  // Phase 2: Recurso compartido
  rotationPositionEquals: "phase_2",
  // Phase 3: Tanda
  fundBalanceAbove: "phase_3",
  fundBalanceBelow: "phase_3",
  // Phase 4: Custom rule editor
  minutesAfterScheduled: "phase_4",
  memberHasMultipleFines: "phase_4",
  memberFinesAbove: "phase_4",
  memberMissedConsecutive: "phase_4",
  eventDayOfWeek: "phase_4",
  eventTimeWindow: "phase_4",
  // hoursBeforeEvent is a trigger config, not a standalone condition —
  // intentionally left out so an author using it as condition logs "unknown".
};

const CONSEQUENCE_PHASE: Partial<Record<ConsequenceType, string>> = {
  // Phase 2: Recurso compartido
  loseTurn: "phase_2",
  losePriority: "phase_2",
  assignSlot: "phase_2",
  transferRight: "phase_2",
  // Phase 4: Custom rule editor + advanced behaviors
  serviceCompensation: "phase_4",
  blockTemporary: "phase_4",
  reciprocity: "phase_4",
  sumPoints: "phase_4",
  subtractPoints: "phase_4",
  startVote: "phase_4",
  createEvent: "phase_4",
  callWebhook: "phase_4",
  // logOnly / sendNotification: intentionally "unknown" — V1.x utilities
  // without a formal phase home; surfacing them as unknown invites a
  // decision rather than silent gating.
};

// =============================================================================
// Engine context — what evaluators read + what executors mutate
// =============================================================================

/**
 * Database-shaped data the evaluators need. The cron function loads these
 * once per SystemEvent and reuses for all matching rules.
 */
export interface RuleContext {
  now: Date;
  /** All active members of the rule's group. */
  members: { id: UUID; user_id: UUID; active: boolean }[];
  /** The Resource (event / slot / etc.) this event affects, if any. */
  resource: ResourceLike | null;
  /** Per-member RSVP rows for the resource (if it's an event). */
  rsvps: RSVPLike[];
  /** Per-member check-in rows for the resource (if it's an event). */
  checkIns: CheckInLike[];
  /** Anti-tirania monthly cap context — fines this month per member. */
  finesThisMonthByMember: Map<UUID, number>;
  /** Hook to actually persist consequences. Pass-through to the function. */
  sink: ConsequenceSink;
}

export interface ResourceLike {
  id: UUID;
  group_id: UUID;
  resource_type: string;
  status: string;
  metadata: Record<string, unknown>;
  /**
   * The series this resource belongs to, if any (mig 00078 §4b). Used by
   * `runRulesForEvent` to honor series-scoped rules: a rule with `series_id`
   * set applies to every occurrence of that series. Null for one-off
   * resources (events with no `resource_series` parent).
   */
  series_id?: UUID | null;
}

export interface RSVPLike {
  member_user_id: UUID;
  status: "pending" | "going" | "maybe" | "declined" | "waitlisted";
  rsvp_at: string | null;
  cancelled_same_day: boolean;
}

export interface CheckInLike {
  member_user_id: UUID;
  arrived_at: string;
  /** Minutes late vs the event's starts_at. Negative if early. */
  minutes_late: number;
}

/**
 * Side-effect interface so the engine stays pure. The cron function passes a
 * Supabase-backed implementation; tests pass an in-memory recorder.
 *
 * `resource_id` is the polymorphic FK introduced by migration 00041 (audit
 * doc § 5.3 items 9+11). For V1 events `resource_id == event_id` (resources.id
 * mirrors events.id post-00040 backfill). For Phase 2 non-event resources
 * (slot decline, fund non-contribution), `event_id` is null and only
 * `resource_id` carries the reference. Sinks write both during cohabitation;
 * `event_id` drops out post-Phase 2 cleanup.
 */
export interface ConsequenceSink {
  proposeFine(args: {
    rule_id: UUID;
    group_id: UUID;
    event_id: UUID | null;
    resource_id: UUID;
    member_id: UUID;
    amount: number;
    reason: string;
    evidence: Record<string, unknown>;
  }): Promise<UUID>;
}

// =============================================================================
// Trigger evaluators — derive RuleTargets from a SystemEvent
// =============================================================================

export type TriggerEvaluator = (
  event: SystemEvent,
  rule: Rule,
  context: RuleContext,
) => Promise<RuleTarget[]>;

const TRIGGERS: Partial<Record<SystemEventType, TriggerEvaluator>> = {
  // (V1) Each member of the group is a candidate for fines (no-show, didn't
  // RSVP, etc.). Returns one target per member with their RSVP/check-in.
  eventClosed: async (event, _rule, context) => {
    if (!event.resource_id) return [];
    return context.members
      .filter((m) => m.active)
      .map((m) => ({
        member_id: m.id,
        resource_id: event.resource_id,
        context: {
          user_id: m.user_id,
          rsvp: context.rsvps.find((r) => r.member_user_id === m.user_id) ?? null,
          check_in: context.checkIns.find((c) => c.member_user_id === m.user_id) ?? null,
          event_starts_at: context.resource?.metadata?.starts_at ?? null,
        },
      }));
  },

  // (V1) Single target = the member who checked in.
  checkInRecorded: async (event, _rule, context) => {
    if (!event.member_id) return [];
    const checkIn = context.checkIns.find((c) => {
      const m = context.members.find((x) => x.id === event.member_id);
      return m && c.member_user_id === m.user_id;
    });
    return [{
      member_id: event.member_id,
      resource_id: event.resource_id,
      context: {
        check_in: checkIn,
        minutes_late: checkIn?.minutes_late ?? null,
      },
    }];
  },

  // (V1) Single target = the member who flipped their RSVP same-day.
  // event.member_id is null when iOS emits without resolving group_members.id.
  // Sprint 1c fix: fall back to event.payload.user_id (the auth.uid the iOS
  // coordinator includes), looking up the matching group_members row.
  rsvpChangedSameDay: async (event, _rule, context) => {
    let memberId = event.member_id;
    if (!memberId) {
      const userId = (event.payload?.user_id as string | undefined) ?? null;
      if (userId) {
        memberId = context.members.find((m) => m.user_id === userId)?.id ?? null;
      }
    }
    if (!memberId) return [];
    return [{
      member_id: memberId,
      resource_id: event.resource_id,
      context: { ...event.payload },
    }];
  },

  // (V1) Single target = the host (responsible for the menu/description).
  hoursBeforeEvent: async (event, _rule, context) => {
    const hostId = context.resource?.metadata?.host_id as UUID | undefined;
    if (!hostId) return [];
    const hostMember = context.members.find((m) => m.user_id === hostId);
    if (!hostMember) return [];
    return [{
      member_id: hostMember.id,
      resource_id: event.resource_id,
      context: {
        scheduled_hours: event.payload.hours,
        description: context.resource?.metadata?.description ?? null,
      },
    }];
  },

  // (Phase 2) Single target = the assigned holder of the expired slot.
  // The cron `emit-slot-system-events` projects assigned_member_id +
  // booking_id onto event.payload so the condition evaluators
  // (`slotIsUnassigned`) can read them from target.context without a
  // round-trip to the resource. If no member was assigned, no target —
  // an unassigned slot expiring without booking is a no-op (you can't
  // fine someone for not using a cupo they never held).
  slotExpired: async (event, _rule, _context) => {
    const assignedMemberId = (event.payload?.assigned_member_id as string | undefined) ?? null;
    if (!assignedMemberId) return [];
    if (!event.resource_id) return [];
    return [{
      member_id: assignedMemberId,
      resource_id: event.resource_id,
      context: {
        booking_id: (event.payload?.booking_id as string | null | undefined) ?? null,
        assigned_member_id: assignedMemberId,
        ends_at: event.payload?.ends_at ?? null,
        asset_id: event.payload?.asset_id ?? null,
      },
    }];
  },
};

// =============================================================================
// Condition evaluators
// =============================================================================

export type ConditionEvaluator = (
  condition: RuleCondition,
  target: RuleTarget,
  context: RuleContext,
) => Promise<boolean>;

const CONDITIONS: Partial<Record<ConditionType, ConditionEvaluator>> = {
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
};

// =============================================================================
// Consequence executors
// =============================================================================

export type ConsequenceExecutor = (
  consequence: RuleConsequence,
  target: RuleTarget,
  rule: Rule,
  context: RuleContext,
) => Promise<ExecutionResult>;

const CONSEQUENCES: Partial<Record<ConsequenceType, ConsequenceExecutor>> = {
  // (V1) Only implemented consequence. Reads `amount` (flat) OR
  // `baseAmount` + `stepAmount` + `stepMinutes` (escalating per minutes_late).
  fine: async (cons, target, rule, context) => {
    if (!target.member_id || !target.resource_id || !context.resource) {
      return failure(rule.id, target.member_id, "fine requires member + resource");
    }

    const flatAmount = cons.config.amount as number | undefined;
    const baseAmount = cons.config.baseAmount as number | undefined;
    const stepAmount = cons.config.stepAmount as number | undefined;
    const stepMinutes = cons.config.stepMinutes as number | undefined;

    let amount: number;
    if (typeof flatAmount === "number") {
      amount = flatAmount;
    } else if (
      typeof baseAmount === "number" &&
      typeof stepAmount === "number" &&
      typeof stepMinutes === "number" &&
      stepMinutes > 0
    ) {
      const lateMinutes = Math.max(0, (target.context.minutes_late as number) ?? 0);
      const steps = Math.floor(lateMinutes / stepMinutes);
      amount = baseAmount + steps * stepAmount;
    } else {
      return failure(rule.id, target.member_id, "fine config missing amount / base+step");
    }

    // event_id is the legacy V1 FK to events(id). For Phase 2 non-event
    // resources (slots, bookings, etc.) the slot id isn't in events, so
    // setting event_id = resource_id triggers the fines_event_id_fkey
    // constraint. Send null instead — resource_id (mig 00041 polymorphic
    // FK to resources) is the canonical Phase 2 reference. For V1 events
    // both fields receive the same UUID since events mirror to resources
    // 1:1 via trigger 00039.
    const isEventResource = context.resource?.resource_type === "event";
    const fineId = await context.sink.proposeFine({
      rule_id: rule.id,
      group_id: rule.group_id,
      event_id: isEventResource ? target.resource_id : null,
      resource_id: target.resource_id,
      member_id: target.member_id,
      amount,
      reason: rule.name,
      evidence: target.context as Record<string, unknown>,
    });

    return {
      success: true,
      rule_id: rule.id,
      member_id: target.member_id,
      created_resource_ids: [fineId],
      emitted_event_types: [],
      error: null,
    };
  },
};

function failure(rule_id: UUID, member_id: UUID | null, error: string): ExecutionResult {
  return {
    success: false,
    rule_id,
    member_id,
    created_resource_ids: [],
    emitted_event_types: [],
    error,
  };
}

// =============================================================================
// Orchestrator
// =============================================================================

/**
 * Whether `rule` applies to `event` given its resource/series scope. Closes
 * audit gap #1: prior to this filter the engine ran every group rule on
 * every event, so a rule scoped to occurrence X fired on occurrences Y/Z.
 *
 * Hierarchy per Taxonomy §29 (mig 00071 + 00078):
 *   - `rule.resource_id != null`  → exact-occurrence override; runs only when
 *                                   the event's resource_id matches.
 *   - `rule.series_id   != null`  → series scope; runs only when the
 *                                   occurrence's `series_id` matches.
 *   - both null                   → group-level rule (or module-shipped via
 *                                   `module_key`); runs for any in-group event.
 *
 * Membership scope is orthogonal and handled at target derivation time
 * (`applyMembershipScope`), not here — a membership-scoped rule still
 * "applies" to the event; it just narrows which target survives.
 */
function ruleAppliesToEvent(
  rule: Rule,
  event: SystemEvent,
  context: RuleContext,
): boolean {
  if (rule.resource_id != null) {
    return event.resource_id != null && rule.resource_id === event.resource_id;
  }
  if (rule.series_id != null) {
    const occurrenceSeriesId = context.resource?.series_id ?? null;
    return occurrenceSeriesId != null && rule.series_id === occurrenceSeriesId;
  }
  return true;
}

/**
 * Narrows `targets` to just the rule's `membership_id` when set. Membership
 * scope is orthogonal to resource/series — a rule can be e.g. group-wide AND
 * apply only to Alice. Drops the filter for unscoped rules.
 */
function applyMembershipScope(rule: Rule, targets: RuleTarget[]): RuleTarget[] {
  if (rule.membership_id == null) return targets;
  return targets.filter((t) => t.member_id === rule.membership_id);
}

/**
 * Ranks a rule by scope specificity for "most-specific-wins" resolution.
 * Higher number = more specific.
 *
 *   resource_id (occurrence override) > series_id > module_key > group
 *
 * membership_id is orthogonal — it doesn't change the rank because a
 * membership-scoped variant of a group rule is still "the same rule for
 * a different member", not a more-specific version of the same logical
 * rule (the dedup key already separates them by member).
 */
function ruleScopeRank(rule: Rule): number {
  if (rule.resource_id != null) return 4;
  if (rule.series_id   != null) return 3;
  if (rule.module_key  != null) return 2;
  return 1;
}

/**
 * Deduplicates rules that share a `slug` (the stable cross-scope id of a
 * logical rule). Same logical rule at multiple scopes → most-specific wins
 * per Taxonomy §29.
 *
 * Bucketing key is `slug + membership_id`: a group rule and a membership-
 * scoped override of the SAME logical rule are kept separately so the
 * group rule applies to everyone else while the member override applies to
 * its targeted member. Slugless rules (user-authored) are passed through
 * untouched — without a stable identity there is nothing to dedupe.
 *
 * Exported for testing.
 */
export function selectMostSpecificPerSlug(rules: Rule[]): Rule[] {
  const winners = new Map<string, Rule>();
  const slugless: Rule[] = [];
  for (const r of rules) {
    if (r.slug == null || r.slug === "") {
      slugless.push(r);
      continue;
    }
    const key = `${r.slug}::${r.membership_id ?? ""}`;
    const cur = winners.get(key);
    if (cur == null || ruleScopeRank(r) > ruleScopeRank(cur)) {
      winners.set(key, r);
    }
  }
  return [...winners.values(), ...slugless];
}

/**
 * Runs ALL rules of `group` that match `event`'s trigger eventType AND
 * scope. For each match: derives targets, evaluates conditions (AND),
 * executes consequences.
 *
 * Multiple rules sharing the same `slug` at different scopes collapse to
 * the most-specific one before evaluation — see `selectMostSpecificPerSlug`.
 */
export async function runRulesForEvent(
  event: SystemEvent,
  rules: Rule[],
  context: RuleContext,
): Promise<ExecutionResult[]> {
  const matchingRules = selectMostSpecificPerSlug(
    rules.filter(
      (r) =>
        r.is_active &&
        r.trigger.eventType === event.event_type &&
        ruleAppliesToEvent(r, event, context),
    ),
  );

  const results: ExecutionResult[] = [];

  for (const rule of matchingRules) {
    const triggerFn = TRIGGERS[rule.trigger.eventType];
    if (!triggerFn) {
      logNotImplemented({
        enginePhase: "trigger",
        typeId: rule.trigger.eventType,
        rule,
        event,
        phaseTarget: TRIGGER_PHASE[rule.trigger.eventType],
      });
      results.push(failure(rule.id, null, `unimplemented trigger: ${rule.trigger.eventType}`));
      continue;
    }

    let targets: RuleTarget[];
    try {
      targets = await triggerFn(event, rule, context);
    } catch (e) {
      results.push(failure(rule.id, null, `trigger eval threw: ${(e as Error).message}`));
      continue;
    }

    targets = applyMembershipScope(rule, targets);

    for (const target of targets) {
      // AND across all conditions
      let allMatched = true;
      let missingCondition: string | null = null;
      for (const cond of rule.conditions) {
        const condFn = CONDITIONS[cond.type];
        if (!condFn) {
          logNotImplemented({
            enginePhase: "condition",
            typeId: cond.type,
            rule,
            event,
            phaseTarget: CONDITION_PHASE[cond.type],
          });
          missingCondition = cond.type;
          allMatched = false;
          break;
        }
        const matched = await condFn(cond, target, context);
        if (!matched) {
          allMatched = false;
          break;
        }
      }
      if (missingCondition) {
        // Condition evaluator missing — record a failure per target so the
        // rule run is observable, not silently skipped.
        results.push(failure(rule.id, target.member_id, `unimplemented condition: ${missingCondition}`));
        continue;
      }
      if (!allMatched) continue;

      // All conditions matched — fire every consequence.
      for (const cons of rule.consequences) {
        const consFn = CONSEQUENCES[cons.type];
        if (!consFn) {
          logNotImplemented({
            enginePhase: "consequence",
            typeId: cons.type,
            rule,
            event,
            phaseTarget: CONSEQUENCE_PHASE[cons.type],
          });
          results.push(failure(rule.id, target.member_id, `unimplemented consequence: ${cons.type}`));
          continue;
        }
        try {
          results.push(await consFn(cons, target, rule, context));
        } catch (e) {
          results.push(failure(rule.id, target.member_id, `consequence threw: ${(e as Error).message}`));
        }
      }
    }
  }

  return results;
}

// =============================================================================
// Structured logging for not-implemented evaluators
// =============================================================================

function logNotImplemented(args: {
  enginePhase: "trigger" | "condition" | "consequence";
  typeId: string;
  rule: Rule;
  event: SystemEvent;
  phaseTarget: string | undefined;
}): void {
  // Rules don't carry module_id in V1 — reserved for the Module registry
  // (Bloque 5). Surface as null so consumers can index on the field today.
  const moduleId = (args.rule as unknown as { module_id?: string | null }).module_id ?? null;

  logStructured({
    level: "warn",
    code: "rule_engine.evaluator_not_implemented",
    engine_phase: args.enginePhase,
    type_id: args.typeId,
    rule_id: args.rule.id,
    rule_name: args.rule.name,
    module_id: moduleId,
    group_id: args.rule.group_id,
    system_event_id: args.event.id,
    phase_target: args.phaseTarget ?? "unknown",
    timestamp: new Date().toISOString(),
    message: `No ${args.enginePhase} evaluator for ${args.typeId}`,
  });
}
