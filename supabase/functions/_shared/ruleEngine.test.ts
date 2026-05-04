// Rule engine unit tests — exercise the 5 default "Cena recurrente" rules
// against fabricated SystemEvent + RuleContext fixtures. Run with:
//
//   deno test supabase/functions/_shared/ruleEngine.test.ts
//
// No Supabase calls. The ConsequenceSink is an in-memory recorder, so every
// fine the engine "creates" is observable as a captured object.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { runRulesForEvent, type ConsequenceSink, type RuleContext } from "./ruleEngine.ts";
import type { Rule, SystemEvent } from "./platformTypes.ts";

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
  for (const fine of captured as Array<{ amount: number; member_id: string }>) {
    assertEquals(fine.amount, 200);
    assertEquals([memberBob.id, memberCarla.id].includes(fine.member_id), true);
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

Deno.test("unimplemented consequence → records failure, does not throw", async () => {
  const { sink, captured } = captureSink();
  const rule = makeRule(
    "future rule",
    { eventType: "eventClosed", config: {} },
    [{ type: "alwaysTrue", config: {} }],
    // loseTurn is declared in the enum but has no executor in V1.
    [{ type: "loseTurn", config: {} }],
  );

  const ctx = baseContext({ sink });
  const results = await runRulesForEvent(makeEvent("eventClosed"), [rule], ctx);

  // 3 active members × 1 unimplemented consequence = 3 failure rows
  assertEquals(results.length, 3);
  for (const r of results) {
    assertEquals(r.success, false);
    assertEquals(r.error?.includes("unimplemented consequence"), true);
  }
  assertEquals(captured.length, 0);
});
