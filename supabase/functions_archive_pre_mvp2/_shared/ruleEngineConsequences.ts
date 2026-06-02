// Consequence executors — split out from ruleEngine.ts for readability
// (mig governance-review item #2). Same registry pattern as
// ruleEngineConditions.ts: a Record<ConsequenceType, Executor> map
// that the engine dispatches against.
//
// Adding a new consequence: implement the ConsequenceExecutor function,
// register it in CONSEQUENCES keyed by the matching ConsequenceType
// enum case, drop the case from CONSEQUENCE_PHASE in ruleEngine.ts if
// it was previously reserved for a future phase, and (if needed)
// extend ConsequenceSink in ruleEngine.ts with whatever DB-touching
// primitives the executor needs.

import type {
  ConsequenceType,
  ExecutionResult,
  Rule,
  RuleConsequence,
  RuleTarget,
  UUID,
} from "./platformTypes.ts";
import type { RuleContext } from "./ruleEngine.ts";

export type ConsequenceExecutor = (
  consequence: RuleConsequence,
  target: RuleTarget,
  rule: Rule,
  context: RuleContext,
) => Promise<ExecutionResult>;

// Local copy of the failure() helper. Identical to the one in
// ruleEngine.ts; intentionally duplicated to avoid a value-import
// cycle (ruleEngine.ts imports this file, which would otherwise have
// to import back). Trivial and stable — 8 lines, no behavior to drift.
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

export const CONSEQUENCES: Partial<Record<ConsequenceType, ConsequenceExecutor>> = {
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

    // Post §14 step 5c-ii: fines.event_id column dropped. resource_id is
    // the canonical handle whether the resource is a V1 event or a
    // Phase 2 non-event (slot, fund, asset).
    const fineId = await context.sink.proposeFine({
      rule_id: rule.id,
      group_id: rule.group_id,
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

  // (mig 00194) Opens a `ledger_review` vote when a rule fires on a ledger
  // entry that crossed a threshold. Phase 1: vote is informational; the
  // referenced ledger entry is NOT auto-voided on fail. Used by
  // `expense_threshold_vote` template.
  startVote: async (cons, target, rule, context) => {
    const ledgerEntryId = target.context.ledger_entry_id as UUID | undefined;
    if (!ledgerEntryId) {
      return failure(rule.id, target.member_id, "startVote requires ledger_entry_id in target context");
    }
    const voteType = (cons.config.vote_type as string | undefined) ?? "ledger_review";
    const title = (cons.config.title as string | undefined) ?? rule.name;
    const voteId = await context.sink.startVote({
      rule_id: rule.id,
      group_id: rule.group_id,
      vote_type: voteType,
      reference_id: ledgerEntryId,
      title,
      description: (cons.config.description as string | undefined) ?? null,
      payload: {
        source_atom_id: target.context.source_atom_id ?? null,
        amount_cents:   target.context.amount_cents ?? null,
        currency:       target.context.currency ?? null,
        ledger_type:    target.context.type ?? null,
        recorder_member_id: target.member_id,
      },
      duration_hours:    (cons.config.duration_hours as number | undefined) ?? null,
      quorum_percent:    (cons.config.quorum_percent as number | undefined) ?? null,
      threshold_percent: (cons.config.threshold_percent as number | undefined) ?? null,
    });
    return {
      success: true,
      rule_id: rule.id,
      member_id: target.member_id,
      created_resource_ids: [voteId],
      emitted_event_types: ["voteOpened"],
      error: null,
    };
  },

  // (mig 00193) Emits a `warningEmitted` system_event so the activity feed
  // surfaces the rule-driven warning. Pure visibility — no money, no vote.
  // Used by the `expense_threshold_warning` template.
  emitWarning: async (_cons, target, rule, context) => {
    const sourceAtomId = target.context.source_atom_id as UUID | undefined;
    if (!sourceAtomId) {
      return failure(rule.id, target.member_id, "emitWarning requires source_atom_id in target context");
    }
    const warningId = await context.sink.emitWarning({
      rule_id: rule.id,
      group_id: rule.group_id,
      resource_id: target.resource_id ?? null,
      member_id: target.member_id ?? null,
      reason: rule.name,
      source_atom_id: sourceAtomId,
      payload: target.context as Record<string, unknown>,
    });
    return {
      success: true,
      rule_id: rule.id,
      member_id: target.member_id,
      created_resource_ids: [warningId],
      emitted_event_types: ["warningEmitted"],
      error: null,
    };
  },

  // (mig 00200) Transfers a right resource to a new holder via the
  // canonical `transfer_right` RPC. Two config modes for picking the
  // recipient:
  //
  //   1. `config.to_member_id: "<uuid>"` — explicit recipient
  //   2. `config.to_target_member: true` — recipient is target.member_id
  //      (the member the rule's trigger fired on, e.g. "transfer to
  //      whoever exercised it last")
  //
  // The right id itself comes from `target.resource_id` — the rule's
  // trigger MUST have fired on a `right` resource (e.g. rightCreated,
  // rightTransferred, rightExercised). Misconfigured rules that fire
  // on a non-right resource fail safe with "resource is not a right".
  //
  // Server-side invariants (mig 00198): transferable=true is still
  // required; new holder must be an active group member; emits
  // `rightTransferred` with attribution=NULL (service_role) but a
  // rule-id reason so the audit row carries enough context.
  transferRight: async (cons, target, rule, context) => {
    if (!target.resource_id) {
      return failure(rule.id, target.member_id, "transferRight requires target.resource_id");
    }
    if (context.resource && context.resource.resource_type !== "right") {
      return failure(
        rule.id,
        target.member_id,
        `transferRight target is a ${context.resource.resource_type}, not a right`,
      );
    }

    let toMemberId: UUID | null = null;
    const explicit = cons.config.to_member_id as string | undefined;
    const useTarget = cons.config.to_target_member as boolean | undefined;
    if (explicit) {
      toMemberId = explicit;
    } else if (useTarget) {
      toMemberId = target.member_id;
    }
    if (!toMemberId) {
      return failure(
        rule.id,
        target.member_id,
        "transferRight requires config.to_member_id or config.to_target_member=true",
      );
    }

    const reason = (cons.config.reason as string | undefined) ?? rule.name;
    try {
      const rightId = await context.sink.transferRight({
        rule_id:      rule.id,
        group_id:     rule.group_id,
        right_id:     target.resource_id,
        to_member_id: toMemberId,
        reason,
      });
      return {
        success: true,
        rule_id: rule.id,
        member_id: target.member_id,
        // The transferred right is the "created/affected resource" for
        // this consequence. Downstream callers use the list to roll up
        // audit trails per ExecutionResult.
        created_resource_ids: [rightId],
        emitted_event_types: ["rightTransferred"],
        error: null,
      };
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return failure(rule.id, target.member_id, `transferRight failed: ${msg}`);
    }
  },

  // (slice 10) Revokes a right. Same guard rails as transferRight:
  //   - target.resource_id must be set
  //   - context.resource (if loaded) must be a right
  // Idempotent server-side: revoke_right RPC short-circuits when status
  // is already 'revoked'. Use case: "When a holder accumulates N fines
  // → revoke their priority access" — pair with a fine-counting
  // condition to gate the revocation.
  revokeRight: async (cons, target, rule, context) => {
    if (!target.resource_id) {
      return failure(rule.id, target.member_id, "revokeRight requires target.resource_id");
    }
    if (context.resource && context.resource.resource_type !== "right") {
      return failure(
        rule.id,
        target.member_id,
        `revokeRight target is a ${context.resource.resource_type}, not a right`,
      );
    }
    const reason = (cons.config.reason as string | undefined) ?? rule.name;
    try {
      const rightId = await context.sink.revokeRight({
        rule_id:  rule.id,
        group_id: rule.group_id,
        right_id: target.resource_id,
        reason,
      });
      return {
        success: true,
        rule_id: rule.id,
        member_id: target.member_id,
        created_resource_ids: [rightId],
        emitted_event_types: ["rightRevoked"],
        error: null,
      };
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return failure(rule.id, target.member_id, `revokeRight failed: ${msg}`);
    }
  },

  // (slice 10) Suspends a right via metadata.suspended_until.
  // Config: `{ "until": "<iso>", "reason": "…" }` — both optional.
  // Status stays 'active'; restore_right (manual admin) is the
  // canonical lift. Use case: "When holder misses N exercises in a
  // row → suspend until they confirm engagement" — paired with a
  // counting condition + an external follow-up.
  suspendRight: async (cons, target, rule, context) => {
    if (!target.resource_id) {
      return failure(rule.id, target.member_id, "suspendRight requires target.resource_id");
    }
    if (context.resource && context.resource.resource_type !== "right") {
      return failure(
        rule.id,
        target.member_id,
        `suspendRight target is a ${context.resource.resource_type}, not a right`,
      );
    }
    const until = (cons.config.until as string | undefined) ?? null;
    const reason = (cons.config.reason as string | undefined) ?? rule.name;
    try {
      const rightId = await context.sink.suspendRight({
        rule_id:  rule.id,
        group_id: rule.group_id,
        right_id: target.resource_id,
        until,
        reason,
      });
      return {
        success: true,
        rule_id: rule.id,
        member_id: target.member_id,
        created_resource_ids: [rightId],
        emitted_event_types: ["rightSuspended"],
        error: null,
      };
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return failure(rule.id, target.member_id, `suspendRight failed: ${msg}`);
    }
  },

  // (mig 00226, AssetRules.md §4.3) Creates a user_actions inbox row
  // of type `assetActionApproval`. Sink dedupes on (rule_id +
  // resource_id + source_atom_id) so re-running the rule doesn't
  // pile up duplicate inbox entries.
  requireApproval: async (_cons, target, rule, context) => {
    if (!target.resource_id) {
      return failure(rule.id, target.member_id, "requireApproval requires resource_id");
    }
    const sourceAtomId = (target.context.source_atom_id as UUID | null | undefined) ?? null;
    const severity = target.context.severity as string | null | undefined;
    const costCents = target.context.estimated_cost_cents as number | null | undefined;
    const title = rule.name;
    const body = (severity && typeof costCents === "number")
      ? `Daño ${severity}: ${(costCents / 100).toFixed(2)} ${target.context.currency ?? "MXN"}`
      : null;

    const actionId = await context.sink.createUserAction({
      rule_id: rule.id,
      group_id: rule.group_id,
      resource_id: target.resource_id,
      action_type: "assetActionApproval",
      title,
      body,
      source_atom_id: sourceAtomId,
      payload: target.context as Record<string, unknown>,
    });

    return {
      success: true,
      rule_id: rule.id,
      member_id: target.member_id,
      created_resource_ids: [actionId],
      emitted_event_types: [],
      error: null,
    };
  },

  // (mig 00226, AssetRules.md §4.3) Sets resources.metadata.bookings_locked
  // = true on the asset and emits an audit warningEmitted atom. Sink
  // is idempotent — re-firing on an already-locked asset is a no-op
  // but still resolves successfully so the rule engine doesn't loop.
  lockBookings: async (_cons, target, rule, context) => {
    if (!target.resource_id) {
      return failure(rule.id, target.member_id, "lockBookings requires resource_id");
    }
    const assetId = await context.sink.setBookingsLocked({
      rule_id: rule.id,
      group_id: rule.group_id,
      resource_id: target.resource_id,
      reason: rule.name,
    });
    return {
      success: true,
      rule_id: rule.id,
      member_id: target.member_id,
      created_resource_ids: [assetId],
      emitted_event_types: ["warningEmitted"],
      error: null,
    };
  },

  // ===========================================================================
  // Space rule consequences (mig 00268, Plans/Active/SpaceRules.md §3.3)
  // ===========================================================================

  // (PR-3) Calls expire_booking(booking_id, reason) to retire the
  // booking that triggered the rule. Emits bookingExpired + (when
  // target is a space) spaceReleased downstream. Idempotent — the RPC
  // short-circuits when a bookingCancelled/Expired atom already exists.
  // Drives `space_no_check_in_release` template.
  releaseBooking: async (cons, target, rule, context) => {
    const bookingId = target.context.booking_id as UUID | null | undefined;
    if (!bookingId) {
      return failure(rule.id, target.member_id, "releaseBooking requires target.context.booking_id");
    }
    const reason = (cons.config.reason as string | undefined) ?? "no_check_in";
    try {
      const id = await context.sink.expireBooking({
        rule_id: rule.id,
        group_id: rule.group_id,
        booking_id: bookingId,
        reason,
      });
      return {
        success: true,
        rule_id: rule.id,
        member_id: target.member_id,
        created_resource_ids: [id],
        emitted_event_types: ["bookingExpired", "spaceReleased"],
        error: null,
      };
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return failure(rule.id, target.member_id, `releaseBooking failed: ${msg}`);
    }
  },

  // (PR-3) Soft block per TalmudicGovernance §4.G. Does NOT roll back
  // the triggering atom (the action happened — atom is truth). Emits a
  // warningEmitted companion atom carrying the deny message so the
  // activity feed + admins see the rejection. UI on the caller side
  // is what surfaces the rejection to the user — this consequence is
  // the audit record. Idempotent via emitWarning's source_atom_id.
  denyAction: async (cons, target, rule, context) => {
    if (!target.resource_id) {
      return failure(rule.id, target.member_id, "denyAction requires target.resource_id");
    }
    const message = (cons.config.message_es as string | undefined)
      ?? "Esta acción no está permitida";
    const sourceAtomId = (target.context.source_atom_id as UUID | null | undefined) ?? rule.id;
    const id = await context.sink.emitWarning({
      rule_id: rule.id,
      group_id: rule.group_id,
      resource_id: target.resource_id,
      member_id: target.member_id,
      reason: message,
      source_atom_id: sourceAtomId,
      payload: {
        kind:         "denyAction",
        deny_message: message,
        ...(target.context as Record<string, unknown>),
      },
    });
    return {
      success: true,
      rule_id: rule.id,
      member_id: target.member_id,
      created_resource_ids: [id],
      emitted_event_types: ["warningEmitted"],
      error: null,
    };
  },

  // (PR-3) Re-emits a spaceWaitlistJoined atom for the actor with a
  // bumped priority. Sink dedupes on source_atom_id so re-running the
  // rule against the same join doesn't ladder priorities upward
  // infinitely. Drives `space_founder_priority_bump`.
  bumpPriority: async (cons, target, rule, context) => {
    if (!target.resource_id || !target.member_id) {
      return failure(rule.id, target.member_id, "bumpPriority requires resource_id + member_id");
    }
    const delta = (cons.config.priority_delta as number | undefined) ?? 100;
    const originalPriority = (target.context.priority as number | null | undefined) ?? 0;
    const sourceAtomId = (target.context.source_atom_id as UUID | null | undefined);
    if (!sourceAtomId) {
      return failure(rule.id, target.member_id, "bumpPriority requires source_atom_id in target context");
    }
    try {
      const id = await context.sink.bumpWaitlistPriority({
        rule_id: rule.id,
        group_id: rule.group_id,
        space_id: target.resource_id,
        member_id: target.member_id,
        original_priority: originalPriority,
        priority_delta: delta,
        source_atom_id: sourceAtomId,
      });
      return {
        success: true,
        rule_id: rule.id,
        member_id: target.member_id,
        created_resource_ids: [id],
        emitted_event_types: ["spaceWaitlistJoined"],
        error: null,
      };
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return failure(rule.id, target.member_id, `bumpPriority failed: ${msg}`);
    }
  },
};
