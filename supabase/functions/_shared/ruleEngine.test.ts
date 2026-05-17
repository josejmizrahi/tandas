// Rule engine unit tests — exercise the 5 default "Cena recurrente" rules
// against fabricated SystemEvent + RuleContext fixtures. Run with:
//
//   deno test supabase/functions/_shared/ruleEngine.test.ts
//
// No Supabase calls. The ConsequenceSink is an in-memory recorder, so every
// fine the engine "creates" is observable as a captured object.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { runRulesForEvent, type ConsequenceSink, type RuleContext } from "./ruleEngine.ts";
import { _resetLogSink, _setLogSink, type StructuredEntry } from "./log.ts";
import type { Rule, SystemEvent } from "./platformTypes.ts";

function captureLogs(): { entries: StructuredEntry[]; restore: () => void } {
  const entries: StructuredEntry[] = [];
  _setLogSink((e) => entries.push(e));
  return { entries, restore: () => _resetLogSink() };
}

const groupId = "g00000000-0000-0000-0000-000000000001";
const eventId = "e00000000-0000-0000-0000-000000000001";

const memberAlice = { id: "ma00000000-0000-0000-0000-000000000001", user_id: "ua00000000-0000-0000-0000-000000000001", active: true };
const memberBob   = { id: "mb00000000-0000-0000-0000-000000000001", user_id: "ub00000000-0000-0000-0000-000000000001", active: true };
const memberCarla = { id: "mc00000000-0000-0000-0000-000000000001", user_id: "uc00000000-0000-0000-0000-000000000001", active: true };

function captureSink(): {
  sink: ConsequenceSink;
  captured: unknown[];
  warnings: unknown[];
  votes: unknown[];
  transfers: unknown[];
  revokes: unknown[];
  suspends: unknown[];
} {
  const captured: unknown[] = [];
  const warnings: unknown[] = [];
  const votes: unknown[] = [];
  const transfers: unknown[] = [];
  const revokes: unknown[] = [];
  const suspends: unknown[] = [];
  const sink: ConsequenceSink = {
    proposeFine: async (args) => {
      captured.push(args);
      return `fine-${captured.length}`;
    },
    emitWarning: async (args) => {
      warnings.push(args);
      return `warning-${warnings.length}`;
    },
    startVote: async (args) => {
      votes.push(args);
      return `vote-${votes.length}`;
    },
    transferRight: async (args) => {
      transfers.push(args);
      return args.right_id;
    },
    revokeRight: async (args) => {
      revokes.push(args);
      return args.right_id;
    },
    suspendRight: async (args) => {
      suspends.push(args);
      return args.right_id;
    },
    // mig 00249 / §22.3 — target selector stubs. Tests that exercise
    // multi-target paths override these via `extras.sink`. Defaults
    // return empty / null so default `$trigger.actor` behavior is
    // unaffected.
    listMembersWithRole: async () => [],
    resolveResourceHostMember: async () => null,
    // AssetRules.md §4.3 stubs — not exercised by the rule fixtures in
    // this file, but required by the ConsequenceSink contract. Default
    // implementations are no-ops that return a synthetic id so any
    // accidental invocation surfaces as observable state rather than a
    // runtime crash.
    createUserAction: async (args) => `user-action-${args.rule_id}`,
    setBookingsLocked: async (args) => args.resource_id,
    latestAssetValuationCents: async () => null,
  };
  return { sink, captured, warnings, votes, transfers, revokes, suspends };
}

function baseContext(extras: Partial<RuleContext>): RuleContext {
  return {
    now: new Date("2026-05-04T22:00:00Z"),
    members: [memberAlice, memberBob, memberCarla],
    resource: {
      id: eventId,
      group_id: groupId,
      resource_type: "event",
      status: "closed",
      metadata: {
        starts_at: "2026-05-04T20:30:00Z",
        host_id: memberAlice.user_id,
        description: "Pasta + ensalada",
      },
    },
    rsvps: [],
    checkIns: [],
    finesThisMonthByMember: new Map(),
    sink: extras.sink ?? captureSink().sink,
    ...extras,
  };
}

function makeRule(name: string, trigger: Rule["trigger"], conditions: Rule["conditions"], consequences: Rule["consequences"]): Rule {
  return {
    id: `rule-${name}`,
    group_id: groupId,
    name,
    is_active: true,
    trigger,
    conditions,
    consequences,
    created_at: "2026-05-01T00:00:00Z",
    updated_at: "2026-05-01T00:00:00Z",
  };
}

function makeEvent(eventType: SystemEvent["event_type"], opts: Partial<SystemEvent> = {}): SystemEvent {
  return {
    id: "se-1",
    group_id: groupId,
    event_type: eventType,
    resource_id: eventId,
    member_id: null,
    payload: {},
    occurred_at: "2026-05-04T22:00:00Z",
    processed_at: null,
    ...opts,
  };
}

// =============================================================================
// Rule 2: "No confirmó a tiempo" — eventClosed + responseStatusIs(pending) → fine $200
// =============================================================================

Deno.test("eventClosed + responseStatusIs(pending) → fines pending members", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "No confirmó a tiempo",
    { eventType: "eventClosed", config: {} },
    [{ type: "responseStatusIs", config: { status: "pending" } }],
    [{ type: "fine", config: { amount: 200 } }],
  );

  const ctx = baseContext({
    sink,
    rsvps: [
      { member_user_id: memberAlice.user_id, status: "going",   rsvp_at: "2026-05-03T10:00:00Z", cancelled_same_day: false },
      { member_user_id: memberBob.user_id,   status: "pending", rsvp_at: null,                   cancelled_same_day: false },
      { member_user_id: memberCarla.user_id, status: "pending", rsvp_at: null,                   cancelled_same_day: false },
    ],
  });

  const results = await runRulesForEvent(makeEvent("eventClosed"), [rule], ctx);

  // 2 pending members → 2 fines proposed
  assertEquals(results.length, 2);
  assertEquals(captured.length, 2);
  for (const fine of captured as Array<{ amount: number; member_id: string; resource_id: string }>) {
    assertEquals(fine.amount, 200);
    assertEquals([memberBob.id, memberCarla.id].includes(fine.member_id), true);
    // Post §14 step 5c-ii: sink receives only resource_id; legacy event_id
    // column on fines was dropped. resources.id mirrors events.id 1:1
    // via the 00039 dual-write trigger.
    assertEquals(fine.resource_id, eventId);
  }
});

// =============================================================================
// Rule 2.b: "No confirmó a tiempo" via rsvpDeadlinePassed
// — pre-event variant of Rule 2. Fires at the RSVP deadline (emitted by
// the emit-deadline-events cron) so a member who hasn't responded gets
// hit while there's still time to react. The post-event variant (Rule 2,
// above) keeps eventClosed semantics for groups that prefer to penalize
// at close time instead.
// =============================================================================

Deno.test("rsvpDeadlinePassed + responseStatusIs(pending) → fines only pending members", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "No confirmó a tiempo (pre-event)",
    { eventType: "rsvpDeadlinePassed", config: {} },
    [{ type: "responseStatusIs", config: { status: "pending" } }],
    [{ type: "fine", config: { amount: 150 } }],
  );

  const deadlineIso = "2026-05-04T12:00:00Z";
  const ctx = baseContext({
    sink,
    rsvps: [
      { member_user_id: memberAlice.user_id, status: "going",   rsvp_at: "2026-05-03T10:00:00Z", cancelled_same_day: false },
      { member_user_id: memberBob.user_id,   status: "pending", rsvp_at: null,                   cancelled_same_day: false },
      { member_user_id: memberCarla.user_id, status: "pending", rsvp_at: null,                   cancelled_same_day: false },
    ],
  });

  const event = makeEvent("rsvpDeadlinePassed", {
    payload: { rsvp_deadline: deadlineIso, starts_at: "2026-05-04T20:30:00Z" },
  });
  const results = await runRulesForEvent(event, [rule], ctx);

  // 2 pending members → 2 fines proposed; Alice (going) is skipped.
  assertEquals(results.length, 2);
  assertEquals(captured.length, 2);
  const fined = (captured as Array<{ member_id: string; amount: number }>)
    .map(f => f.member_id)
    .sort();
  assertEquals(fined, [memberBob.id, memberCarla.id].sort());
  for (const fine of captured as Array<{ amount: number }>) {
    assertEquals(fine.amount, 150);
  }
});

Deno.test("rsvpDeadlinePassed: all members responded → no fines", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "No confirmó a tiempo (pre-event)",
    { eventType: "rsvpDeadlinePassed", config: {} },
    [{ type: "responseStatusIs", config: { status: "pending" } }],
    [{ type: "fine", config: { amount: 150 } }],
  );

  const ctx = baseContext({
    sink,
    rsvps: [
      { member_user_id: memberAlice.user_id, status: "going",    rsvp_at: "x", cancelled_same_day: false },
      { member_user_id: memberBob.user_id,   status: "declined", rsvp_at: "x", cancelled_same_day: false },
      { member_user_id: memberCarla.user_id, status: "maybe",    rsvp_at: "x", cancelled_same_day: false },
    ],
  });

  const event = makeEvent("rsvpDeadlinePassed", {
    payload: { rsvp_deadline: "2026-05-04T12:00:00Z", starts_at: "2026-05-04T20:30:00Z" },
  });
  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 0, "every member responded — no fines");
  assertEquals(captured.length, 0);
});

Deno.test("rsvpDeadlinePassed without resource_id → no targets, no fines", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "No confirmó a tiempo (pre-event)",
    { eventType: "rsvpDeadlinePassed", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "fine", config: { amount: 150 } }],
  );

  const ctx = baseContext({ sink });
  // Defensive: the emitter always sets resource_id, but guard the engine
  // against malformed rows so a missing FK doesn't crash process-events.
  const event = makeEvent("rsvpDeadlinePassed", { resource_id: null });
  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 0);
  assertEquals(captured.length, 0);
});

// =============================================================================
// Rule 4: "No-show" — eventClosed + going + checkInExists(false) → fine $300
// =============================================================================

Deno.test("eventClosed + going + checkInExists(false) → no-show fine", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "No-show",
    { eventType: "eventClosed", config: {} },
    [
      { type: "responseStatusIs", config: { status: "going" } },
      { type: "checkInExists",    config: { exists: false } },
    ],
    [{ type: "fine", config: { amount: 300 } }],
  );

  const ctx = baseContext({
    sink,
    rsvps: [
      { member_user_id: memberAlice.user_id, status: "going", rsvp_at: "z", cancelled_same_day: false },
      { member_user_id: memberBob.user_id,   status: "going", rsvp_at: "z", cancelled_same_day: false },
    ],
    checkIns: [
      { member_user_id: memberAlice.user_id, arrived_at: "2026-05-04T20:30:00Z", minutes_late: 0 },
      // Bob never arrived
    ],
  });

  const results = await runRulesForEvent(makeEvent("eventClosed"), [rule], ctx);
  // Only Bob qualifies (Alice checked in; Carla wasn't going)
  assertEquals(results.length, 1);
  assertEquals(captured.length, 1);
  const bobFine = captured[0] as { member_id: string; amount: number };
  assertEquals(bobFine.member_id, memberBob.id);
  assertEquals(bobFine.amount, 300);
});

// =============================================================================
// Rule 1: "Llegada tardía" — checkInRecorded + checkInMinutesLate → escalating fine
// =============================================================================

Deno.test("checkInRecorded + escalating fine — 75 min late = base + 2 steps", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "Llegada tardía",
    { eventType: "checkInRecorded", config: {} },
    [{ type: "checkInMinutesLate", config: { thresholdMinutes: 0 } }],
    [{ type: "fine", config: { baseAmount: 200, stepAmount: 50, stepMinutes: 30 } }],
  );

  const ctx = baseContext({
    sink,
    checkIns: [
      { member_user_id: memberBob.user_id, arrived_at: "2026-05-04T21:45:00Z", minutes_late: 75 },
    ],
  });

  const event = makeEvent("checkInRecorded", { member_id: memberBob.id });
  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 1);
  assertEquals(captured.length, 1);
  // 75 minutes late, step every 30 → 2 steps. base 200 + 2*50 = 300.
  assertEquals((captured[0] as { amount: number }).amount, 300);
});

Deno.test("checkInRecorded + on-time arrival → no fine", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "Llegada tardía",
    { eventType: "checkInRecorded", config: {} },
    [{ type: "checkInMinutesLate", config: { thresholdMinutes: 0 } }],
    [{ type: "fine", config: { baseAmount: 200, stepAmount: 50, stepMinutes: 30 } }],
  );

  const ctx = baseContext({
    sink,
    checkIns: [
      { member_user_id: memberAlice.user_id, arrived_at: "2026-05-04T20:30:00Z", minutes_late: 0 },
    ],
  });

  const event = makeEvent("checkInRecorded", { member_id: memberAlice.id });
  const results = await runRulesForEvent(event, [rule], ctx);

  // 0 minutes late >= 0 threshold → fires. Base + 0 steps = 200.
  assertEquals(results.length, 1);
  assertEquals((captured[0] as { amount: number }).amount, 200);
});

// =============================================================================
// Rule 3: "Cancelación mismo día" — rsvpChangedSameDay + alwaysTrue → fine $200
// =============================================================================

Deno.test("rsvpChangedSameDay + alwaysTrue → fine for the member", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "Cancelación mismo día",
    { eventType: "rsvpChangedSameDay", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "fine", config: { amount: 200 } }],
  );

  const ctx = baseContext({ sink });
  const event = makeEvent("rsvpChangedSameDay", { member_id: memberCarla.id, payload: { from: "going", to: "declined" } });
  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 1);
  assertEquals((captured[0] as { member_id: string; amount: number }).member_id, memberCarla.id);
  assertEquals((captured[0] as { amount: number }).amount, 200);
});

// =============================================================================
// Rule 5: "Anfitrión sin menú" — hoursBeforeEvent + eventDescriptionMissing → fine $200
// =============================================================================

Deno.test("hoursBeforeEvent + descriptionMissing → fine for host (description present = no fine)", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "Anfitrión sin menú",
    { eventType: "hoursBeforeEvent", config: { hours: 24 } },
    [{ type: "eventDescriptionMissing", config: {} }],
    [{ type: "fine", config: { amount: 200 } }],
  );

  // Description IS present in baseContext — no fire
  const ctx = baseContext({ sink });
  const event = makeEvent("hoursBeforeEvent", { payload: { hours: 24 } });
  const results = await runRulesForEvent(event, [rule], ctx);
  assertEquals(results.length, 0);
  assertEquals(captured.length, 0);

  // Now strip the description — should fire one fine for the host (Alice).
  const { sink: sink2, captured: captured2 } = captureSink();
  const ctxMissing = baseContext({
    sink: sink2,
    resource: {
      id: eventId,
      group_id: groupId,
      resource_type: "event",
      status: "upcoming",
      metadata: {
        starts_at: "2026-05-04T20:30:00Z",
        host_id: memberAlice.user_id,
        description: "",
      },
    },
  });
  const results2 = await runRulesForEvent(event, [rule], ctxMissing);
  assertEquals(results2.length, 1);
  assertEquals((captured2[0] as { member_id: string }).member_id, memberAlice.id);
});

// =============================================================================
// Negative cases — engine resilience
// =============================================================================

Deno.test("inactive rule → never fires", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "off rule",
    { eventType: "eventClosed", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "fine", config: { amount: 1 } }],
  );
  rule.is_active = false;

  const ctx = baseContext({ sink });
  const results = await runRulesForEvent(makeEvent("eventClosed"), [rule], ctx);
  assertEquals(results.length, 0);
  assertEquals(captured.length, 0);
});

Deno.test("unimplemented consequence → records failure + structured warn log per target", async () => {
  const { sink, captured } = captureSink();
  const { entries, restore } = captureLogs();
  try {
    const rule = makeRule(
      "future rule",
      { eventType: "eventClosed", config: {} },
      [{ type: "alwaysTrue", config: {} }],
      // loseTurn is declared in the enum but has no executor in V1.
      [{ type: "loseTurn", config: {} }],
    );

    const ctx = baseContext({ sink });
    const event = makeEvent("eventClosed");
    const results = await runRulesForEvent(event, [rule], ctx);

    // 3 active members × 1 unimplemented consequence = 3 failure rows + 3 logs
    assertEquals(results.length, 3);
    for (const r of results) {
      assertEquals(r.success, false);
      assertEquals(r.error?.includes("unimplemented consequence"), true);
    }
    assertEquals(captured.length, 0);

    assertEquals(entries.length, 3);
    for (const e of entries) {
      assertEquals(e.level, "warn");
      assertEquals(e.code, "rule_engine.evaluator_not_implemented");
      assertEquals(e.engine_phase, "consequence");
      assertEquals(e.type_id, "loseTurn");
      assertEquals(e.rule_id, rule.id);
      assertEquals(e.rule_name, rule.name);
      assertEquals(e.module_id, null);
      assertEquals(e.group_id, groupId);
      assertEquals(e.system_event_id, event.id);
      assertEquals(e.phase_target, "phase_2");
      assertEquals(typeof e.timestamp, "string");
    }
  } finally {
    restore();
  }
});

// =============================================================================
// Reserved-type failure modes — must surface, not silent-skip
// =============================================================================

Deno.test("unimplemented trigger → 1 failure record + structured warn log (no targets derived)", async () => {
  const { sink, captured } = captureSink();
  const { entries, restore } = captureLogs();
  try {
    // slotAssigned is reserved for phase_2 (Recurso compartido template).
    // No trigger evaluator in V1 — must NOT silently skip.
    const rule = makeRule(
      "phase 2 rule",
      { eventType: "slotAssigned", config: {} },
      [{ type: "alwaysTrue", config: {} }],
      [{ type: "fine", config: { amount: 100 } }],
    );

    const ctx = baseContext({ sink });
    const event = makeEvent("slotAssigned");
    const results = await runRulesForEvent(event, [rule], ctx);

    // No targets ever derived → exactly 1 failure record for the rule itself.
    assertEquals(results.length, 1);
    assertEquals(results[0].success, false);
    assertEquals(results[0].member_id, null);
    assertEquals(results[0].error?.includes("unimplemented trigger"), true);
    assertEquals(captured.length, 0);

    assertEquals(entries.length, 1);
    const e = entries[0];
    assertEquals(e.level, "warn");
    assertEquals(e.code, "rule_engine.evaluator_not_implemented");
    assertEquals(e.engine_phase, "trigger");
    assertEquals(e.type_id, "slotAssigned");
    assertEquals(e.rule_id, rule.id);
    assertEquals(e.rule_name, rule.name);
    assertEquals(e.module_id, null);
    assertEquals(e.group_id, groupId);
    assertEquals(e.system_event_id, event.id);
    assertEquals(e.phase_target, "phase_2");
    assertEquals(typeof e.timestamp, "string");
  } finally {
    restore();
  }
});

Deno.test("unimplemented condition → failure per target + structured warn log per target", async () => {
  const { sink, captured } = captureSink();
  const { entries, restore } = captureLogs();
  try {
    // memberFinesAbove is reserved for phase_4 (custom rule editor).
    // Condition with no evaluator must NOT silently set allMatched=false
    // without recording a failure.
    const rule = makeRule(
      "phase 4 rule",
      { eventType: "eventClosed", config: {} },
      [{ type: "memberFinesAbove", config: { count: 3 } }],
      [{ type: "fine", config: { amount: 100 } }],
    );

    const ctx = baseContext({ sink });
    const event = makeEvent("eventClosed");
    const results = await runRulesForEvent(event, [rule], ctx);

    // 3 active members × 1 unimplemented condition = 3 failure rows + 3 logs
    assertEquals(results.length, 3);
    for (const r of results) {
      assertEquals(r.success, false);
      assertEquals(r.error?.includes("unimplemented condition"), true);
    }
    assertEquals(captured.length, 0);

    assertEquals(entries.length, 3);
    for (const e of entries) {
      assertEquals(e.level, "warn");
      assertEquals(e.code, "rule_engine.evaluator_not_implemented");
      assertEquals(e.engine_phase, "condition");
      assertEquals(e.type_id, "memberFinesAbove");
      assertEquals(e.rule_id, rule.id);
      assertEquals(e.rule_name, rule.name);
      assertEquals(e.module_id, null);
      assertEquals(e.group_id, groupId);
      assertEquals(e.system_event_id, event.id);
      assertEquals(e.phase_target, "phase_4");
      assertEquals(typeof e.timestamp, "string");
    }
  } finally {
    restore();
  }
});

// =============================================================================
// Phase 2 conditions — slot evaluators
// =============================================================================

const slotId = "s00000000-0000-0000-0000-000000000001";
const bookingId = "b00000000-0000-0000-0000-000000000001";

function slotContext(extras: {
  sink: ConsequenceSink;
  bookingId?: string | null;
  startsAt?: string;
  now?: Date;
}): RuleContext {
  return {
    now: extras.now ?? new Date("2026-05-04T22:00:00Z"),
    members: [memberAlice, memberBob, memberCarla],
    resource: {
      id: slotId,
      group_id: groupId,
      resource_type: "slot",
      status: extras.bookingId ? "booked" : "expired",
      metadata: {
        starts_at: extras.startsAt ?? "2026-05-05T20:30:00Z",
        ends_at: "2026-05-05T22:30:00Z",
        asset_id: "a00000000-0000-0000-0000-000000000001",
        assigned_member_id: memberAlice.id,
        booking_id: extras.bookingId ?? null,
      },
    },
    rsvps: [],
    checkIns: [],
    finesThisMonthByMember: new Map(),
    sink: extras.sink,
  };
}

Deno.test("slotIsUnassigned (booking_id=null) → condition true, consequences fire", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "shared_no_show",
    { eventType: "eventClosed", config: {} },
    [{ type: "slotIsUnassigned", config: {} }],
    [{ type: "fine", config: { amount: 200 } }],
  );

  // Use eventClosed as vehicle (slotExpired trigger lands in Slice 2.2).
  // Each active member becomes a target; condition reads context.resource.
  const ctx = slotContext({ sink, bookingId: null });
  const results = await runRulesForEvent(makeEvent("eventClosed", { resource_id: slotId }), [rule], ctx);

  // Condition true for every member → 3 fines proposed.
  assertEquals(results.length, 3);
  assertEquals(captured.length, 3);
});

Deno.test("slotIsUnassigned (booking_id present) → condition false, no fires", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "shared_no_show",
    { eventType: "eventClosed", config: {} },
    [{ type: "slotIsUnassigned", config: {} }],
    [{ type: "fine", config: { amount: 200 } }],
  );

  const ctx = slotContext({ sink, bookingId });
  const results = await runRulesForEvent(makeEvent("eventClosed", { resource_id: slotId }), [rule], ctx);

  assertEquals(results.length, 0);
  assertEquals(captured.length, 0);
});


Deno.test("slotExpiresInHours: starts within window → true", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "shared_swap_warning",
    { eventType: "eventClosed", config: {} },
    [{ type: "slotExpiresInHours", config: { hours: 24 } }],
    [{ type: "fine", config: { amount: 50 } }],
  );

  // now = 2026-05-04T22:00, slot starts = 2026-05-05T20:30 → ~22.5h away → in window
  const ctx = slotContext({ sink, bookingId: null });
  const results = await runRulesForEvent(makeEvent("eventClosed", { resource_id: slotId }), [rule], ctx);

  assertEquals(results.length, 3);
  assertEquals(captured.length, 3);
});

Deno.test("slotExpiresInHours: outside window → false", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "shared_swap_warning",
    { eventType: "eventClosed", config: {} },
    [{ type: "slotExpiresInHours", config: { hours: 6 } }],
    [{ type: "fine", config: { amount: 50 } }],
  );

  // 22.5h away with hours=6 → out of window → no fires
  const ctx = slotContext({ sink, bookingId: null });
  const results = await runRulesForEvent(makeEvent("eventClosed", { resource_id: slotId }), [rule], ctx);

  assertEquals(results.length, 0);
  assertEquals(captured.length, 0);
});

// =============================================================================
// Phase 2 triggers — slotExpired evaluator
// =============================================================================

Deno.test("slotExpired (assigned + no booking) → fines the assigned holder", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "shared_no_show",
    { eventType: "slotExpired", config: {} },
    [{ type: "slotIsUnassigned", config: {} }],
    [{ type: "fine", config: { amount: 200 } }],
  );

  // The emitter projects assigned_member_id + booking_id onto payload.
  // slotExpired returns 1 target = the assigned holder. slotIsUnassigned
  // reads target.context.booking_id (null) → true → fine fires.
  const ctx = slotContext({ sink, bookingId: null });
  const event = makeEvent("slotExpired", {
    resource_id: slotId,
    payload: {
      assigned_member_id: memberAlice.id,
      booking_id: null,
      ends_at: "2026-05-05T22:30:00Z",
      asset_id: "a00000000-0000-0000-0000-000000000001",
    },
  });
  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 1);
  assertEquals(captured.length, 1);
  assertEquals((captured[0] as { member_id: string }).member_id, memberAlice.id);
  assertEquals((captured[0] as { amount: number }).amount, 200);
});

Deno.test("slotExpired (booked) → condition false → no fine", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "shared_no_show",
    { eventType: "slotExpired", config: {} },
    [{ type: "slotIsUnassigned", config: {} }],
    [{ type: "fine", config: { amount: 200 } }],
  );

  // Booking attached → condition false → no fines (the holder did use the slot).
  const ctx = slotContext({ sink, bookingId });
  const event = makeEvent("slotExpired", {
    resource_id: slotId,
    payload: {
      assigned_member_id: memberAlice.id,
      booking_id: bookingId,
      ends_at: "2026-05-05T22:30:00Z",
    },
  });
  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 0);
  assertEquals(captured.length, 0);
});

Deno.test("slotExpired (unassigned slot) → no targets, no fines", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "shared_no_show",
    { eventType: "slotExpired", config: {} },
    [{ type: "slotIsUnassigned", config: {} }],
    [{ type: "fine", config: { amount: 200 } }],
  );

  // Slot expired without ever being assigned → can't fine anyone.
  const ctx = slotContext({ sink, bookingId: null });
  const event = makeEvent("slotExpired", {
    resource_id: slotId,
    payload: {
      assigned_member_id: null,
      booking_id: null,
      ends_at: "2026-05-05T22:30:00Z",
    },
  });
  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 0);
  assertEquals(captured.length, 0);
});

Deno.test("slotExpiresInHours: slot already started → false (no retroactive fires)", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "shared_swap_warning",
    { eventType: "eventClosed", config: {} },
    [{ type: "slotExpiresInHours", config: { hours: 24 } }],
    [{ type: "fine", config: { amount: 50 } }],
  );

  const ctx = slotContext({
    sink,
    bookingId: null,
    now: new Date("2026-05-05T22:00:00Z"), // 1.5h after slot starts_at
  });
  const results = await runRulesForEvent(makeEvent("eventClosed", { resource_id: slotId }), [rule], ctx);

  assertEquals(results.length, 0);
  assertEquals(captured.length, 0);
});

// =============================================================================
// Scope hierarchy — Taxonomy §29 / mig 00071 + 00078
//
// `runRulesForEvent` must honor rule scope (resource_id / series_id /
// membership_id) on top of group_id + is_active + trigger.eventType. Before
// these tests landed the engine ignored scope, so a rule scoped to one
// occurrence fired on every other event in the group. Audit gap #1.
// =============================================================================

const otherResourceId = "e00000000-0000-0000-0000-0000000000ff";
const seriesAlpha     = "s10000000-0000-0000-0000-000000000001";
const seriesBeta      = "s20000000-0000-0000-0000-000000000002";

Deno.test("scope: resource_id=X rule does NOT fire on an event for resource Y", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "event-specific fine",
    { eventType: "rsvpChangedSameDay", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "fine", config: { amount: 100 } }],
  );
  // Override: this rule applies only to a DIFFERENT occurrence.
  rule.resource_id = otherResourceId;

  const ctx = baseContext({ sink });
  const event = makeEvent("rsvpChangedSameDay", {
    member_id: memberAlice.id,
    resource_id: eventId, // event for a different resource than the rule targets
  });

  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 0, "out-of-scope rule should be filtered out before evaluation");
  assertEquals(captured.length, 0);
});

Deno.test("scope: resource_id=X rule fires on its own resource", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "event-specific fine",
    { eventType: "rsvpChangedSameDay", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "fine", config: { amount: 100 } }],
  );
  rule.resource_id = eventId; // applies to this exact occurrence

  const ctx = baseContext({ sink });
  const event = makeEvent("rsvpChangedSameDay", {
    member_id: memberAlice.id,
    resource_id: eventId,
  });

  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 1);
  assertEquals(results[0].success, true);
  assertEquals(captured.length, 1);
});

Deno.test("scope: series_id rule fires when occurrence belongs to that series", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "series-wide fine",
    { eventType: "rsvpChangedSameDay", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "fine", config: { amount: 100 } }],
  );
  rule.series_id = seriesAlpha;

  // Context's resource carries the matching series_id, simulating an
  // occurrence of Series Alpha.
  const ctx = baseContext({ sink });
  ctx.resource = { ...ctx.resource!, series_id: seriesAlpha };

  const event = makeEvent("rsvpChangedSameDay", {
    member_id: memberAlice.id,
    resource_id: eventId,
  });

  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 1);
  assertEquals(results[0].success, true);
  assertEquals(captured.length, 1);
});

Deno.test("scope: series_id rule does NOT fire on occurrence of a different series", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "series-wide fine (alpha)",
    { eventType: "rsvpChangedSameDay", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "fine", config: { amount: 100 } }],
  );
  rule.series_id = seriesAlpha;

  // Occurrence belongs to Series Beta, not Alpha.
  const ctx = baseContext({ sink });
  ctx.resource = { ...ctx.resource!, series_id: seriesBeta };

  const event = makeEvent("rsvpChangedSameDay", {
    member_id: memberAlice.id,
    resource_id: eventId,
  });

  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 0);
  assertEquals(captured.length, 0);
});

Deno.test("scope: series_id rule does NOT fire when occurrence has no series", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "series-wide fine",
    { eventType: "rsvpChangedSameDay", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "fine", config: { amount: 100 } }],
  );
  rule.series_id = seriesAlpha;

  // One-off resource (no series).
  const ctx = baseContext({ sink });
  ctx.resource = { ...ctx.resource!, series_id: null };

  const event = makeEvent("rsvpChangedSameDay", {
    member_id: memberAlice.id,
    resource_id: eventId,
  });

  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 0);
  assertEquals(captured.length, 0);
});

Deno.test("scope: group-level rule (no scope fields) fires regardless of resource/series", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "group-wide fine",
    { eventType: "rsvpChangedSameDay", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "fine", config: { amount: 100 } }],
  );
  // No scope set → group-level. Should still fire.

  const ctx = baseContext({ sink });
  const event = makeEvent("rsvpChangedSameDay", { member_id: memberAlice.id });

  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 1);
  assertEquals(results[0].success, true);
  assertEquals(captured.length, 1);
});

Deno.test("scope: membership_id rule fires only for the targeted member", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "alice-specific fine",
    { eventType: "eventClosed", config: {} },
    [{ type: "responseStatusIs", config: { status: "pending" } }],
    [{ type: "fine", config: { amount: 100 } }],
  );
  rule.membership_id = memberAlice.id;

  // Both Alice and Bob have pending RSVP → trigger derives 2 targets, but
  // membership scope must collapse to just Alice.
  const ctx = baseContext({
    sink,
    rsvps: [
      { member_user_id: memberAlice.user_id, status: "pending", rsvp_at: null, cancelled_same_day: false },
      { member_user_id: memberBob.user_id,   status: "pending", rsvp_at: null, cancelled_same_day: false },
    ],
  });
  const event = makeEvent("eventClosed");

  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 1, "only one target survives the membership filter");
  assertEquals((captured[0] as { member_id: string }).member_id, memberAlice.id);
});

// =============================================================================
// Most-specific-wins dedup (audit M.5) — when the same slug exists at
// multiple scopes, only the most specific should fire.
// =============================================================================

Deno.test("scope precedence: resource-scoped slug beats group-scoped slug", async () => {
  const { sink, captured } = captureSink();

  const group = makeRule(
    "group fine",
    { eventType: "rsvpChangedSameDay", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "fine", config: { amount: 100 } }],
  );
  group.slug = "rsvp_late_cancel_fine";

  const occurrence = makeRule(
    "this-event fine",
    { eventType: "rsvpChangedSameDay", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "fine", config: { amount: 250 } }],
  );
  occurrence.slug = "rsvp_late_cancel_fine";
  occurrence.resource_id = eventId;

  const ctx = baseContext({ sink });
  const event = makeEvent("rsvpChangedSameDay", { member_id: memberAlice.id });

  const results = await runRulesForEvent(event, [group, occurrence], ctx);

  assertEquals(results.length, 1, "only the resource-scoped variant fires");
  assertEquals((captured[0] as { amount: number }).amount, 250, "the resource-scoped amount wins");
});

Deno.test("scope precedence: series-scoped slug beats group-scoped slug", async () => {
  const { sink, captured } = captureSink();

  const group = makeRule(
    "group fine",
    { eventType: "rsvpChangedSameDay", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "fine", config: { amount: 100 } }],
  );
  group.slug = "rsvp_late_cancel_fine";

  const series = makeRule(
    "series fine",
    { eventType: "rsvpChangedSameDay", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "fine", config: { amount: 175 } }],
  );
  series.slug = "rsvp_late_cancel_fine";
  series.series_id = seriesAlpha;

  const ctx = baseContext({ sink });
  ctx.resource = { ...ctx.resource!, series_id: seriesAlpha };
  const event = makeEvent("rsvpChangedSameDay", { member_id: memberAlice.id });

  const results = await runRulesForEvent(event, [group, series], ctx);

  assertEquals(results.length, 1, "only the series-scoped variant fires");
  assertEquals((captured[0] as { amount: number }).amount, 175);
});

Deno.test("scope precedence: slugless rules are not deduplicated", async () => {
  const { sink, captured } = captureSink();

  const a = makeRule(
    "user rule A",
    { eventType: "rsvpChangedSameDay", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "fine", config: { amount: 100 } }],
  );
  const b = makeRule(
    "user rule B",
    { eventType: "rsvpChangedSameDay", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "fine", config: { amount: 200 } }],
  );
  // Neither carries a slug — both fire independently even though scope is identical.

  const ctx = baseContext({ sink });
  const event = makeEvent("rsvpChangedSameDay", { member_id: memberAlice.id });

  const results = await runRulesForEvent(event, [a, b], ctx);

  assertEquals(results.length, 2, "without a slug there is no dedup");
  assertEquals(captured.length, 2);
});

Deno.test("scope precedence: rules with different slugs all fire", async () => {
  const { sink, captured } = captureSink();

  const reminder = makeRule(
    "reminder rule",
    { eventType: "rsvpChangedSameDay", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "fine", config: { amount: 50 } }],
  );
  reminder.slug = "rsvp_reminder";

  const cancel = makeRule(
    "cancel-fine rule",
    { eventType: "rsvpChangedSameDay", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "fine", config: { amount: 150 } }],
  );
  cancel.slug = "rsvp_late_cancel";

  const ctx = baseContext({ sink });
  const event = makeEvent("rsvpChangedSameDay", { member_id: memberAlice.id });

  const results = await runRulesForEvent(event, [reminder, cancel], ctx);

  assertEquals(results.length, 2, "different slugs are different logical rules");
});

Deno.test("scope precedence: group rule + per-member override coexist (different dedup keys)", async () => {
  // The pre-Tier-0.5 version of this test seeded RSVPs only for Alice
  // and Bob, leaving Carla with no event_attendance row. The engine's
  // `responseStatusIs` reads `rsvp?.status ?? "pending"` (defensive),
  // so a missing RSVP defaulted to "pending" and Carla unexpectedly
  // matched the group rule's filter — producing 4 fines instead of 3.
  //
  // Production never reaches that state: `create_event_v2` seeds
  // event_attendance for every active member at event creation, so by
  // the time the eventClosed trigger runs every member has a real
  // RSVP row. The test fixture, not the engine, was the artifact.
  //
  // Fix: seed Carla with an explicit RSVP that doesn't match `pending`
  // ("going" suffices). Test now reflects the production guarantee.
  const { sink, captured } = captureSink();

  const group = makeRule(
    "group fine",
    { eventType: "eventClosed", config: {} },
    [{ type: "responseStatusIs", config: { status: "pending" } }],
    [{ type: "fine", config: { amount: 100 } }],
  );
  group.slug = "no_response_fine";

  const aliceOverride = makeRule(
    "alice override",
    { eventType: "eventClosed", config: {} },
    [{ type: "responseStatusIs", config: { status: "pending" } }],
    [{ type: "fine", config: { amount: 50 } }],
  );
  aliceOverride.slug = "no_response_fine";
  aliceOverride.membership_id = memberAlice.id;

  const ctx = baseContext({
    sink,
    rsvps: [
      { member_user_id: memberAlice.user_id, status: "pending", rsvp_at: null, cancelled_same_day: false },
      { member_user_id: memberBob.user_id,   status: "pending", rsvp_at: null, cancelled_same_day: false },
      { member_user_id: memberCarla.user_id, status: "going",   rsvp_at: "z",  cancelled_same_day: false },
    ],
  });
  const event = makeEvent("eventClosed");

  const results = await runRulesForEvent(event, [group, aliceOverride], ctx);

  // Alice's override hits her (1 result); group rule hits Alice + Bob (2 results).
  // Alice's group target overlaps with the override but both fire (different
  // dedup keys). Bob only sees the group rule. Carla (going) skipped. Total = 3.
  assertEquals(results.length, 3);
  const amounts = (captured as { member_id: string; amount: number }[]).sort(
    (a, b) => a.amount - b.amount,
  );
  assertEquals(amounts[0].amount, 50,  "alice override fired");
  assertEquals(amounts[0].member_id, memberAlice.id);
  assertEquals(amounts[1].amount, 100, "alice group rule fired");
  assertEquals(amounts[2].amount, 100, "bob group rule fired");
});

// =============================================================================
// Original "unmapped reserved type" test (preserved post scope additions)
// =============================================================================

Deno.test("unmapped reserved type → phase_target='unknown' (signals roadmap gap)", async () => {
  const { sink, captured } = captureSink();
  const { entries, restore } = captureLogs();
  try {
    // logOnly is intentionally NOT in CONSEQUENCE_PHASE — it's a V1.x utility
    // without a phase home. We expect phase_target='unknown' so a future dev
    // sees the signal "this needs a roadmap decision" rather than silent gating.
    const rule = makeRule(
      "log-only rule",
      { eventType: "rsvpChangedSameDay", config: {} },
      [{ type: "alwaysTrue", config: {} }],
      [{ type: "logOnly", config: {} }],
    );

    const ctx = baseContext({ sink });
    const event = makeEvent("rsvpChangedSameDay", { member_id: memberAlice.id });
    const results = await runRulesForEvent(event, [rule], ctx);

    assertEquals(results.length, 1);
    assertEquals(results[0].success, false);
    assertEquals(captured.length, 0);

    assertEquals(entries.length, 1);
    assertEquals(entries[0].phase_target, "unknown");
    assertEquals(entries[0].type_id, "logOnly");
    assertEquals(entries[0].engine_phase, "consequence");
  } finally {
    restore();
  }
});


// =============================================================================
// expense_threshold_warning pilot (mig 00193)
//   trigger:    ledgerEntryCreated
//   condition:  amountAbove
//   consequence: emitWarning
// =============================================================================

Deno.test("ledgerEntryCreated + amountAbove(thr=200000) → fires above threshold", async () => {
  const { sink, captured, warnings } = captureSink();
  const rule = makeRule(
    "Aviso por gasto grande",
    { eventType: "ledgerEntryCreated", config: {} },
    [{ type: "amountAbove", config: { threshold_cents: 200000 } }],
    [{ type: "emitWarning", config: {} }],
  );

  const ctx = baseContext({ sink });
  const event = makeEvent("ledgerEntryCreated", {
    id: "se-ledger-1",
    member_id: memberAlice.id,
    payload: {
      ledger_entry_id: "le-1",
      type: "expense",
      amount_cents: 350000,  // $3500 — above threshold
      currency: "MXN",
      from_member_id: null,
      to_member_id: null,
    },
  });
  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 1);
  assertEquals(results[0].success, true);
  assertEquals(captured.length, 0);                              // no fine
  assertEquals(warnings.length, 1);                              // one warning
  assertEquals((warnings[0] as { rule_id: string }).rule_id, rule.id);
  assertEquals((warnings[0] as { member_id: string }).member_id, memberAlice.id);
  assertEquals((warnings[0] as { source_atom_id: string }).source_atom_id, "se-ledger-1");
});

Deno.test("ledgerEntryCreated + amountAbove(thr=200000) → does NOT fire at/below threshold", async () => {
  const { sink, captured, warnings } = captureSink();
  const rule = makeRule(
    "Aviso por gasto grande",
    { eventType: "ledgerEntryCreated", config: {} },
    [{ type: "amountAbove", config: { threshold_cents: 200000 } }],
    [{ type: "emitWarning", config: {} }],
  );

  const ctx = baseContext({ sink });

  // Exactly at threshold — strict > comparison, no fire.
  const eventAt = makeEvent("ledgerEntryCreated", {
    id: "se-ledger-eq",
    member_id: memberAlice.id,
    payload: { amount_cents: 200000, type: "expense" },
  });
  let results = await runRulesForEvent(eventAt, [rule], ctx);
  assertEquals(results.length, 0);

  // Below threshold.
  const eventBelow = makeEvent("ledgerEntryCreated", {
    id: "se-ledger-below",
    member_id: memberAlice.id,
    payload: { amount_cents: 50000, type: "expense" },
  });
  results = await runRulesForEvent(eventBelow, [rule], ctx);
  assertEquals(results.length, 0);

  assertEquals(captured.length, 0);
  assertEquals(warnings.length, 0);
});

Deno.test("ledgerEntryCreated → no targets if event.member_id is null", async () => {
  const { sink, captured, warnings } = captureSink();
  const rule = makeRule(
    "Aviso por gasto grande",
    { eventType: "ledgerEntryCreated", config: {} },
    [{ type: "amountAbove", config: { threshold_cents: 200000 } }],
    [{ type: "emitWarning", config: {} }],
  );

  const ctx = baseContext({ sink });
  // member_id null — trigger evaluator short-circuits, no warning.
  const event = makeEvent("ledgerEntryCreated", {
    member_id: null,
    payload: { amount_cents: 999999, type: "expense" },
  });
  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 0);
  assertEquals(captured.length, 0);
  assertEquals(warnings.length, 0);
});

Deno.test("expense_threshold_vote: startVote consequence opens ledger_review vote above threshold", async () => {
  const { sink, captured, warnings, votes } = captureSink();
  const rule = makeRule(
    "Voto por gasto grande",
    { eventType: "ledgerEntryCreated", config: {} },
    [{ type: "amountAbove", config: { threshold_cents: 500000 } }],
    [{ type: "startVote", config: { vote_type: "ledger_review" } }],
  );

  const ctx = baseContext({ sink });
  const event = makeEvent("ledgerEntryCreated", {
    id: "se-ledger-vote",
    member_id: memberAlice.id,
    payload: {
      ledger_entry_id: "le-vote-1",
      type: "expense",
      amount_cents: 700000,  // $7000 — above $5000 threshold
      currency: "MXN",
    },
  });
  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 1);
  assertEquals(results[0].success, true);
  assertEquals(captured.length, 0);
  assertEquals(warnings.length, 0);
  assertEquals(votes.length, 1);
  const v = votes[0] as { vote_type: string; reference_id: string; rule_id: string };
  assertEquals(v.vote_type, "ledger_review");
  assertEquals(v.reference_id, "le-vote-1");
  assertEquals(v.rule_id, rule.id);
});

Deno.test("startVote: short-circuits when ledger_entry_id missing from context", async () => {
  const { sink, votes } = captureSink();
  const rule = makeRule(
    "Voto por gasto grande",
    { eventType: "ledgerEntryCreated", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "startVote", config: { vote_type: "ledger_review" } }],
  );

  const ctx = baseContext({ sink });
  const event = makeEvent("ledgerEntryCreated", {
    member_id: memberAlice.id,
    payload: { amount_cents: 700000 },  // no ledger_entry_id
  });
  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 1);
  assertEquals(results[0].success, false);
  assertEquals(votes.length, 0);
});

Deno.test("startVote: forwards duration_hours/quorum_percent/threshold_percent from config", async () => {
  const { sink, votes } = captureSink();
  const rule = makeRule(
    "Voto por gasto grande",
    { eventType: "ledgerEntryCreated", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{
      type: "startVote",
      config: {
        vote_type: "ledger_review",
        duration_hours: 72,
        quorum_percent: 60,
        threshold_percent: 67,
      },
    }],
  );

  const ctx = baseContext({ sink });
  const event = makeEvent("ledgerEntryCreated", {
    member_id: memberAlice.id,
    payload: { ledger_entry_id: "le-config-1", amount_cents: 700000 },
  });
  const results = await runRulesForEvent(event, [rule], ctx);

  assertEquals(results.length, 1);
  assertEquals(results[0].success, true);
  assertEquals(votes.length, 1);
  const v = votes[0] as {
    duration_hours: number | null;
    quorum_percent: number | null;
    threshold_percent: number | null;
  };
  assertEquals(v.duration_hours, 72);
  assertEquals(v.quorum_percent, 60);
  assertEquals(v.threshold_percent, 67);
});

Deno.test("startVote: defaults to null when config omits knobs (RPC fallback)", async () => {
  const { sink, votes } = captureSink();
  const rule = makeRule(
    "Voto por gasto grande",
    { eventType: "ledgerEntryCreated", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    [{ type: "startVote", config: { vote_type: "ledger_review" } }],
  );

  const ctx = baseContext({ sink });
  const event = makeEvent("ledgerEntryCreated", {
    member_id: memberAlice.id,
    payload: { ledger_entry_id: "le-noconfig", amount_cents: 700000 },
  });
  await runRulesForEvent(event, [rule], ctx);

  const v = votes[0] as {
    duration_hours: number | null;
    quorum_percent: number | null;
    threshold_percent: number | null;
  };
  assertEquals(v.duration_hours, null);
  assertEquals(v.quorum_percent, null);
  assertEquals(v.threshold_percent, null);
});
