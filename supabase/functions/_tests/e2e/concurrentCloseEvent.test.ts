// Concurrent close_event race regression test (V1-02).
//
// Pre-mig-00349, two admins clicking "Close" on the same event nearly
// simultaneously would both pass through the unlocked SELECT + UPDATE,
// and BOTH would call `record_system_event('eventClosed', ...)` —
// system_events ended up with two `eventClosed` atoms for the same
// resource. process-system-events evaluates each atom independently,
// so the rule engine fires fines twice for every late attendee.
//
// Mig 00349 mirrors the pay_fine FOR UPDATE pattern (mig 00146):
//   - SELECT ... FOR UPDATE serializes concurrent callers.
//   - Idempotent early return when status='completed'.
//   - WHERE status<>'completed' guard + GET DIAGNOSTICS row_count
//     defends against any caller that bypasses the lock.
//
// This test fires two parallel close_event() calls and asserts:
//   1. The RPC returns the same view row for both callers (no exception).
//   2. Exactly ONE `eventClosed` system_event row exists for the resource.
//   3. After process-system-events runs the rule engine, Bob has exactly
//      ONE fine — not two.
//   4. A sequential 3rd call to close_event is a no-op (no new atom, no
//      new fine).

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { extractRowId, seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";
import { invokeCron } from "./_fixtures/invokeCron.ts";

const admin = adminClient();

Deno.test("close_event race: two parallel calls → exactly one eventClosed atom + one fine", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [
        { handle: "alice" },   // founder, will close the event
        { handle: "bob" },     // infractor (late check-in)
        { handle: "carla" },
      ],
      seedDinnerRules: true,
    });
    const [alice, bob] = group.members;

    // Activate "Llegada tardía" only — same setup as appealQuorumFailed.
    await admin.from("rules")
      .update({ is_active: false })
      .eq("group_id", group.groupId);
    await admin.from("rules")
      .update({ is_active: true })
      .eq("group_id", group.groupId)
      .eq("name", "Llegada tardía");

    // Create event 90 min ago. Bob RSVPs going + arrives 75 min late.
    const startsAt = new Date(Date.now() - 90 * 60_000);
    const { data: createResult, error: createErr } = await alice.client.rpc(
      "create_event_v2",
      {
        p_group_id:  group.groupId,
        p_title:     "Cena del martes",
        p_starts_at: startsAt.toISOString(),
        p_host_id:   alice.userId,
      },
    );
    if (createErr) throw new Error(`create_event_v2: ${createErr.message}`);
    const eventId = extractRowId(createResult);
    if (!eventId) throw new Error(`create_event_v2 returned no id: ${JSON.stringify(createResult)}`);

    await bob.client.rpc("set_rsvp_v2", { p_event_id: eventId, p_status: "going" });
    await alice.client.rpc("check_in_attendee", {
      p_event_id:   eventId,
      p_user_id:    bob.userId,
      p_arrived_at: new Date(startsAt.getTime() + 75 * 60_000).toISOString(),
    });

    await admin.from("system_events").insert({
      group_id:    group.groupId,
      event_type:  "checkInRecorded",
      resource_id: eventId,
      member_id:   bob.memberId,
      payload:     { method: "qr", late_minutes: 75 },
    });

    // ────────────────────────────────────────────────────────────
    // Fire two parallel close_event() calls on the same event. Pre-fix
    // both would emit an eventClosed atom. Post-fix the FOR UPDATE
    // serializes them: B blocks until A commits, then B sees
    // status='completed' and returns idempotently without re-emitting.
    // ────────────────────────────────────────────────────────────

    const [resA, resB] = await Promise.allSettled([
      alice.client.rpc("close_event", { p_event_id: eventId }),
      alice.client.rpc("close_event", { p_event_id: eventId }),
    ]);

    // Both calls must succeed (idempotent — no exception on the loser).
    if (resA.status !== "fulfilled" || resA.value.error) {
      throw new Error(`close_event call A failed: ${JSON.stringify(resA)}`);
    }
    if (resB.status !== "fulfilled" || resB.value.error) {
      throw new Error(`close_event call B failed: ${JSON.stringify(resB)}`);
    }

    // Exactly ONE eventClosed atom must exist for this resource.
    const { count: closedCount, error: closedErr } = await admin
      .from("system_events")
      .select("*", { count: "exact", head: true })
      .eq("resource_id", eventId)
      .eq("event_type", "eventClosed");
    if (closedErr) throw new Error(`count eventClosed failed: ${closedErr.message}`);
    assertEquals(closedCount, 1, "exactly one eventClosed atom expected; pre-fix would have produced 2");

    // Resource status must be 'completed' from the first writer's UPDATE.
    const { data: resourceRow } = await admin
      .from("resources")
      .select("status")
      .eq("id", eventId)
      .single();
    assertEquals(resourceRow?.status, "completed");

    // ────────────────────────────────────────────────────────────
    // Run the rule engine. Pre-fix two eventClosed atoms → two
    // late-arrival fines for Bob. Post-fix exactly one.
    // ────────────────────────────────────────────────────────────

    await invokeCron("process-system-events");

    const { count: fineCount, error: fineErr } = await admin
      .from("fines")
      .select("*", { count: "exact", head: true })
      .eq("group_id", group.groupId)
      .eq("user_id", bob.userId);
    if (fineErr) throw new Error(`count fines failed: ${fineErr.message}`);
    assertEquals(fineCount, 1, "Bob must have exactly one fine; pre-fix would have produced 2");

    // ────────────────────────────────────────────────────────────
    // A sequential 3rd close on the same already-closed event must
    // be a no-op: no new atom, no new fine. Verifies the idempotent
    // early-return path.
    // ────────────────────────────────────────────────────────────

    const { data: thirdData, error: thirdErr } = await alice.client.rpc(
      "close_event",
      { p_event_id: eventId },
    );
    if (thirdErr) throw new Error(`3rd close_event failed: ${thirdErr.message}`);
    assertEquals((thirdData as { status: string } | null)?.status, "completed");

    const { count: closedCountAfter } = await admin
      .from("system_events")
      .select("*", { count: "exact", head: true })
      .eq("resource_id", eventId)
      .eq("event_type", "eventClosed");
    assertEquals(closedCountAfter, 1, "3rd close_event must NOT emit a new eventClosed atom");

    await invokeCron("process-system-events");
    const { count: fineCountAfter } = await admin
      .from("fines")
      .select("*", { count: "exact", head: true })
      .eq("group_id", group.groupId)
      .eq("user_id", bob.userId);
    assertEquals(fineCountAfter, 1, "3rd close_event must NOT trigger a duplicate fine");
  } finally {
    if (group) await cleanupGroup(group);
  }
});
