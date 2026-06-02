// Tier 4 (mig 00131) acceptance: emit-event-reminder-events emits
// synthetic `hoursBeforeEvent` system_events for events that fall
// inside the (now+N-1h, now+Nh] window of an active rule.
//
// Pre-Tier-4, the trigger had a rule engine evaluator (since 00014)
// but no upstream emitter — `dinner_host_no_menu` rules sat dormant
// in prod. This test exercises the loop end-to-end against the fresh
// cron + local supabase.
//
// Three scenarios:
//   1. Active rule with hoursBeforeEvent.config.hours=24 + event
//      23.5h ahead → cron emits one system_event with payload.hours=24.
//      Re-invoking the cron is a no-op (dedup via existing system_event).
//   2. Event 5h ahead with no rule covering N=5 → cron emits nothing
//      (window-clean): the 24h rule's window of (23h, 24h] excludes 5h.
//   3. Two active rules (N=24 and N=6) + one event 5.5h ahead →
//      cron emits one row with payload.hours=6 (matches the 6h rule's
//      window), not 24 (out of range).

import { assertEquals, assertGreaterOrEqual } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";
import { invokeCron } from "./_fixtures/invokeCron.ts";

const admin = adminClient();

interface InsertedRule { id: string; }

async function insertHoursBeforeRule(
  groupId: string,
  hours: number,
  slug: string,
): Promise<string> {
  const { data, error } = await admin
    .from("rules")
    .insert({
      group_id: groupId,
      name: `Recordatorio ${hours}h (e2e)`,
      slug,
      is_active: true,
      trigger: { eventType: "hoursBeforeEvent", config: { hours } },
      conditions: [],
      consequences: [{ type: "sendNotification", config: {} }],
    })
    .select("id")
    .single();
  if (error || !data) throw new Error(`rule insert failed: ${error?.message}`);
  return (data as InsertedRule).id;
}

async function createEventStartingAt(
  groupId: string,
  founderClient: SeededGroup["founder"]["client"],
  startsAt: Date,
): Promise<string> {
  const { data, error } = await founderClient.rpc("create_event_v2", {
    p_group_id:  groupId,
    p_title:     "Reminder e2e",
    p_starts_at: startsAt.toISOString(),
  });
  if (error) throw new Error(`create_event_v2: ${error.message}`);
  // create_event_v2 returns the events row (full record) — supabase-js
  // surfaces the .id field directly.
  if (data && typeof data === "object" && "id" in data) {
    return (data as { id: string }).id;
  }
  if (typeof data === "string") return data;
  throw new Error(`create_event_v2 returned shape we can't unwrap: ${JSON.stringify(data)}`);
}

async function fetchReminderEvents(resourceId: string) {
  const { data, error } = await admin
    .from("system_events")
    .select("id, resource_id, payload")
    .eq("event_type", "hoursBeforeEvent")
    .eq("resource_id", resourceId);
  if (error) throw new Error(`select system_events: ${error.message}`);
  return (data ?? []) as Array<{ id: string; resource_id: string; payload: { hours?: number; starts_at?: string } }>;
}

Deno.test("Tier 4: 24h rule + event in (23h, 24h] → emits one hoursBeforeEvent (idempotent)", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    // Wipe template-seeded rules so the only active rule is our 24h one.
    await admin.from("rules").delete().eq("group_id", group.groupId);
    await insertHoursBeforeRule(group.groupId, 24, "reminder_24h_e2e");

    // Pin the cron clock to a fixed instant. Event lands 23.5h ahead so
    // it sits squarely inside (now + 23h, now + 24h].
    const clockNow = new Date();
    const startsAt = new Date(clockNow.getTime() + 23.5 * 3_600_000);
    const eventId = await createEventStartingAt(group.groupId, group.founder.client, startsAt);

    const r1 = await invokeCron("emit-event-reminder-events", { clockOverride: clockNow });
    assertEquals(r1.ok, true, `first invoke failed: ${JSON.stringify(r1.body)}`);

    const rows1 = await fetchReminderEvents(eventId);
    assertEquals(rows1.length, 1, "expect exactly one hoursBeforeEvent emitted");
    assertEquals(rows1[0].payload.hours, 24, "payload.hours must be 24");

    // Second invocation: dedup must skip. No second row.
    const r2 = await invokeCron("emit-event-reminder-events", { clockOverride: clockNow });
    assertEquals(r2.ok, true, `second invoke failed: ${JSON.stringify(r2.body)}`);
    const rows2 = await fetchReminderEvents(eventId);
    assertEquals(rows2.length, 1, "second invocation must be a no-op (dedup)");
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 4: event 5h ahead with only a 24h rule → no emission (window-clean)", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    await admin.from("rules").delete().eq("group_id", group.groupId);
    await insertHoursBeforeRule(group.groupId, 24, "reminder_24h_e2e");

    const clockNow = new Date();
    const startsAt = new Date(clockNow.getTime() + 5 * 3_600_000);
    const eventId = await createEventStartingAt(group.groupId, group.founder.client, startsAt);

    const r = await invokeCron("emit-event-reminder-events", { clockOverride: clockNow });
    assertEquals(r.ok, true);

    const rows = await fetchReminderEvents(eventId);
    assertEquals(rows.length, 0, "event 5h out must not match the 24h rule's window");
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 4: two rules (24h, 6h) + event 5.5h ahead → matches the 6h rule only", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    await admin.from("rules").delete().eq("group_id", group.groupId);
    await insertHoursBeforeRule(group.groupId, 24, "reminder_24h_e2e");
    await insertHoursBeforeRule(group.groupId, 6,  "reminder_6h_e2e");

    const clockNow = new Date();
    const startsAt = new Date(clockNow.getTime() + 5.5 * 3_600_000);
    const eventId = await createEventStartingAt(group.groupId, group.founder.client, startsAt);

    const r = await invokeCron("emit-event-reminder-events", { clockOverride: clockNow });
    assertEquals(r.ok, true);

    const rows = await fetchReminderEvents(eventId);
    assertEquals(rows.length, 1, "exactly one emission for the 6h rule");
    assertEquals(rows[0].payload.hours, 6, "payload.hours must be 6 (the only matching window)");

    // Sanity: scanned counter from response body sees at least one event.
    if (typeof r.body === "object" && r.body !== null) {
      const b = r.body as { scanned?: number; emitted?: number };
      assertGreaterOrEqual(b.scanned ?? 0, 1);
      assertEquals(b.emitted ?? 0, 1);
    }
  } finally {
    if (group) await cleanupGroup(group);
  }
});
