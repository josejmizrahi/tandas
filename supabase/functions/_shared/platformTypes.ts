// Platform types — TypeScript mirror of the Swift platform models. The
// string-union enums live in `platformEnums.generated.ts` (auto-generated
// from `platform/types/catalog.json`). This file owns the structural
// interfaces (`SystemEvent`, `Rule`, `RuleTarget`, …) that aren't part of
// the codegen.
//
// To add or rename an enum value: edit `platform/types/catalog.json` and
// run `node scripts/codegen/types.mjs`. CI rejects PRs whose generated
// output differs from the catalog.

export {
  type SystemEventType,
  type ConditionType,
  type ConsequenceType,
  type ResourceType,
  type GovernanceAction,
  type PermissionLevel,
  SystemEventType_ALL,
  ConditionType_ALL,
  ConsequenceType_ALL,
  ResourceType_ALL,
  GovernanceAction_ALL,
  PermissionLevel_ALL,
  isSystemEventType,
  isConditionType,
  isConsequenceType,
  isResourceType,
  isGovernanceAction,
  isPermissionLevel,
} from "./platformEnums.generated.ts";

import type {
  SystemEventType,
  ConditionType,
  ConsequenceType,
} from "./platformEnums.generated.ts";

export type UUID = string;
export type ISODate = string;

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
