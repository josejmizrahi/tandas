// Tier 5 Beta (mig 00132) acceptance: rotation capability on series.
//
// Three scenarios:
//   1. Unit-ish: next_host_for_series with a synthetic series row,
//      order=sequential, 3 participants → cycles 1..6 visit each
//      participant twice in declared order.
//   2. replacementPolicy=skip_to_next: one participant gets deactivated,
//      next_host_for_series skips them and picks the next active one.
//   3. End-to-end: build_resource_from_draft creates a series with
//      rotation cap_config; auto-generate-events emits 3 occurrences;
//      events.host_id of each occurrence rotates A → B → C in declared
//      order.
//
// Out of scope (per founder 2026-05-13):
//   - rotation as standalone resource_type
//   - swap requests
//   - rotation shared across multiple resources

import { assertEquals, assertExists } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";
import { invokeCron } from "./_fixtures/invokeCron.ts";

const admin = adminClient();

async function callNextHost(seriesId: string, cycle: number): Promise<string | null> {
  const { data, error } = await admin.rpc("next_host_for_series", {
    p_series_id: seriesId,
    p_cycle:     cycle,
  });
  if (error) throw new Error(`next_host_for_series: ${error.message}`);
  return typeof data === "string" ? data : null;
}

async function insertSeriesWithRotation(
  groupId: string,
  participants: string[],
  opts: { order?: "sequential" | "random"; replacementPolicy?: string } = {},
): Promise<string> {
  const { data, error } = await admin
    .from("resource_series")
    .insert({
      group_id: groupId,
      resource_type: "event",
      pattern: {
        frequency:    "weekly",
        dayOfWeek:    4, // Thursday
        hour:         20,
        minute:       0,
        endCondition: "never",
        timezone:     "UTC",
      },
      metadata: {
        title: "Cena rotativa (e2e)",
        duration_minutes: 180,
        capability_configs: {
          rotation: {
            purpose: "host",
            participants,
            order: opts.order ?? "sequential",
            frequency: "every_event",
            replacementPolicy: opts.replacementPolicy ?? "skip_to_next",
          },
        },
      },
      active: true,
      created_by: participants[0],
    })
    .select("id")
    .single();
  if (error || !data) throw new Error(`series insert failed: ${error?.message}`);
  return (data as { id: string }).id;
}

Deno.test("Tier 5: sequential rotation cycles through participants in declared order", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }, { handle: "carla" }],
      seedDinnerRules: false,
    });
    const userIds = group.members.map((m) => m.userId);
    const seriesId = await insertSeriesWithRotation(group.groupId, userIds);

    // Cycles 1..6 must visit [alice, bob, carla, alice, bob, carla].
    const expected = [userIds[0], userIds[1], userIds[2], userIds[0], userIds[1], userIds[2]];
    for (let cycle = 1; cycle <= 6; cycle++) {
      const host = await callNextHost(seriesId, cycle);
      assertEquals(host, expected[cycle - 1], `cycle ${cycle} should be ${expected[cycle - 1]}`);
    }
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 5: replacementPolicy=skip_to_next skips an inactive participant", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }, { handle: "carla" }],
      seedDinnerRules: false,
    });
    const userIds = group.members.map((m) => m.userId);
    const seriesId = await insertSeriesWithRotation(group.groupId, userIds, {
      replacementPolicy: "skip_to_next",
    });

    // Deactivate Bob (index 1). Cycle 2 normally picks Bob → with
    // skip_to_next it should advance to Carla.
    await admin.from("group_members")
      .update({ active: false })
      .eq("group_id", group.groupId)
      .eq("user_id", userIds[1]);

    const cycle1 = await callNextHost(seriesId, 1); // Alice
    const cycle2 = await callNextHost(seriesId, 2); // Bob → skip → Carla
    const cycle3 = await callNextHost(seriesId, 3); // Carla (already)

    assertEquals(cycle1, userIds[0], "cycle 1 = alice");
    assertEquals(cycle2, userIds[2], "cycle 2 = carla (skipped bob)");
    assertEquals(cycle3, userIds[2], "cycle 3 = carla (own slot)");
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 5: hostAssigned user_action emitted for each rotation-resolved occurrence", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }, { handle: "carla" }],
      seedDinnerRules: false,
    });
    const userIds = group.members.map((m) => m.userId);

    const startDate = new Date();
    startDate.setUTCDate(startDate.getUTCDate() + 1);
    const startDateStr = startDate.toISOString().slice(0, 10);
    const dayOfWeek = startDate.getUTCDay();

    const { data: series, error: insErr } = await admin
      .from("resource_series")
      .insert({
        group_id: group.groupId,
        resource_type: "event",
        active: true,
        pattern: {
          frequency: "weekly",
          dayOfWeek: dayOfWeek,
          hour: 20,
          minute: 0,
          startDate: startDateStr,
          endCondition: "never",
          timezone: "UTC",
        },
        metadata: {
          title: "Cena rotativa (inbox e2e)",
          duration_minutes: 180,
          capability_configs: {
            rotation: {
              purpose: "host",
              participants: userIds,
              order: "sequential",
              frequency: "every_event",
              replacementPolicy: "skip_to_next",
            },
          },
        },
        created_by: userIds[0],
      })
      .select("id")
      .single();
    if (insErr || !series) throw new Error(`series insert: ${insErr?.message}`);
    const seriesId = (series as { id: string }).id;

    const r = await invokeCron("auto-generate-events");
    if (!r.ok) throw new Error(`auto-generate-events failed: ${JSON.stringify(r.body)}`);

    // Read the first 3 events generated.
    const { data: events, error: evErr } = await admin
      .from("events")
      .select("id, host_id, cycle_number, created_by")
      .eq("series_id", seriesId)
      .order("starts_at", { ascending: true })
      .limit(3);
    if (evErr || !events) throw new Error(`events select: ${evErr?.message}`);
    assertEquals(events.length, 3, "expect 3 occurrences");

    // For each rotation-resolved occurrence, the trigger from mig 00133
    // should have inserted a hostAssigned user_action targeted at the
    // resolved host. created_by is NULL because auto-generate-events
    // runs as service_role — so the (host_id != created_by) gate fires.
    for (const ev of events) {
      const { data: actions, error: actErr } = await admin
        .from("user_actions")
        .select("user_id, action_type, reference_id, title")
        .eq("action_type", "hostAssigned")
        .eq("reference_id", ev.id);
      if (actErr) throw new Error(`user_actions select for ${ev.id}: ${actErr.message}`);
      assertEquals(
        actions?.length,
        1,
        `expect exactly one hostAssigned user_action for event ${ev.id} (cycle ${ev.cycle_number})`,
      );
      assertEquals(
        actions![0].user_id,
        ev.host_id,
        `hostAssigned user_action user_id must match the event's host_id`,
      );
    }
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 5: auto-generate-events forwards rotation host_id to occurrences", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }, { handle: "carla" }],
      seedDinnerRules: false,
    });
    const userIds = group.members.map((m) => m.userId);

    // Pattern shape matches recurrenceGenerator.test.ts (the flat
    // weekly form supported by _shared/recurrence.ts): frequency +
    // dayOfWeek + hour + minute + startDate + endCondition.
    const startDate = new Date();
    startDate.setUTCDate(startDate.getUTCDate() + 1); // tomorrow
    const startDateStr = startDate.toISOString().slice(0, 10);
    const dayOfWeek = startDate.getUTCDay();

    const { data: series, error: insErr } = await admin
      .from("resource_series")
      .insert({
        group_id: group.groupId,
        resource_type: "event",
        active: true,
        pattern: {
          frequency:    "weekly",
          dayOfWeek:    dayOfWeek,
          hour:         20,
          minute:       0,
          startDate:    startDateStr,
          endCondition: "never",
          timezone:     "UTC",
        },
        metadata: {
          title: "Cena rotativa weekly (e2e)",
          duration_minutes: 180,
          capability_configs: {
            rotation: {
              purpose: "host",
              participants: userIds,
              order: "sequential",
              frequency: "every_event",
              replacementPolicy: "skip_to_next",
            },
          },
        },
        created_by: userIds[0],
      })
      .select("id")
      .single();
    if (insErr || !series) throw new Error(`series insert: ${insErr?.message}`);
    const seriesId = (series as { id: string }).id;

    const r = await invokeCron("auto-generate-events");
    if (!r.ok) throw new Error(`auto-generate-events failed: ${JSON.stringify(r.body)}`);

    // Fetch the first 3 occurrences by starts_at asc.
    const { data: events, error: evErr } = await admin
      .from("events")
      .select("id, host_id, starts_at, cycle_number")
      .eq("series_id", seriesId)
      .order("starts_at", { ascending: true })
      .limit(3);
    if (evErr) throw new Error(`events select: ${evErr.message}`);
    assertExists(events, "expect events generated");
    assertEquals(events!.length, 3, "expect at least 3 occurrences in horizon");

    // Hosts must rotate sequentially: occurrence[0]=alice, [1]=bob, [2]=carla.
    assertEquals(events![0].host_id, userIds[0], "occurrence 1 host = alice");
    assertEquals(events![1].host_id, userIds[1], "occurrence 2 host = bob");
    assertEquals(events![2].host_id, userIds[2], "occurrence 3 host = carla");
  } finally {
    if (group) await cleanupGroup(group);
  }
});
