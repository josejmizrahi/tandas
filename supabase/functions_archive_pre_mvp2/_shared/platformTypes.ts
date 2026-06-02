// Platform types for the rule engine and edge functions.
//
// Enums (SystemEventType, ConditionType, ConsequenceType) are codegen-
// produced from `ios/Tandas/Platform/Models/<Name>.swift` — see
// `scripts/codegen/README.md`. Do not edit them inline here.
//
// The structs/interfaces below (SystemEvent, Rule, RuleTrigger, etc.)
// are still hand-maintained mirrors of the Swift Platform/Models structs.
// A future Fase 0.5 may add codegen for those too; until then, keep them
// in sync manually when the Swift side changes.

export type UUID = string;
export type ISODate = string;

import { type SystemEventType } from "./types/systemEventType.ts";
import { type ConditionType } from "./types/conditionType.ts";
import { type ConsequenceType } from "./types/consequenceType.ts";
export type { SystemEventType, ConditionType, ConsequenceType };

// =============================================================================
// SystemEvent
// =============================================================================

export interface SystemEvent {
  id: UUID;
  group_id: UUID;
  event_type: SystemEventType;
  resource_id: UUID | null;
  member_id: UUID | null;
  payload: Record<string, unknown>;
  occurred_at: ISODate;
  processed_at: ISODate | null;
}

// =============================================================================
// Rule
// =============================================================================

export interface RuleTrigger {
  eventType: SystemEventType;
  config: Record<string, unknown>;
}

export interface RuleCondition {
  type: ConditionType;
  config: Record<string, unknown>;
}

/**
 * AND/OR/NOT composition of conditions (§22.4 / mig 00251). A rule's
 * `conditions` field may be:
 *
 * - a flat array of leaves — interpreted as `{op:'and', children:array}`
 *   (legacy / pre-§22.4 wire shape, preserved for backward compat).
 * - a `{op,children}` object where `op ∈ {'and','or','not'}` and each
 *   child is either a leaf `{type,config}` or a nested op node.
 *   `'not'` carries exactly one child; `'and'`/`'or'` carry ≥ 1.
 *
 * The engine normalises arrays to `{op:'and', children:array}` before
 * walking so downstream code only handles the tree form.
 * Publisher RPCs (publish_rule_composition v6, bump_rule_version v5)
 * validate the structure before persisting.
 */
export type RuleConditionNode =
  | RuleCondition
  | { op: "and"; children: RuleConditionNode[] }
  | { op: "or";  children: RuleConditionNode[] }
  | { op: "not"; children: RuleConditionNode[] };

export interface RuleConsequence {
  type: ConsequenceType;
  config: Record<string, unknown>;
  /**
   * Optional target selector that re-routes this consequence to a
   * member different from the one the trigger picked. Vocabulary
   * (mig 00249, §22.3 Governance.md):
   *
   *   undefined / "$trigger.actor" → original target.member_id (default)
   *   "$resource.host"             → resource.metadata.host_id (event)
   *   "$role.<role_id>"            → multiplex: one fire per active
   *                                   member assigned that role
   *
   * Resolution happens in resolveConsequenceTargets (engine). Missing
   * resource/role → 0 targets → consequence is a no-op (logged).
   */
  target?: string;
}

export interface Rule {
  id: UUID;
  group_id: UUID;
  /**
   * Stable cross-scope identifier inherited from the originating template
   * rule (e.g. `dinner_late_arrival`). Survives rename of `name` (display
   * copy) and i18n. Used by `selectMostSpecificPerSlug` to dedupe the same
   * logical rule across scopes (most specific wins). Optional because
   * user-authored rules may not carry a slug.
   */
  slug?: string | null;
  name: string;
  is_active: boolean;
  trigger: RuleTrigger;
  /**
   * §22.4 (mig 00251): either a flat array of leaves (legacy implicit
   * AND wire shape) or a `{op,children}` tree object. The engine
   * normalises arrays to `{op:'and', children: array}` before walking,
   * so downstream code only deals with the tree form.
   */
  conditions: RuleCondition[] | RuleConditionNode;
  consequences: RuleConsequence[];
  // (RuleConsequence carries its own optional `target` selector per
  // mig 00249 — see ruleEngineConsequences.ts resolveTargets.)
  /**
   * Exceptions are condition-shaped predicates that BLOCK the
   * consequences when ANY of them evaluates true on the target.
   * Reuses the same shape catalog (kind=condition) so an `alwaysTrue`,
   * `responseStatusIs("excused")`, or `slotIsUnassigned` can serve as
   * an exception. Engine evaluates them AFTER all conditions match,
   * BEFORE any consequence fires. Empty array = no exceptions (the
   * default and the behavior pre-mig 00248). See §22.2 Governance.md.
   *
   * Optional in the TS shape because pre-00248 fixtures don't set it.
   */
  exceptions?: RuleCondition[];
  /**
   * Scope precedence per Taxonomy §29 — read by `runRulesForEvent` to filter
   * which rules apply to a given SystemEvent (mig 00071 + 00078):
   *
   *   - `resource_id` set            → applies only to that resource (occurrence).
   *   - `series_id`   set            → applies to all occurrences of that series
   *                                    UNLESS the occurrence has its own override.
   *   - `membership_id` set          → orthogonal: target must be that member.
   *   - `module_key`  set            → seeded by module activation (group-level).
   *   - all four null                → group-level user/template rule.
   *
   * Optional in the TS shape because pre-00071 fixtures and tests don't set
   * them. The DB columns are nullable.
   */
  resource_id?: UUID | null;
  series_id?: UUID | null;
  membership_id?: UUID | null;
  module_key?: string | null;
  created_at: ISODate;
  updated_at: ISODate;
}

// =============================================================================
// Rule engine runtime
// =============================================================================

/**
 * One concrete target a rule will be evaluated against, derived from a
 * SystemEvent by the matching TriggerEvaluator. For the V1 rules:
 *   - eventClosed → one target per group_member
 *   - checkInRecorded → one target for the member who checked in
 *   - rsvpChangedSameDay → one target for the member who changed
 *   - hoursBeforeEvent → one target for the host
 */
export interface RuleTarget {
  member_id: UUID | null;
  resource_id: UUID | null;
  context: Record<string, unknown>;
}

/**
 * Per-rule execution result. Aggregated by the orchestrator into a run
 * summary that lands back in the system_events row's payload column when
 * marked processed.
 */
export interface ExecutionResult {
  success: boolean;
  rule_id: UUID;
  member_id: UUID | null;
  created_resource_ids: UUID[];
  emitted_event_types: SystemEventType[];
  error: string | null;
}
