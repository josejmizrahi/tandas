// Concurrent reopen_event race regression test (V1-06).
//
// Pre-mig-00350, two admins clicking "Reopen" on the same closed event
// near-simultaneously both passed an unlocked SELECT + the
// `status IN ('completed','cancelled')` snapshot check, both UPDATEd
// the resources row (Postgres serialized the writes, both succeeded),
// and BOTH called record_system_event('eventReopened') → duplicate atoms.
// Today no rule has eventReopened as its trigger so the bug doesn't fire
// fines, but it corrupts the causal-chain projection (reopen cycle
// count is off by one) and any future rule with that trigger would
// double-fire.
//
// Mig 00350 mirrors the pay_fine / close_event FOR UPDATE pattern.
//
// This test fires two parallel reopen_event() calls and asserts:
//   1. Both callers fulfilled (idempotent — no exception on the loser).
//   2. Exactly ONE `eventReopened` system_event row exists for the resource.
//   3. The event's status is back to 'scheduled'.
//   4. A sequential 3rd call to reopen_event on an already-scheduled
//      event is a no-op (no new atom).
//   5. Closing again + reopening again (second cycle) DOES emit a new
//      atom — verifies the fix doesn't break the legitimate
//      close→reopen→close→reopen cycle.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { extractRowId, seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";

const admin = adminClient();

Deno.test("reopen_event race: two parallel calls → exactly one eventReopened atom; cycle still works", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [
        { handle: "alice" },   // founder + host
        { handle: "bob" },
      ],
      seedDinnerRules: false,
    });
    const [alice] = group.members;

    // Create an event and close it via the no-fines variant so we don't
    // pollute the test with rule-engine side effects.
    const startsAt = new Date(Date.now() - 60 * 60_000);
    const { data: createResult, error: createErr } = await alice.client.rpc(
      "create_event_v2",
      {
        p_group_id:  group.groupId,
        p_title:     "Reopen race test",
        p_starts_at: startsAt.toISOString(),
        p_host_id:   alice.userId,
      },
    );
    if (createErr) throw new Error(`create_event_v2: ${createErr.message}`);
    const eventId = extractRowId(createResult);
    if (!eventId) throw new Error(`create_event_v2 returned no id: ${JSON.stringify(createResult)}`);

    const { error: closeErr } = await alice.client.rpc(
      "close_event_no_fines",
      { p_event_id: eventId },
    );
    if (closeErr) throw new Error(`close_event_no_fines: ${closeErr.message}`);

    // Sanity: event is completed and there's exactly one eventClosed atom.
    const { count: closedCount } = await admin
      .from("system_events")
      .select("*", { count: "exact", head: true })
      .eq("resource_id", eventId)
      .eq("event_type", "eventClosed");
    assertEquals(closedCount, 1, "setup: expected one eventClosed atom before reopen test");

    // ────────────────────────────────────────────────────────────
    // Fire two parallel reopen_event() calls on the same event.
    // Pre-fix both would emit an eventReopened atom. Post-fix FOR
    // UPDATE serializes them: B blocks until A commits, then B sees
    // status='scheduled' and returns idempotently without re-emitting.
    // ────────────────────────────────────────────────────────────

    const [resA, resB] = await Promise.allSettled([
      alice.client.rpc("reopen_event", { p_event_id: eventId }),
      alice.client.rpc("reopen_event", { p_event_id: eventId }),
    ]);

    if (resA.status !== "fulfilled" || resA.value.error) {
      throw new Error(`reopen_event call A failed: ${JSON.stringify(resA)}`);
    }
    if (resB.status !== "fulfilled" || resB.value.error) {
      throw new Error(`reopen_event call B failed: ${JSON.stringify(resB)}`);
    }

    // Exactly ONE eventReopened atom must exist for this resource.
    const { count: reopenedCount, error: reopenedErr } = await admin
      .from("system_events")
      .select("*", { count: "exact", head: true })
      .eq("resource_id", eventId)
      .eq("event_type", "eventReopened");
    if (reopenedErr) throw new Error(`count eventReopened failed: ${reopenedErr.message}`);
    assertEquals(reopenedCount, 1, "exactly one eventReopened atom expected; pre-fix would have produced 2");

    // Resource status must be 'scheduled' from the first writer's UPDATE.
    const { data: resourceRow } = await admin
      .from("resources")
      .select("status")
      .eq("id", eventId)
      .single();
    assertEquals(resourceRow?.status, "scheduled");

    // ────────────────────────────────────────────────────────────
    // Sequential 3rd reopen on an already-scheduled event is a no-op:
    // exercises the idempotent early-return path (status NOT IN
    // (completed, cancelled)).
    // ────────────────────────────────────────────────────────────

    const { error: thirdErr } = await alice.client.rpc(
      "reopen_event",
      { p_event_id: eventId },
    );
    if (thirdErr) throw new Error(`3rd reopen_event failed: ${thirdErr.message}`);

    const { count: reopenedCountAfter3rd } = await admin
      .from("system_events")
      .select("*", { count: "exact", head: true })
      .eq("resource_id", eventId)
      .eq("event_type", "eventReopened");
    assertEquals(reopenedCountAfter3rd, 1, "3rd reopen on already-scheduled event must NOT emit a new atom");

    // ────────────────────────────────────────────────────────────
    // Close again + reopen again — second cycle must produce a NEW
    // eventReopened atom. Verifies the fix doesn't break the
    // legitimate close→reopen→close→reopen flow.
    // ────────────────────────────────────────────────────────────

    const { error: closeAgainErr } = await alice.client.rpc(
      "close_event_no_fines",
      { p_event_id: eventId },
    );
    if (closeAgainErr) throw new Error(`2nd close_event_no_fines: ${closeAgainErr.message}`);

    const { error: reopenAgainErr } = await alice.client.rpc(
      "reopen_event",
      { p_event_id: eventId },
    );
    if (reopenAgainErr) throw new Error(`2nd reopen_event: ${reopenAgainErr.message}`);

    const { count: reopenedCountAfter2ndCycle } = await admin
      .from("system_events")
      .select("*", { count: "exact", head: true })
      .eq("resource_id", eventId)
      .eq("event_type", "eventReopened");
    assertEquals(reopenedCountAfter2ndCycle, 2, "second close→reopen cycle MUST emit a new eventReopened atom");

    const { count: closedCountFinal } = await admin
      .from("system_events")
      .select("*", { count: "exact", head: true })
      .eq("resource_id", eventId)
      .eq("event_type", "eventClosed");
    assertEquals(closedCountFinal, 2, "two close cycles → two eventClosed atoms");
  } finally {
    if (group) await cleanupGroup(group);
  }
});
