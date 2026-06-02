// emit-event-started-atoms: cron that emits `eventStarted` system_events
// once an event's `starts_at` has elapsed.
//
// Plans/Active/EventResource.md §8 lists `eventStarted` as a canonical
// lifecycle atom; §17 says real state ("is_live") derives from atoms,
// not from `resources.status`. Until this cron lands, `event_lifecycle_view`
// (mig 00207) falls back to clock comparison for is_live — correct enough,
// but every consumer that wants to react to "this event just started" is
// stuck polling. After this, the rule engine + UI listeners get a single
// authoritative atom per (event, started) and the projection can prefer
// atom over clock.
//
// Design — event-driven scan, not rule-driven:
//   1. Find events whose `metadata.starts_at` is in the past but capped
//      to a backstop (default: now − 7 days). Older events that never
//      got the atom stay un-emitted (not worth back-emitting decades of
//      history; this is a forward-going atom).
//   2. Dedup against existing `eventStarted` rows in system_events. A
//      second cron invocation is a no-op for already-emitted events.
//   3. Skip events that have a `eventCancelled` atom — a cancelled
//      event never "started" in the lifecycle sense. (We do NOT skip
//      `eventClosed`: an event can be closed without starting in some
//      legacy paths, but most close-without-start flows are bugs.
//      Emitting both atoms in close order is acceptable evidence.)
//   4. Insert one synthetic row per event with payload `{starts_at, host_id}`
//      so the rule engine has enough context without re-querying.
//
// Suggested schedule: `*/5 * * * *`. Backstop tolerates up to 7 days of
// cron downtime without dropping an emission; tighter backstop risks
// missing emissions on extended platform outage.
//
// Idempotency:
//   - Dedup check is exact: `(resource_id, event_type='eventStarted')`.
//   - INSERTs are unconstrained at the DB level (system_events has no
//     unique index on this pair), so this in-app dedup is the only gate.
//     `cron.schedule` runs jobs sequentially per name, so the practical
//     risk of double-emission is zero unless operator triggers via curl
//     in the same window. Downstream `process-system-events` is itself
//     idempotent at rule_firings level — a dupe atom is recoverable.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { withSentry } from "../_shared/sentry.ts";
import { getNow } from "../_shared/time.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BATCH_LIMIT = parseInt(Deno.env.get("EMIT_STARTED_BATCH") ?? "200");
const BACKSTOP_DAYS = parseInt(Deno.env.get("EMIT_STARTED_BACKSTOP_DAYS") ?? "7");

interface ResourceRow {
  id: string;
  group_id: string;
  metadata: Record<string, unknown>;
}

serve(withSentry(async (req) => {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const now = getNow(req);
  const nowIso = now.toISOString();
  const backstopIso = new Date(
    now.getTime() - BACKSTOP_DAYS * 86_400_000,
  ).toISOString();
  const startedAt = new Date();

  // 1. Candidates: event resources whose starts_at has elapsed,
  // within the backstop window. Filter on metadata->>starts_at via
  // PostgREST. Skip archived rows — archive implies "out of lifecycle".
  const { data: candidates, error: candErr } = await supabase
    .from("resources")
    .select("id, group_id, metadata")
    .eq("resource_type", "event")
    .is("archived_at", null)
    .gte("metadata->>starts_at", backstopIso)
    .lte("metadata->>starts_at", nowIso)
    .limit(BATCH_LIMIT);

  if (candErr) {
    console.error("emit-event-started-atoms: candidate select failed", candErr);
    return new Response(JSON.stringify({ error: candErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  if (!candidates || candidates.length === 0) {
    return new Response(
      JSON.stringify({ emitted: 0, scanned: 0 }),
      { headers: { "Content-Type": "application/json" } },
    );
  }

  const candidateIds = (candidates as ResourceRow[]).map((c) => c.id);

  // 2. Dedup against existing eventStarted atoms.
  const { data: started, error: startedErr } = await supabase
    .from("system_events")
    .select("resource_id")
    .eq("event_type", "eventStarted")
    .in("resource_id", candidateIds);

  if (startedErr) {
    console.error(
      "emit-event-started-atoms: dedup select failed",
      startedErr,
    );
    return new Response(JSON.stringify({ error: startedErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const alreadyStarted = new Set(
    (started ?? []).map((r) => (r as { resource_id: string }).resource_id),
  );

  // 3. Exclude cancellations — never emit started for a cancelled event.
  const { data: cancellations, error: cancErr } = await supabase
    .from("system_events")
    .select("resource_id")
    .eq("event_type", "eventCancelled")
    .in("resource_id", candidateIds);

  if (cancErr) {
    console.error(
      "emit-event-started-atoms: cancellation dedup failed",
      cancErr,
    );
    return new Response(JSON.stringify({ error: cancErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const cancelled = new Set(
    (cancellations ?? []).map(
      (r) => (r as { resource_id: string }).resource_id,
    ),
  );

  const toEmit = (candidates as ResourceRow[]).filter(
    (c) => !alreadyStarted.has(c.id) && !cancelled.has(c.id),
  );

  if (toEmit.length === 0) {
    return new Response(
      JSON.stringify({
        emitted: 0,
        scanned: candidates.length,
        already_started: alreadyStarted.size,
        cancelled: cancelled.size,
      }),
      { headers: { "Content-Type": "application/json" } },
    );
  }

  const rows = toEmit.map((c) => ({
    group_id: c.group_id,
    event_type: "eventStarted",
    resource_id: c.id,
    payload: {
      starts_at: c.metadata?.starts_at ?? null,
      title: c.metadata?.title ?? null,
      host_id: c.metadata?.host_id ?? null,
    },
  }));

  // V8 fix (mig 00302): route through record_system_events_batch RPC.
  const { error: insErr } = await supabase.rpc("record_system_events_batch", { p_events: rows });
  if (insErr) {
    console.error("emit-event-started-atoms: insert failed", insErr);
    return new Response(JSON.stringify({ error: insErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const finishedAt = new Date();
  console.log(
    `emit-event-started-atoms: scanned ${candidates.length} emitted ${toEmit.length} (already=${alreadyStarted.size} cancelled=${cancelled.size}) in ${
      finishedAt.getTime() - startedAt.getTime()
    }ms`,
  );

  return new Response(
    JSON.stringify({
      scanned: candidates.length,
      emitted: toEmit.length,
      already_started: alreadyStarted.size,
      cancelled: cancelled.size,
      duration_ms: finishedAt.getTime() - startedAt.getTime(),
    }),
    { headers: { "Content-Type": "application/json" } },
  );
}, { functionName: "emit-event-started-atoms" }));
