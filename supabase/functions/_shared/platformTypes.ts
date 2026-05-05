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

export interface RuleConsequence {
  type: ConsequenceType;
  config: Record<string, unknown>;
}

export interface Rule {
  id: UUID;
  group_id: UUID;
  name: string;
  is_active: boolean;
  trigger: RuleTrigger;
  conditions: RuleCondition[];
  consequences: RuleConsequence[];
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
