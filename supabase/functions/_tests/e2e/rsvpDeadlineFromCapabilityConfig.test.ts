// Tier 2 (mig 00129) acceptance: the wizard's rsvp.deadline reaches
// events.rsvp_deadline.
//
// Pre-Tier-2, `build_resource_from_draft` discarded the rsvp
// capability config when calling `create_event_v2`, so the event row
// always landed with the legacy `starts_at - 4h` fallback. After mig
// 00129 the function extracts `p_capability_configs->'rsvp'->>'deadline'`
// and threads it through `p_rsvp_deadline`, making the wizard's
// choice the actual source-of-truth for `emit-deadline-events`.
//
// Three scenarios:
//   1. cap_config supplies an absolute deadline → events.rsvp_deadline
//      equals the supplied timestamp.
//   2. cap_config omits the deadline → events.rsvp_deadline falls back
//      to starts_at - 4h (existing behavior preserved).
//   3. cap_config has a malformed deadline string → silent fallback to
//      starts_at - 4h (no whole-submit abort over a single bad field).

import { assertEquals, assertExists } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";

const admin = adminClient();

interface BuildDraftArgs {
  groupId: string;
  founderClient: SeededGroup["founder"]["client"];
  startsAt: Date;
  capabilityConfigs: Record<string, unknown>;
}

async function buildEventDraft(args: BuildDraftArgs): Promise<string> {
  const { data, error } = await args.founderClient.rpc("build_resource_from_draft", {
    p_group_id:              args.groupId,
    p_resource_type:         "event",
    p_basic_fields: {
      title:           "Tier 2 deadline test",
      startsAt:        args.startsAt.toISOString(),
      durationMinutes: 180,
    },
    p_enabled_capabilities:  ["rsvp"],
    p_capability_configs:    args.capabilityConfigs,
    p_series_pattern:        null,
    p_initial_rules:         [],
  });
  if (error) throw new Error(`build_resource_from_draft: ${error.message}`);
  if (typeof data !== "string") {
    throw new Error(`build_resource_from_draft returned non-uuid: ${JSON.stringify(data)}`);
  }
  return data;
}

async function fetchEventDeadline(resourceId: string): Promise<{ rsvp_deadline: string; starts_at: string }> {
  const { data, error } = await admin
    .from("events")
    .select("rsvp_deadline, starts_at")
    .eq("id", resourceId)
    .single();
  if (error) throw new Error(`select event ${resourceId}: ${error.message}`);
  assertExists(data?.rsvp_deadline, "event must have a materialized rsvp_deadline");
  return data as { rsvp_deadline: string; starts_at: string };
}

Deno.test("Tier 2: rsvp.deadline from cap_config materializes on the event row", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({ memberSpecs: [{ handle: "alice" }], seedDinnerRules: false });

    // starts_at = +3d at exactly 21:00 UTC for a clean assertion.
    const startsAt = new Date();
    startsAt.setUTCDate(startsAt.getUTCDate() + 3);
    startsAt.setUTCHours(21, 0, 0, 0);

    // Wizard's choice: deadline at +2d 18:00 UTC (≈27h before starts_at,
    // way different from the legacy 4h fallback so the assertion is sharp).
    const chosenDeadline = new Date(startsAt);
    chosenDeadline.setUTCDate(chosenDeadline.getUTCDate() - 1);
    chosenDeadline.setUTCHours(18, 0, 0, 0);

    const resourceId = await buildEventDraft({
      groupId:        group.groupId,
      founderClient:  group.founder.client,
      startsAt,
      capabilityConfigs: {
        rsvp: { deadline: chosenDeadline.toISOString(), allowMaybe: true },
      },
    });

    const row = await fetchEventDeadline(resourceId);
    assertEquals(
      new Date(row.rsvp_deadline).getTime(),
      chosenDeadline.getTime(),
      "events.rsvp_deadline must equal the wizard's chosen timestamp",
    );
    // Sanity: starts_at unchanged.
    assertEquals(new Date(row.starts_at).getTime(), startsAt.getTime());
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 2: omitted rsvp.deadline still falls back to starts_at - 4h", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({ memberSpecs: [{ handle: "alice" }], seedDinnerRules: false });

    const startsAt = new Date();
    startsAt.setUTCDate(startsAt.getUTCDate() + 5);
    startsAt.setUTCHours(20, 0, 0, 0);

    const resourceId = await buildEventDraft({
      groupId:        group.groupId,
      founderClient:  group.founder.client,
      startsAt,
      capabilityConfigs: { rsvp: { allowMaybe: false } }, // no deadline
    });

    const row = await fetchEventDeadline(resourceId);
    const expected = new Date(startsAt.getTime() - 4 * 60 * 60 * 1000);
    assertEquals(
      new Date(row.rsvp_deadline).getTime(),
      expected.getTime(),
      "without rsvp.deadline, events.rsvp_deadline must keep the legacy T-4h fallback",
    );
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 2: malformed rsvp.deadline silently falls back instead of aborting submit", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({ memberSpecs: [{ handle: "alice" }], seedDinnerRules: false });

    const startsAt = new Date();
    startsAt.setUTCDate(startsAt.getUTCDate() + 4);
    startsAt.setUTCHours(19, 0, 0, 0);

    const resourceId = await buildEventDraft({
      groupId:        group.groupId,
      founderClient:  group.founder.client,
      startsAt,
      capabilityConfigs: { rsvp: { deadline: "not-a-timestamp" } },
    });

    const row = await fetchEventDeadline(resourceId);
    const expected = new Date(startsAt.getTime() - 4 * 60 * 60 * 1000);
    assertEquals(
      new Date(row.rsvp_deadline).getTime(),
      expected.getTime(),
      "malformed rsvp.deadline must fall back to T-4h (atomic submit shouldn't abort)",
    );
  } finally {
    if (group) await cleanupGroup(group);
  }
});
