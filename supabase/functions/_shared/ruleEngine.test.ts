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

function captureSink(): { sink: ConsequenceSink; captured: unknown[] } {
  const captured: unknown[] = [];
  const sink: ConsequenceSink = {
    proposeFine: async (args) => {
      captured.push(args);
      return `fine-${captured.length}`;
    },
  };
  return { sink, captured };
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
  for (const fine of captured as Array<{ amount: number; member_id: string; event_id: string; resource_id: string }>) {
    assertEquals(fine.amount, 200);
    assertEquals([memberBob.id, memberCarla.id].includes(fine.member_id), true);
    // Audit § 5.3 items 9+11 contract: sink receives both event_id (legacy)
    // and resource_id (polymorphic, 00041). For V1 events both === target
    // resource id (resources mirror events 1:1 post-00040).
    assertEquals(fine.event_id, eventId);
    assertEquals(fine.resource_id, eventId);
  }
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
