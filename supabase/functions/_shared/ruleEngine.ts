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
 */
export interface ConsequenceSink {
  proposeFine(args: {
    rule_id: UUID;
    group_id: UUID;
    event_id: UUID;
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
  rsvpChangedSameDay: async (event, _rule, _context) => {
    if (!event.member_id) return [];
    return [{
      member_id: event.member_id,
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

    const fineId = await context.sink.proposeFine({
      rule_id: rule.id,
      group_id: rule.group_id,
      event_id: target.resource_id,
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
 * Runs ALL rules of `group` that match `event`'s trigger eventType. For each
 * match: derives targets, evaluates conditions (AND), executes consequences.
 */
export async function runRulesForEvent(
  event: SystemEvent,
  rules: Rule[],
  context: RuleContext,
): Promise<ExecutionResult[]> {
  const matchingRules = rules.filter(
    (r) => r.is_active && r.trigger.eventType === event.event_type,
  );

  const results: ExecutionResult[] = [];

  for (const rule of matchingRules) {
    const triggerFn = TRIGGERS[rule.trigger.eventType];
    if (!triggerFn) {
      console.warn(`[ruleEngine] no trigger evaluator for ${rule.trigger.eventType}`);
      continue;
    }

    let targets: RuleTarget[];
    try {
      targets = await triggerFn(event, rule, context);
    } catch (e) {
      results.push(failure(rule.id, null, `trigger eval threw: ${(e as Error).message}`));
      continue;
    }

    for (const target of targets) {
      // AND across all conditions
      let allMatched = true;
      for (const cond of rule.conditions) {
        const condFn = CONDITIONS[cond.type];
        if (!condFn) {
          console.warn(`[ruleEngine] no condition evaluator for ${cond.type} (rule ${rule.id})`);
          allMatched = false;
          break;
        }
        const matched = await condFn(cond, target, context);
        if (!matched) {
          allMatched = false;
          break;
        }
      }
      if (!allMatched) continue;

      // All conditions matched — fire every consequence.
      for (const cons of rule.consequences) {
        const consFn = CONSEQUENCES[cons.type];
        if (!consFn) {
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
