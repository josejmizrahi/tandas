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
  RuleConsequence,
  RuleTarget,
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
  // Phase 5: Event spec atoms WITHOUT trigger evaluators today. Listed
  // here so authoring slips on rules using them surface as "future_phase"
  // rather than "unknown".
  //
  // eventStarted / eventCancelled / eventUpdated were promoted out of
  // this map once their evaluators landed below — leaving them here would
  // make the engine log "reserved for phase_5" while actually firing.
  resourceLinked: "phase_5",
  resourceUnlinked: "phase_5",
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
  // transferRight implemented in mig 00200 — see CONSEQUENCES.transferRight
  // below. Removed from this stub map so the engine no longer logs
  // "reserved for phase_2" when the executor actually runs.
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
 * `resource_id` is the polymorphic FK to public.resources. Post §14 step
 * 5c-ii the legacy `event_id` column on fines was dropped, so sinks now
 * write only `resource_id` (events are resources via the 00039 dual-write).
 */
export interface ConsequenceSink {
  proposeFine(args: {
    rule_id: UUID;
    group_id: UUID;
    resource_id: UUID;
    member_id: UUID;
    amount: number;
    reason: string;
    evidence: Record<string, unknown>;
  }): Promise<UUID>;

  /**
   * Emits a `warningEmitted` system_event for the `emitWarning` consequence.
   * Returns the new system_events.id so the executor can record it as a
   * `created_resource_ids` entry in ExecutionResult. Per mig 00193.
   */
  emitWarning(args: {
    rule_id: UUID;
    group_id: UUID;
    resource_id: UUID | null;
    member_id: UUID | null;
    reason: string;
    source_atom_id: UUID;
    payload: Record<string, unknown>;
  }): Promise<UUID>;

  /**
   * Opens a vote for the `startVote` consequence. The optional knobs
   * (duration/quorum/threshold) override `start_vote` RPC defaults when
   * the template params surface them. nil falls through to the RPC's
   * group-policy defaults. Per mig 00194 + Sprint 8 config controls.
   */
  startVote(args: {
    rule_id: UUID;
    group_id: UUID;
    vote_type: string;
    reference_id: UUID;
    title: string;
    description: string | null;
    payload: Record<string, unknown>;
    duration_hours: number | null;
    quorum_percent: number | null;
    threshold_percent: number | null;
  }): Promise<UUID>;

  /**
   * Reassigns a transferable right resource to a new holder. Invokes
   * the canonical `transfer_right` RPC (mig 00198 + 00200) which
   * (a) enforces the right's `transferable=true` invariant, (b) verifies
   * the new holder is an active group member, and (c) emits the
   * `rightTransferred` atom. The sink runs as service_role; the
   * RPC's auth gate is relaxed for that path (mig 00200). Returns the
   * right id (idempotent identifier — same as the input, useful as
   * a `created_resource_ids` entry).
   */
  transferRight(args: {
    rule_id: UUID;
    group_id: UUID;
    right_id: UUID;
    to_member_id: UUID;
    reason: string | null;
  }): Promise<UUID>;

  /**
   * Sets a right's status to `revoked` via the canonical `revoke_right`
   * RPC (mig 00198 + mig 00200's service_role gate). Idempotent —
   * the RPC short-circuits if status is already 'revoked'. Returns the
   * right id (same as input; useful as a `created_resource_ids` entry
   * even though no new row is created).
   */
  revokeRight(args: {
    rule_id: UUID;
    group_id: UUID;
    right_id: UUID;
    reason: string | null;
  }): Promise<UUID>;

  /**
   * Sets `metadata.suspended_until` on a right via the canonical
   * `suspend_right` RPC (mig 00198 + 00200). Status stays 'active' —
   * the suspension is a metadata-level signal. Returns the right id.
   */
  suspendRight(args: {
    rule_id: UUID;
    group_id: UUID;
    right_id: UUID;
    until: string | null;
    reason: string | null;
  }): Promise<UUID>;

  /**
   * Inserts a `user_actions` row of type `assetActionApproval` for the
   * `requireApproval` consequence (Plans/Active/AssetRules.md §4.3).
   * `reference_id` is the asset's resource_id so the inbox surface
   * routes to its detail. Idempotent on (rule_id, resource_id,
   * source_atom_id) — the implementation should dedupe so re-running
   * the rule on the same atom doesn't pile up duplicate inbox rows.
   * Returns the new user_actions.id.
   */
  createUserAction(args: {
    rule_id: UUID;
    group_id: UUID;
    resource_id: UUID;
    action_type: string;
    title: string;
    body: string | null;
    source_atom_id: UUID | null;
    payload: Record<string, unknown>;
  }): Promise<UUID>;

  /**
   * Flips `resources.metadata.bookings_locked = true` for the
   * `lockBookings` consequence (Plans/Active/AssetRules.md §4.3).
   * Soft policy per Constitution §9 — doesn't block booking RPCs;
   * UI + rules read the flag and react. Idempotent: re-firing on an
   * already-locked asset is a no-op. Also emits a `warningEmitted`
   * atom referencing the rule so the audit trail captures the lock.
   * Returns the asset's resource_id for ExecutionResult bookkeeping.
   */
  setBookingsLocked(args: {
    rule_id: UUID;
    group_id: UUID;
    resource_id: UUID;
    reason: string | null;
  }): Promise<UUID>;

  /**
   * Reads the latest `valuationRecorded` atom for an asset and returns
   * its `value_cents`. Used by the `assetTransferred` trigger
   * evaluator to project `valuation_cents` onto the target context so
   * the `transferAmountAbove` condition can compare. Returns null when
   * the asset has no recorded valuation yet (the condition then short-
   * circuits to false). Plans/Active/AssetRules.md §4.1.
   */
  latestAssetValuationCents(assetId: UUID): Promise<number | null>;

  /**
   * Returns active `group_members.id` for every member of `group_id`
   * whose `roles` jsonb array contains `role_id`. Used by the
   * per-consequence target selector `$role.<role_id>` (mig 00249,
   * §22.3) to multiplex a consequence — e.g. "notify the treasurer"
   * fires once per holder. Empty array → no-op consequence (logged
   * but not failed).
   */
  listMembersWithRole(args: { group_id: UUID; role_id: string }): Promise<UUID[]>;

  /**
   * Returns the `group_members.id` matching the `host_id` user in
   * `resources.metadata.host_id`. Used by the `$resource.host`
   * selector for event-scoped consequences. Returns null when:
   *   - resource has no host_id metadata,
   *   - the host's user_id doesn't map to an active member.
   */
  resolveResourceHostMember(resourceId: UUID): Promise<UUID | null>;
}

// =============================================================================
// Trigger evaluators
// =============================================================================
// TRIGGERS lives in ./ruleEngineTriggers.ts (split for legibility
// 2026-05-17, governance-review item #2). Re-export preserves the
// `import { TriggerEvaluator } from "./ruleEngine.ts"` API.
export type { TriggerEvaluator } from "./ruleEngineTriggers.ts";
import { TRIGGERS } from "./ruleEngineTriggers.ts";


// =============================================================================
// Condition evaluators
// =============================================================================
// CONDITIONS lives in ./ruleEngineConditions.ts (split for legibility
// 2026-05-17, governance-review item #2). The export below preserves
// the `import type { ConditionEvaluator } from "./ruleEngine.ts"` API
// for downstream callers.

export type { ConditionEvaluator } from "./ruleEngineConditions.ts";
import { CONDITIONS } from "./ruleEngineConditions.ts";

// =============================================================================
// Consequence executors
// =============================================================================

// CONSEQUENCES lives in ./ruleEngineConsequences.ts (split for legibility
// 2026-05-17, governance-review item #2). The re-exports preserve the
// `import { ConsequenceExecutor } from "./ruleEngine.ts"` API.
export type { ConsequenceExecutor } from "./ruleEngineConsequences.ts";
import { CONSEQUENCES } from "./ruleEngineConsequences.ts";

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

      // Exceptions (mig 00248, §22.2 Governance.md). Same shape as
      // conditions, evaluated by the same CONDITIONS registry, but
      // semantically inverted: if ANY exception evaluates true the
      // consequence is BLOCKED for this target. Halajic "regla y
      // excepción" pattern. Empty / undefined = no exceptions = old
      // behavior preserved.
      const exceptions = rule.exceptions ?? [];
      let blockedByException = false;
      let missingExceptionShape: ConditionType | null = null;
      for (const exc of exceptions) {
        const excFn = CONDITIONS[exc.type];
        if (!excFn) {
          // Missing exception shape = we can't prove the exception
          // wouldn't apply, so fail-safe by blocking. The alternative
          // (silently ignore the exception) would risk firing
          // consequences the rule author intended to gate.
          missingExceptionShape = exc.type;
          blockedByException = true;
          break;
        }
        const triggered = await excFn(exc, target, context);
        if (triggered) {
          blockedByException = true;
          break;
        }
      }
      if (missingExceptionShape) {
        logNotImplemented({
          enginePhase: "condition",
          typeId: missingExceptionShape,
          rule,
          event,
          phaseTarget: CONDITION_PHASE[missingExceptionShape],
        });
        results.push(failure(
          rule.id,
          target.member_id,
          `unimplemented exception shape: ${missingExceptionShape} (blocked consequence as fail-safe)`,
        ));
        continue;
      }
      if (blockedByException) continue;

      // All conditions matched and no exception applied — fire every
      // consequence. mig 00249 / §22.3: each consequence may carry a
      // `target` selector that re-routes / multiplexes execution to
      // members different from the trigger's original target.
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
        const resolvedTargets = await resolveConsequenceTargets(cons, target, context, rule);
        if (resolvedTargets.length === 0) {
          // Selector evaluated to empty set (role with no holders, host
          // missing). Log and continue — not a failure, just a no-op.
          logStructured({
            level: "warn",
            code: "rule_engine.consequence_target_empty",
            message: "consequence target resolved to empty set",
            rule_id: rule.id,
            consequence_type: cons.type,
            target_selector: cons.target ?? "$trigger.actor",
          });
          continue;
        }
        for (const resolved of resolvedTargets) {
          try {
            results.push(await consFn(cons, resolved, rule, context));
          } catch (e) {
            results.push(failure(rule.id, resolved.member_id, `consequence threw: ${(e as Error).message}`));
          }
        }
      }
    }
  }

  return results;
}

/**
 * Resolves a consequence's optional target selector to one or more
 * RuleTargets (mig 00249 / §22.3 Governance.md).
 *
 *   undefined / "$trigger.actor" → [originalTarget] (default, no DB)
 *   "$resource.host"             → host_member_id from resource.metadata
 *                                  (1 target, or 0 if missing)
 *   "$role.<role_id>"            → 0..N targets, one per active member
 *                                  with that role
 *
 * Returned targets preserve the original `resource_id` + `context` so
 * the consequence executor can still reason about the original event;
 * only `member_id` is rewritten. This is the talmudic distinction
 * between actor and subject — the act happened to the original target,
 * but the consequence binds a different party.
 */
async function resolveConsequenceTargets(
  cons: RuleConsequence,
  originalTarget: RuleTarget,
  context: RuleContext,
  rule: Rule,
): Promise<RuleTarget[]> {
  const selector = cons.target ?? "$trigger.actor";

  if (selector === "$trigger.actor") {
    return [originalTarget];
  }

  if (selector === "$resource.host") {
    if (!originalTarget.resource_id) return [];
    const hostMemberId = await context.sink.resolveResourceHostMember(originalTarget.resource_id);
    if (!hostMemberId) return [];
    return [{
      member_id: hostMemberId,
      resource_id: originalTarget.resource_id,
      context: { ...originalTarget.context, redirected_from_member_id: originalTarget.member_id },
    }];
  }

  const roleMatch = selector.match(/^\$role\.([a-z][a-z0-9_]{0,31})$/);
  if (roleMatch) {
    const role_id = roleMatch[1];
    const memberIds = await context.sink.listMembersWithRole({
      group_id: rule.group_id,
      role_id,
    });
    return memberIds.map((member_id) => ({
      member_id,
      resource_id: originalTarget.resource_id,
      context: { ...originalTarget.context, redirected_from_member_id: originalTarget.member_id },
    }));
  }

  // Unknown selector — fail-safe: treat as default. The publish RPC
  // validates the selector vocabulary so this branch shouldn't fire
  // for any rule that landed via publish_rule_composition or
  // bump_rule_version (both validate via validate_consequence_target).
  logStructured({
    level: "warn",
    code: "rule_engine.consequence_target_unknown_selector",
    message: "unknown consequence target selector, falling back to $trigger.actor",
    rule_id: rule.id,
    consequence_type: cons.type,
    selector,
  });
  return [originalTarget];
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
