// AUTO-GENERATED — Do not edit by hand. Source: platform/types/catalog.json. Run: node scripts/codegen/types.mjs

// String unions and runtime arrays for every platform enum. The rule
// engine and edge functions import from here. Decoders that encounter
// a value not present in the matching `_ALL` array log a warning and
// skip the row instead of crashing.

// Every event the platform may emit. The rule engine matches `Rule.trigger
// .eventType` against this enum.
//
// Cases marked **(V1)** have a TriggerEvaluator implementation in
// `_shared/ruleEngine.ts`. Other cases are declared so the model stays
// V4-ready; the engine ignores rules whose trigger is not implemented yet.
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
  | "fineReminderSent"
  | "appealCreated"
  | "appealResolved"
  | "voteOpened"
  | "voteCast"
  | "voteResolved"
  | "fundDeposit"
  | "fundThresholdReached"
  | "positionChanged"
  | "memberJoined"
  | "memberLeft";

export const SystemEventType_ALL = [
  "eventClosed",
  "eventCreated",
  "rsvpDeadlinePassed",
  "hoursBeforeEvent",
  "rsvpSubmitted",
  "rsvpChangedSameDay",
  "checkInRecorded",
  "checkInMissed",
  "eventDescriptionMissing",
  "slotAssigned",
  "slotDeclined",
  "slotExpired",
  "fineOfficialized",
  "finePaid",
  "fineReminderSent",
  "appealCreated",
  "appealResolved",
  "voteOpened",
  "voteCast",
  "voteResolved",
  "fundDeposit",
  "fundThresholdReached",
  "positionChanged",
  "memberJoined",
  "memberLeft",
] as const satisfies readonly SystemEventType[];

export function isSystemEventType(value: unknown): value is SystemEventType {
  return typeof value === "string" && (SystemEventType_ALL as readonly string[]).includes(value);
}

// Every condition the rule engine knows how to evaluate. Rules combine
// multiple conditions with AND.
//
// Cases marked **(V1)** have a ConditionEvaluator implementation in
// `_shared/ruleEngine.ts`. Other cases throw `NotImplementedError` server-
// side; rules using them are skipped with a structured log line.
export type ConditionType =
  | "alwaysTrue"
  | "responseStatusIs"
  | "checkInExists"
  | "checkInMinutesLate"
  | "eventDescriptionMissing"
  | "minutesAfterScheduled"
  | "hoursBeforeEvent"
  | "memberHasMultipleFines"
  | "memberFinesAbove"
  | "memberMissedConsecutive"
  | "eventDayOfWeek"
  | "eventTimeWindow"
  | "fundBalanceAbove"
  | "fundBalanceBelow"
  | "rotationPositionEquals";

export const ConditionType_ALL = [
  "alwaysTrue",
  "responseStatusIs",
  "checkInExists",
  "checkInMinutesLate",
  "eventDescriptionMissing",
  "minutesAfterScheduled",
  "hoursBeforeEvent",
  "memberHasMultipleFines",
  "memberFinesAbove",
  "memberMissedConsecutive",
  "eventDayOfWeek",
  "eventTimeWindow",
  "fundBalanceAbove",
  "fundBalanceBelow",
  "rotationPositionEquals",
] as const satisfies readonly ConditionType[];

export function isConditionType(value: unknown): value is ConditionType {
  return typeof value === "string" && (ConditionType_ALL as readonly string[]).includes(value);
}

// Every consequence the rule engine can execute when a rule's conditions
// match. Rules can chain multiple consequences (all execute).
//
// Cases marked **(V1)** have a ConsequenceExecutor implementation in
// `_shared/ruleEngine.ts`. Other cases throw `NotImplementedError`; rules
// using them are skipped with a structured log line so the architecture
// stays V4-ready without silently failing in production.
export type ConsequenceType =
  | "fine"
  | "loseTurn"
  | "losePriority"
  | "serviceCompensation"
  | "blockTemporary"
  | "reciprocity"
  | "logOnly"
  | "sumPoints"
  | "subtractPoints"
  | "sendNotification"
  | "startVote"
  | "createEvent"
  | "assignSlot"
  | "transferRight"
  | "callWebhook";

export const ConsequenceType_ALL = [
  "fine",
  "loseTurn",
  "losePriority",
  "serviceCompensation",
  "blockTemporary",
  "reciprocity",
  "logOnly",
  "sumPoints",
  "subtractPoints",
  "sendNotification",
  "startVote",
  "createEvent",
  "assignSlot",
  "transferRight",
  "callWebhook",
] as const satisfies readonly ConsequenceType[];

export function isConsequenceType(value: unknown): value is ConsequenceType {
  return typeof value === "string" && (ConsequenceType_ALL as readonly string[]).includes(value);
}

export type ResourceType =
  | "event"
  | "slot"
  | "fund"
  | "position"
  | "asset"
  | "contribution";

export const ResourceType_ALL = [
  "event",
  "slot",
  "fund",
  "position",
  "asset",
  "contribution",
] as const satisfies readonly ResourceType[];

export function isResourceType(value: unknown): value is ResourceType {
  return typeof value === "string" && (ResourceType_ALL as readonly string[]).includes(value);
}

// Governance action evaluated by `GovernanceService`. Each case maps to one
// key in `groups.governance` jsonb. Stable raw values — these are part of
// the API surface for SQL helper functions like `group_governance_level`.
export type GovernanceAction =
  | "whoCanModifyRules"
  | "whoCanInviteMembers"
  | "whoCanRemoveMembers"
  | "whoCanCloseEvents"
  | "whoCanCreateVotes"
  | "whoCanModifyGovernance";

export const GovernanceAction_ALL = [
  "whoCanModifyRules",
  "whoCanInviteMembers",
  "whoCanRemoveMembers",
  "whoCanCloseEvents",
  "whoCanCreateVotes",
  "whoCanModifyGovernance",
] as const satisfies readonly GovernanceAction[];

export function isGovernanceAction(value: unknown): value is GovernanceAction {
  return typeof value === "string" && (GovernanceAction_ALL as readonly string[]).includes(value);
}

// Permission level applied to a governance action. Stored as raw string in
// `groups.governance` jsonb. The values mirror the enum cases verbatim
// (camelCase on disk to match the migration backfill).
export type PermissionLevel =
  | "founder"
  | "anyMember"
  | "majorityVote"
  | "supermajorityVote"
  | "host"
  | "treasurer";

export const PermissionLevel_ALL = [
  "founder",
  "anyMember",
  "majorityVote",
  "supermajorityVote",
  "host",
  "treasurer",
] as const satisfies readonly PermissionLevel[];

export function isPermissionLevel(value: unknown): value is PermissionLevel {
  return typeof value === "string" && (PermissionLevel_ALL as readonly string[]).includes(value);
}
