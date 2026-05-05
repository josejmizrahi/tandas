// Platform types — TypeScript mirror of the Swift platform models. Used by
// the rule engine and the cron functions.
//
// Keep this file in sync with `ios/Tandas/Platform/Models/`. When you add
// a new SystemEventType / ConditionType / ConsequenceType in Swift, append
// it here too. Mismatches are not silently ignored — the rule engine logs
// "unknown ConditionType" and skips the rule.

export type UUID = string;
export type ISODate = string;

// =============================================================================
// SystemEvent
// =============================================================================

export type SystemEventType =
  | "eventClosed"
  | "eventCreated"
  | "rsvpDeadlinePassed"
  | "hoursBeforeEvent"
  | "rsvpSubmitted"
  | "rsvpChangedSameDay"
  | "checkInRecorded"
  | "checkInMissed"
  | "eventDescriptionMissing"
  | "slotAssigned"
  | "slotDeclined"
  | "slotExpired"
  | "fineOfficialized"
  | "finePaid"
  | "appealCreated"
  | "appealResolved"
  | "voteCast"
  | "fundDeposit"
  | "fundThresholdReached"
  | "positionChanged"
  | "memberJoined"
  | "memberLeft";

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

import { type ConditionType } from "./types/conditionType.ts";
import { type ConsequenceType } from "./types/consequenceType.ts";
export type { ConditionType, ConsequenceType };

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
