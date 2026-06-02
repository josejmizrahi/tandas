// Recurrence end-to-end: resource_series → auto-generate-events cron
// → events table populated with correct series_id + starts_at + idempotent
// on re-run.
//
// Tier 1 (2026-05-12) acceptance: this is the test that closes the
// "recurrence visible only if complete e2e" criterion. If it goes red
// in CI, RecurrenceCapability stays .incomplete in the iOS catalog.
//
// What this exercises:
//   - resource_series row insert (skips the iOS wizard — direct DB)
//   - auto-generate-events cron (post-Tier-1.5 rewrite)
//   - _shared/recurrence.ts pattern generator (post-Tier-1.6)
//   - create_event_v2 with p_series_id (mig 00126)
//   - uniq_events_series_starts_at unique constraint (mig 00126)
//
// NOT covered here (covered by separate tests):
//   - iOS wizard step 3 + step 4 (covered by SwiftUI snapshot/unit)
//   - build_resource_from_draft creating the series row (covered by
//     iOS LiveResourceDraftRepository test once wired)

import { assertEquals, assertGreaterOrEqual } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";
import { invokeCron } from "./_fixtures/invokeCron.ts";

const admin = adminClient();

Deno.test("recurrence: weekly Thursday, never end → cron generates horizon-worth of events with series_id", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,  // keep the test focused
    });

    // Insert a series with a pattern that starts in the near future.
    // The cron uses a 60-day horizon by default, so a weekly series
    // should yield ~9 occurrences.
    const startDate = new Date();
    startDate.setUTCDate(startDate.getUTCDate() + 1); // tomorrow
    const startDateStr = startDate.toISOString().slice(0, 10);

    // dayOfWeek must match the eventual first occurrence's UTC weekday;
    // we pick "tomorrow's DOW" so firstOccurrence is exactly tomorrow.
    const dayOfWeek = startDate.getUTCDay();

    const { data: series, error: insErr } = await admin
      .from("resource_series")
      .insert({
        group_id:      group.groupId,
        resource_type: "event",
        active:        true,
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
          title: "Cena recurrente E2E",
          duration_minutes: 180,
        },
      })
      .select("id")
      .single();
    if (insErr || !series) throw new Error(`resource_series insert: ${insErr?.message}`);

    // ─────────────────────────────────────────────────────────────────
    // STEP 1 — first cron run.
    // ─────────────────────────────────────────────────────────────────

    const run1 = await invokeCron("auto-generate-events");
    assertEquals(run1.ok, true, `auto-generate-events run 1 failed: ${JSON.stringify(run1.body)}`);

    // §14 step 5c-iv: events table dropped — read via projection.
    const { data: events1, error: e1Err } = await admin
      .from("events_view")
      .select("id, series_id, starts_at")
      .eq("series_id", series.id)
      .order("starts_at", { ascending: true });
    if (e1Err) throw new Error(`events select run 1: ${e1Err.message}`);

    // 60 days / 7 ≈ 8-9 weekly occurrences (caps at MAX_PER_SERIES=20).
    assertGreaterOrEqual(events1?.length ?? 0, 8);

    // Every event must have series_id set (mig 00126 dual-write).
    for (const ev of events1 ?? []) {
      assertEquals(ev.series_id, series.id, "every generated event must carry series_id");
    }

    // First event lands on the expected date+time.
    const firstStartsAt = new Date(events1![0].starts_at);
    assertEquals(firstStartsAt.toISOString().slice(0, 10), startDateStr);
    assertEquals(firstStartsAt.getUTCHours(), 20);
    assertEquals(firstStartsAt.getUTCMinutes(), 0);
    assertEquals(firstStartsAt.getUTCDay(), dayOfWeek);

    // Each event is exactly 7 days after the previous.
    for (let i = 1; i < (events1 ?? []).length; i++) {
      const prev = new Date(events1![i-1].starts_at).getTime();
      const cur  = new Date(events1![i].starts_at).getTime();
      assertEquals(cur - prev, 7 * 24 * 3600_000, `gap between event ${i-1} and ${i}`);
    }

    // ─────────────────────────────────────────────────────────────────
    // STEP 2 — idempotent re-run.
    // ─────────────────────────────────────────────────────────────────

    const run2 = await invokeCron("auto-generate-events");
    assertEquals(run2.ok, true, `auto-generate-events run 2 failed: ${JSON.stringify(run2.body)}`);

    const { data: events2, error: e2Err } = await admin
      .from("events_view")
      .select("id")
      .eq("series_id", series.id);
    if (e2Err) throw new Error(`events select run 2: ${e2Err.message}`);

    // Idempotency contract: re-running the cron should NOT create new
    // events (the (series_id, starts_at) unique index + ON CONFLICT
    // DO NOTHING in create_event_v2 absorb duplicate attempts).
    assertEquals(events2?.length, events1?.length, "re-run must not add events");

    // ─────────────────────────────────────────────────────────────────
    // STEP 3 — generated_until cursor advanced on the series.
    // ─────────────────────────────────────────────────────────────────

    const { data: seriesAfter } = await admin
      .from("resource_series")
      .select("generated_until")
      .eq("id", series.id)
      .single();
    const lastEventStart = (events1 ?? []).at(-1)?.starts_at;
    assertEquals(
      seriesAfter?.generated_until,
      lastEventStart,
      "generated_until should point at the latest produced starts_at",
    );
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("recurrence: after_count caps the series at exactly count occurrences", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: false,
    });

    const startDate = new Date();
    startDate.setUTCDate(startDate.getUTCDate() + 1);
    const startDateStr = startDate.toISOString().slice(0, 10);
    const dayOfWeek = startDate.getUTCDay();

    const { data: series, error: insErr } = await admin
      .from("resource_series")
      .insert({
        group_id:      group.groupId,
        resource_type: "event",
        active:        true,
        pattern: {
          frequency:    "weekly",
          dayOfWeek:    dayOfWeek,
          hour:         20, minute: 0,
          startDate:    startDateStr,
          endCondition: "after_count",
          count:        3,
          timezone:     "UTC",
        },
        metadata: { title: "Cena 3 veces", duration_minutes: 180 },
      })
      .select("id")
      .single();
    if (insErr || !series) throw new Error(`series insert: ${insErr?.message}`);

    await invokeCron("auto-generate-events");

    const { data: events } = await admin
      .from("events_view")
      .select("id, starts_at")
      .eq("series_id", series.id)
      .order("starts_at", { ascending: true });
    assertEquals(events?.length, 3, "after_count=3 must produce exactly 3 events");

    // Re-run: stays at 3.
    await invokeCron("auto-generate-events");
    const { data: events2 } = await admin
      .from("events_view")
      .select("id")
      .eq("series_id", series.id);
    assertEquals(events2?.length, 3, "idempotent — re-run stays at count");
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("recurrence: until_date caps the series at the last occurrence on/before that date", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: false,
    });

    const startDate = new Date();
    startDate.setUTCDate(startDate.getUTCDate() + 1);
    const startDateStr = startDate.toISOString().slice(0, 10);
    const dayOfWeek = startDate.getUTCDay();
    // untilDate = 4 weeks after start (=> expect 5 occurrences: week 0,
    // 1, 2, 3, 4 — inclusive).
    const untilDate = new Date(startDate);
    untilDate.setUTCDate(untilDate.getUTCDate() + 28);
    const untilDateStr = untilDate.toISOString().slice(0, 10);

    const { data: series, error: insErr } = await admin
      .from("resource_series")
      .insert({
        group_id:      group.groupId,
        resource_type: "event",
        active:        true,
        pattern: {
          frequency:    "weekly",
          dayOfWeek:    dayOfWeek,
          hour:         20, minute: 0,
          startDate:    startDateStr,
          endCondition: "until_date",
          untilDate:    untilDateStr,
          timezone:     "UTC",
        },
        metadata: { title: "Cena 5 semanas", duration_minutes: 180 },
      })
      .select("id")
      .single();
    if (insErr || !series) throw new Error(`series insert: ${insErr?.message}`);

    await invokeCron("auto-generate-events");

    const { data: events } = await admin
      .from("events_view")
      .select("starts_at")
      .eq("series_id", series.id)
      .order("starts_at", { ascending: true });
    // Weeks 0,1,2,3,4 = 5 occurrences (untilDate is inclusive of the
    // last week's day).
    assertEquals(events?.length, 5);
    const lastEvent = new Date(events!.at(-1)!.starts_at);
    assertEquals(lastEvent.toISOString().slice(0, 10), untilDateStr);
  } finally {
    if (group) await cleanupGroup(group);
  }
});
