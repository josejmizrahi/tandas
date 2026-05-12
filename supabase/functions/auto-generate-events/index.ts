// auto-generate-events: cron that produces upcoming occurrences for
// every active `resource_series`.
//
// Suggested schedule: "0 */2 * * *" (every 2h).
//
// Post-Tier-1 (2026-05-12):
//   - Reads `resource_series` (NOT the dropped `groups.frequency_type`
//     legacy columns the pre-BigBang code consulted, which silently
//     made this cron a no-op since 00078).
//   - Uses the shared `recurrence.ts` pure pattern→timestamps function.
//     Same code path can be unit-tested without DB.
//   - Idempotent via the `uniq_events_series_starts_at` partial unique
//     index (mig 00126). `create_event_v2` honors ON CONFLICT (series_id,
//     starts_at) DO NOTHING, so re-running the cron is safe.
//   - Polymorphic-ready: today only `resource_type='event'` has a
//     create RPC (`create_event_v2`). Other types log "not supported"
//     and skip. Adding slot/fund support is one branch in the
//     dispatcher below.
//
// Per-run contract
//   - Look at every active series where `generated_until` is null or
//     older than (now + GENERATION_HORIZON_DAYS).
//   - For each, ask the pattern function for the next batch
//     (bounded by horizon + end-condition + MAX_PER_SERIES).
//   - Create each occurrence via the resource_type-specific RPC.
//   - Update `generated_until` to the latest timestamp produced.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { withSentry } from "../_shared/sentry.ts";
import { getNow } from "../_shared/time.ts";
import {
  computeNextOccurrences,
  validatePattern,
  type RecurrencePattern,
} from "../_shared/recurrence.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const GENERATION_HORIZON_DAYS = parseInt(Deno.env.get("GENERATION_HORIZON_DAYS") ?? "60");
const MAX_PER_SERIES         = parseInt(Deno.env.get("MAX_PER_SERIES_PER_RUN") ?? "20");

interface SeriesRow {
  id: string;
  group_id: string;
  resource_type: string;
  pattern: Record<string, unknown>;
  metadata: Record<string, unknown>;
  active: boolean;
  generated_until: string | null;
}

interface RunResult {
  scanned: number;
  generated: number;
  skipped_unsupported: number;
  skipped_invalid_pattern: number;
  errors: Array<{ series_id: string; error: string }>;
}

serve(withSentry(async (req) => {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const now = getNow(req);
  const result: RunResult = {
    scanned: 0, generated: 0,
    skipped_unsupported: 0, skipped_invalid_pattern: 0,
    errors: [],
  };

  const { data: series, error: selErr } = await supabase
    .from("resource_series")
    .select("id, group_id, resource_type, pattern, metadata, active, generated_until")
    .eq("active", true);

  if (selErr) {
    console.error("resource_series select failed", selErr);
    return new Response(JSON.stringify({ error: selErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  for (const s of (series ?? []) as SeriesRow[]) {
    result.scanned++;

    const pattern = s.pattern as Partial<RecurrencePattern>;
    const patternErrs = validatePattern(pattern);
    if (patternErrs.length > 0) {
      result.skipped_invalid_pattern++;
      console.warn(`series ${s.id}: invalid pattern`, patternErrs);
      continue;
    }

    // Generator state: count existing occurrences (for after_count) +
    // latest generated timestamp (for the resume cursor).
    const stateResult = await loadSeriesState(supabase, s);
    if (stateResult.error) {
      result.errors.push({ series_id: s.id, error: `state: ${stateResult.error}` });
      continue;
    }
    const { alreadyGenerated, after } = stateResult;

    const next = computeNextOccurrences({
      pattern: pattern as RecurrencePattern,
      after,
      alreadyGenerated,
      now,
      horizonMs: GENERATION_HORIZON_DAYS * 24 * 3600_000,
      maxPerRun: MAX_PER_SERIES,
    });

    if (next.length === 0) continue;

    let producedFor = 0;
    let latest: Date | null = null;
    for (const ts of next) {
      const created = await createOccurrence(supabase, s, ts);
      if (created.error) {
        result.errors.push({ series_id: s.id, error: created.error });
        // Don't abort the whole series — try the next timestamp; the
        // unique constraint protects us from duplicates.
        continue;
      }
      if (created.skipped) {
        result.skipped_unsupported++;
        break; // unsupported resource_type — no point retrying same series
      }
      producedFor++;
      latest = ts;
    }

    result.generated += producedFor;

    // Update generated_until = latest successful timestamp so the next
    // run resumes from here. Only update on actual produce; null
    // results don't move the cursor.
    if (latest && producedFor > 0) {
      const { error: updErr } = await supabase
        .from("resource_series")
        .update({ generated_until: latest.toISOString() })
        .eq("id", s.id);
      if (updErr) {
        result.errors.push({ series_id: s.id, error: `update_generated_until: ${updErr.message}` });
      }
    }
  }

  console.log(
    `auto-generate-events: scanned=${result.scanned} generated=${result.generated} ` +
    `skipped_unsupported=${result.skipped_unsupported} ` +
    `skipped_invalid=${result.skipped_invalid_pattern} errors=${result.errors.length}`
  );

  return new Response(JSON.stringify(result), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}, { functionName: "auto-generate-events" }));

/**
 * For a series, returns the existing occurrence count + the latest
 * timestamp so the generator knows where to resume.
 *
 * - alreadyGenerated counts ALL persisted occurrences (for after_count
 *   end condition).
 * - after is the latest occurrence's starts_at, or null if no
 *   occurrences yet. Pattern function walks forward from this point.
 *
 * V1 supports `event` resource_type only — counts from `events`. Other
 * resource types: count from `resources` directly (each occurrence is
 * a row in resources with series_id set per mig 00078).
 */
async function loadSeriesState(
  supabase: SupabaseClient,
  s: SeriesRow,
): Promise<
  | { error: null; alreadyGenerated: number; after: Date | null }
  | { error: string; alreadyGenerated: 0; after: null }
> {
  if (s.resource_type === "event") {
    const { count: countErr, error: countQueryErr } = await supabase
      .from("events")
      .select("id", { count: "exact", head: true })
      .eq("series_id", s.id);
    if (countQueryErr) return { error: countQueryErr.message, alreadyGenerated: 0, after: null };
    const alreadyGenerated = countErr ?? 0;

    const { data: latest, error: latestErr } = await supabase
      .from("events")
      .select("starts_at")
      .eq("series_id", s.id)
      .order("starts_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (latestErr) return { error: latestErr.message, alreadyGenerated: 0, after: null };
    const after = latest?.starts_at ? new Date(latest.starts_at) : null;

    return { error: null, alreadyGenerated, after };
  }
  // Polymorphic fallback: count from resources (Phase 2+).
  const { count, error: cErr } = await supabase
    .from("resources")
    .select("id", { count: "exact", head: true })
    .eq("series_id", s.id);
  if (cErr) return { error: cErr.message, alreadyGenerated: 0, after: null };
  // Without per-resource_type scheduled_at column, we can't pick a
  // canonical "after". Treat as no resume — pattern function will
  // re-derive from startDate.
  return { error: null, alreadyGenerated: count ?? 0, after: null };
}

/**
 * Dispatches creation of one occurrence to the right RPC by
 * resource_type. Returns `skipped: true` when the type has no create
 * helper yet (Phase 2 stubs).
 *
 * For `event`: calls create_event_v2(p_series_id=...). The mig 00126
 * RPC honors ON CONFLICT (series_id, starts_at) DO NOTHING, so a
 * concurrent or repeated run is idempotent.
 */
async function createOccurrence(
  supabase: SupabaseClient,
  s: SeriesRow,
  ts: Date,
): Promise<{ error: string | null; skipped: boolean }> {
  switch (s.resource_type) {
    case "event": {
      const title = (s.metadata?.["title"] as string | undefined)
        ?? `${formatShort(ts)}`;
      const durationMinutes = (s.metadata?.["duration_minutes"] as number | undefined) ?? 180;
      const description = s.metadata?.["description"] as string | undefined;
      const coverImageName = s.metadata?.["cover_image_name"] as string | undefined;

      const { error } = await supabase.rpc("create_event_v2", {
        p_group_id:              s.group_id,
        p_title:                 title,
        p_starts_at:             ts.toISOString(),
        p_duration_minutes:      durationMinutes,
        p_description:           description ?? null,
        p_cover_image_name:      coverImageName ?? null,
        p_apply_rules:           true,
        p_is_recurring_generated: true,
        p_series_id:             s.id,
      });
      // Idempotency: the RPC's ON CONFLICT clause makes a repeat a
      // no-op, returning the existing row. PostgREST surfaces this as
      // success — no error to handle here.
      if (error) return { error: error.message, skipped: false };
      return { error: null, skipped: false };
    }
    default: {
      console.warn(
        `auto-generate-events: resource_type "${s.resource_type}" has no create helper yet; ` +
        `series ${s.id} skipped. Add a branch here when shipping a new resource type's RPC.`,
      );
      return { error: null, skipped: true };
    }
  }
}

function formatShort(d: Date): string {
  return d.toISOString().slice(0, 10);
}
