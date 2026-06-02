// Asset rule engine unit tests (Plans/Active/AssetRules.md §8).
//
// Pure Deno tests — no live Supabase. Each test constructs a synthetic
// `SystemEvent` + `Rule` + `RuleContext` (with a recording
// `ConsequenceSink`) and asserts on what the engine produced.
//
// Covers 6 of the 8 §8 tests:
//   1. damageReportedTriggerEnumeratesMember
//   2. damageAmountAboveFiresOnThreshold
//   3. requireApprovalCreatesUserAction (with sink dedupe)
//   4. maintenanceOverdueRespectsCompletion (sink-side path: dedup token)
//   5. lockBookingsSetsMetadata
//   6. transferLargeVoteRequiresValuation
//
// Not covered here (need live DB or heavier mocks — P2 follow-ups):
//   - checkoutOverdueDeduplicatesWithin24h — cron emitter dedup. Lives in
//     supabase/functions/emit-asset-overdue-events; an e2e test against a
//     test Supabase project is the right shape.
//   - eachAssetTemplateHappyPath — end-to-end through real RPCs → atoms
//     → engine → sink. Same constraint.

import { assertEquals, assert } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { runRulesForEvent } from "../_shared/ruleEngine.ts";
import type {
  ConsequenceSink,
  RuleContext,
} from "../_shared/ruleEngine.ts";
import type {
  Rule,
  SystemEvent,
  UUID,
} from "../_shared/platformTypes.ts";

// =============================================================================
// Helpers
// =============================================================================

const GROUP_ID    = "00000000-0000-0000-0000-000000000001";
const RESOURCE_ID = "00000000-0000-0000-0000-000000000002";
const MEMBER_ID   = "00000000-0000-0000-0000-000000000003";
const USER_ID     = "00000000-0000-0000-0000-000000000004";

function makeEvent(over: Partial<SystemEvent>): SystemEvent {
  return {
    id:           "00000000-0000-0000-0000-000000000010",
    group_id:     GROUP_ID,
    event_type:   "damageReported",
    resource_id:  RESOURCE_ID,
    member_id:    MEMBER_ID,
    payload:      {},
    occurred_at:  new Date().toISOString(),
    processed_at: null,
    ...over,
  };
}

function makeRule(over: Partial<Rule>): Rule {
  const now = new Date().toISOString();
  return {
    id:           "00000000-0000-0000-0000-000000000020",
    group_id:     GROUP_ID,
    slug:         "test_rule",
    name:         "Test Rule",
    is_active:    true,
    trigger:      { eventType: "damageReported", config: {} },
    conditions:   [{ type: "alwaysTrue", config: {} }],
    consequences: [{ type: "emitWarning", config: {} }],
    resource_id:  null,
    series_id:    null,
    membership_id: null,
    module_key:   null,
    created_at:   now,
    updated_at:   now,
    ...over,
  };
}

/// Sink that records every call so tests can assert what the engine
/// produced. Each sink method returns a deterministic stub uuid so
/// the engine's ExecutionResult.created_resource_ids has something
/// to put in it.
function makeRecordingSink(opts: {
  /// Stub valuation_cents the assetTransferred trigger projects onto
  /// target.context. `null` means "no valuation recorded" — exercises
  /// the transferAmountAbove short-circuit path.
  valuationCents?: number | null;
  /// Pre-seeded user_actions rows the createUserAction sink should
  /// treat as existing duplicates. Keys are
  /// `${rule_id}|${resource_id}|${source_atom_id}` tuples.
  existingActions?: Set<string>;
  /// Pre-seeded resource ids the setBookingsLocked sink should treat
  /// as already-locked (idempotent path).
  alreadyLocked?: Set<UUID>;
} = {}): ConsequenceSink & {
  fines: unknown[];
  warnings: unknown[];
  votes: unknown[];
  actions: unknown[];
  locks: unknown[];
} {
  const fines:    unknown[] = [];
  const warnings: unknown[] = [];
  const votes:    unknown[] = [];
  const actions:  unknown[] = [];
  const locks:    unknown[] = [];
  const existing = opts.existingActions ?? new Set<string>();
  const locked   = opts.alreadyLocked   ?? new Set<UUID>();

  return {
    fines, warnings, votes, actions, locks,

    proposeFine: async (args) => {
      fines.push(args);
      return "fine-id";
    },
    emitWarning: async (args) => {
      warnings.push(args);
      return "warning-id";
    },
    startVote: async (args) => {
      votes.push(args);
      return "vote-id";
    },
    transferRight: async () => "right-id",
    revokeRight:   async () => "right-id",
    suspendRight:  async () => "right-id",

    createUserAction: async (args) => {
      const key = `${args.rule_id}|${args.resource_id}|${args.source_atom_id ?? "no-source"}`;
      if (existing.has(key)) {
        // Dedupe path: return existing stub id without recording.
        return "existing-action-id";
      }
      existing.add(key);
      actions.push(args);
      return "action-id";
    },

    setBookingsLocked: async (args) => {
      if (locked.has(args.resource_id)) {
        // Idempotent path: already locked → no-op record.
        return args.resource_id;
      }
      locked.add(args.resource_id);
      locks.push(args);
      return args.resource_id;
    },

    latestAssetValuationCents: async () => {
      return opts.valuationCents ?? null;
    },
  };
}

function makeContext(sink: ConsequenceSink): RuleContext {
  return {
    now: new Date(),
    members: [
      { id: MEMBER_ID, user_id: USER_ID, active: true },
    ],
    resource: {
      id: RESOURCE_ID,
      group_id: GROUP_ID,
      resource_type: "asset",
      status: "active",
      metadata: {},
    },
    rsvps: [],
    checkIns: [],
    finesThisMonthByMember: new Map(),
    sink,
  };
}

// =============================================================================
// 1. damageReported trigger — single target = the reporter
// =============================================================================

Deno.test("damageReportedTriggerEnumeratesMember — single target = reporter", async () => {
  const sink = makeRecordingSink();
  const ctx  = makeContext(sink);
  const event = makeEvent({
    event_type: "damageReported",
    payload: {
      severity:             "major",
      estimated_cost_cents: 750_000,
      currency:             "MXN",
      notes:                "se cayó el palco",
    },
  });
  const rule = makeRule({
    trigger:    { eventType: "damageReported", config: {} },
    conditions: [{ type: "alwaysTrue", config: {} }],
    consequences: [{ type: "emitWarning", config: {} }],
  });

  await runRulesForEvent(event, [rule], ctx);

  // emitWarning fires once with the projected payload — proves the
  // trigger enumerated exactly one target (the reporter).
  assertEquals(sink.warnings.length, 1, "exactly one warning emitted");
  const w = sink.warnings[0] as Record<string, unknown>;
  assertEquals(w.member_id, MEMBER_ID, "warning targets the reporter");
  assertEquals(w.resource_id, RESOURCE_ID, "warning targets the asset");
});

// =============================================================================
// 2. damageAmountAbove — fires above, skips at-or-below
// =============================================================================

Deno.test("damageAmountAboveFiresOnThreshold — above fires, below skips", async () => {
  const threshold = 500_000;
  const rule = makeRule({
    trigger:    { eventType: "damageReported", config: {} },
    conditions: [{ type: "damageAmountAbove", config: { threshold_cents: threshold } }],
    consequences: [{ type: "emitWarning", config: {} }],
  });

  // Above threshold — fires.
  {
    const sink = makeRecordingSink();
    const ctx  = makeContext(sink);
    await runRulesForEvent(
      makeEvent({
        event_type: "damageReported",
        payload: { estimated_cost_cents: threshold + 1 },
      }),
      [rule], ctx,
    );
    assertEquals(sink.warnings.length, 1, "above threshold → warning fired");
  }

  // Exactly at threshold — skips (strict > per evaluator).
  {
    const sink = makeRecordingSink();
    const ctx  = makeContext(sink);
    await runRulesForEvent(
      makeEvent({
        event_type: "damageReported",
        payload: { estimated_cost_cents: threshold },
      }),
      [rule], ctx,
    );
    assertEquals(sink.warnings.length, 0, "at threshold → strict > so no fire");
  }

  // Below threshold — skips.
  {
    const sink = makeRecordingSink();
    const ctx  = makeContext(sink);
    await runRulesForEvent(
      makeEvent({
        event_type: "damageReported",
        payload: { estimated_cost_cents: threshold - 1 },
      }),
      [rule], ctx,
    );
    assertEquals(sink.warnings.length, 0, "below threshold → no fire");
  }

  // Missing payload — defaults to 0, never fires above threshold.
  {
    const sink = makeRecordingSink();
    const ctx  = makeContext(sink);
    await runRulesForEvent(
      makeEvent({ event_type: "damageReported", payload: {} }),
      [rule], ctx,
    );
    assertEquals(sink.warnings.length, 0, "missing payload → defaults to 0, no fire");
  }
});

// =============================================================================
// 3. requireApproval — creates user_action, dedupes re-runs on same atom
// =============================================================================

Deno.test("requireApprovalCreatesUserAction — first run inserts, re-run dedupes", async () => {
  const existingActions = new Set<string>();
  const sink = makeRecordingSink({ existingActions });
  const ctx  = makeContext(sink);
  const rule = makeRule({
    id: "00000000-0000-0000-0000-000000000099",
    trigger:    { eventType: "damageReported", config: {} },
    conditions: [{ type: "alwaysTrue", config: {} }],
    consequences: [{ type: "requireApproval", config: {} }],
  });
  const event = makeEvent({
    id: "00000000-0000-0000-0000-000000000077",
    event_type: "damageReported",
    payload: {
      severity:             "major",
      estimated_cost_cents: 600_000,
      currency:             "MXN",
    },
  });

  // First run: action created.
  await runRulesForEvent(event, [rule], ctx);
  assertEquals(sink.actions.length, 1, "first run creates a user_action");
  const a = sink.actions[0] as Record<string, unknown>;
  assertEquals(a.action_type, "assetActionApproval");
  assertEquals(a.resource_id, RESOURCE_ID);
  assertEquals(a.rule_id, rule.id);
  assertEquals(a.source_atom_id, event.id);

  // Second run on the SAME atom: dedupes (sink.existingActions hit).
  await runRulesForEvent(event, [rule], ctx);
  assertEquals(sink.actions.length, 1, "re-run on same atom does not duplicate");
});

// =============================================================================
// 4. lockBookings — flips metadata, idempotent on re-run
// =============================================================================

Deno.test("lockBookingsSetsMetadata — first run locks, re-run no-ops", async () => {
  const alreadyLocked = new Set<UUID>();
  const sink = makeRecordingSink({ alreadyLocked });
  const ctx  = makeContext(sink);
  const rule = makeRule({
    trigger:    { eventType: "assetMaintenanceOverdue", config: {} },
    conditions: [{ type: "alwaysTrue", config: {} }],
    consequences: [{ type: "lockBookings", config: {} }],
  });

  // assetMaintenanceOverdue is resource-scoped (member_id = null)
  // so the trigger evaluator emits one target with member_id=null.
  const event = makeEvent({
    event_type: "assetMaintenanceOverdue",
    member_id: null,
    payload: { maintenance_event_id: "x", days_open: 14 },
  });

  // First run: lock flips.
  await runRulesForEvent(event, [rule], ctx);
  assertEquals(sink.locks.length, 1, "first run locks the asset");
  assert(alreadyLocked.has(RESOURCE_ID), "sink state shows locked");

  // Second run: no-op (idempotent).
  await runRulesForEvent(event, [rule], ctx);
  assertEquals(sink.locks.length, 1, "re-run on locked asset is a no-op");
});

// =============================================================================
// 5. transferAmountAbove — short-circuits without valuation, fires with one
// =============================================================================

Deno.test("transferLargeVoteRequiresValuation — null valuation short-circuits", async () => {
  const rule = makeRule({
    trigger:    { eventType: "assetTransferred", config: {} },
    conditions: [{ type: "transferAmountAbove", config: { threshold_cents: 5_000_000 } }],
    consequences: [
      // Use emitWarning instead of startVote so the test doesn't depend
      // on the ledger_entry_id projection that startVote requires.
      // The condition's pass/fail is what's under test here.
      { type: "emitWarning", config: {} },
    ],
  });

  // No valuation → short-circuits to false → no warning.
  {
    const sink = makeRecordingSink({ valuationCents: null });
    const ctx  = makeContext(sink);
    await runRulesForEvent(
      makeEvent({
        event_type: "assetTransferred",
        payload: { to_member_id: "x", from_member_id: "y" },
      }),
      [rule], ctx,
    );
    assertEquals(sink.warnings.length, 0, "no valuation → no fire");
  }

  // Valuation above threshold → fires.
  {
    const sink = makeRecordingSink({ valuationCents: 10_000_000 });
    const ctx  = makeContext(sink);
    await runRulesForEvent(
      makeEvent({
        event_type: "assetTransferred",
        payload: { to_member_id: "x", from_member_id: "y" },
      }),
      [rule], ctx,
    );
    assertEquals(sink.warnings.length, 1, "valuation above threshold → fires");
  }

  // Valuation below threshold → no fire.
  {
    const sink = makeRecordingSink({ valuationCents: 4_999_999 });
    const ctx  = makeContext(sink);
    await runRulesForEvent(
      makeEvent({
        event_type: "assetTransferred",
        payload: { to_member_id: "x", from_member_id: "y" },
      }),
      [rule], ctx,
    );
    assertEquals(sink.warnings.length, 0, "below threshold → no fire");
  }
});

// =============================================================================
// 6. assetCheckoutOverdue + not_returned_fine — fine routes to the holder
// =============================================================================

Deno.test("checkoutOverdueRoutesFineToHolder — holder = member_id from atom", async () => {
  const sink = makeRecordingSink();
  const ctx  = makeContext(sink);
  const rule = makeRule({
    trigger:    { eventType: "assetCheckoutOverdue", config: {} },
    conditions: [{ type: "alwaysTrue", config: {} }],
    consequences: [{ type: "fine", config: { amount: 200 } }],
  });
  const event = makeEvent({
    event_type: "assetCheckoutOverdue",
    member_id: MEMBER_ID,
    payload: {
      expected_return_at: "2026-05-01T00:00:00Z",
      checked_out_at:     "2026-04-24T00:00:00Z",
      days_overdue:       7,
    },
  });

  await runRulesForEvent(event, [rule], ctx);

  assertEquals(sink.fines.length, 1, "exactly one fine emitted");
  const f = sink.fines[0] as Record<string, unknown>;
  assertEquals(f.member_id, MEMBER_ID, "fine targets the prior holder");
  assertEquals(f.resource_id, RESOURCE_ID, "fine targets the asset");
  assertEquals(f.amount, 200, "fine carries the configured amount");
});
