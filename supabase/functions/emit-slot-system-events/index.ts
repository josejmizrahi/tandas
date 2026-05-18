// emit-slot-system-events: cron that emits `slotExpired` system events
// for slot resources whose `ends_at` has passed without a booking attached.
// Drives the rule engine to evaluate `shared_no_show` (fine the assigned
// holder when the cupo went unused).
//
// Suggested schedule: "*/5 * * * *" (every 5 minutes). Matches the cadence
// of emit-deadline-events; slots are not high-frequency.
//
// Flow:
//   1. SELECT slot resources where status NOT IN (expired, cancelled) AND
//      metadata->>ends_at < now() AND metadata->>booking_id IS NULL.
//   2. Dedup against existing slotExpired system_events for the same
//      resource_id (so re-runs don't double-emit).
//   3. INSERT one system_events row per slot + UPDATE the slot's status
//      to 'expired' so the next run skips it cheaply.
//
// Idempotency: the dedup check + status flip together ensure exactly-once
// emission per slot. If the function crashes between INSERT and UPDATE,
// the next run sees the existing system_event and skips.
//
// Trigger evaluator for slotExpired lives in _shared/ruleEngine.ts and
// derives the assigned_member_id as the fine target.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { withSentry } from "../_shared/sentry.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BATCH_LIMIT = parseInt(Deno.env.get("EMIT_SLOTS_BATCH") ?? "100");

serve(withSentry(async (_req) => {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const startedAt = new Date();
  const nowIso = startedAt.toISOString();

  // Candidate slots: slot resources past ends_at, still open, no booking.
  // `metadata->>booking_id` (text) is NULL when the key is missing OR when
  // the JSON value is null — covers both "never booked" shapes.
  const { data: candidates, error: selErr } = await supabase
    .from("resources")
    .select("id, group_id, status, metadata")
    .eq("resource_type", "slot")
    .not("status", "in", "(expired,cancelled)")
    .filter("metadata->>ends_at", "lt", nowIso)
    .filter("metadata->>booking_id", "is", null)
    .limit(BATCH_LIMIT);

  if (selErr) {
    console.error("emit-slot-system-events select failed", selErr);
    return new Response(JSON.stringify({ error: selErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  if (!candidates || candidates.length === 0) {
    return new Response(JSON.stringify({ emitted: 0 }), {
      headers: { "Content-Type": "application/json" },
    });
  }

  // Dedup: skip slots that already have a slotExpired system_event.
  const slotIds = candidates.map((s) => s.id);
  const { data: alreadyEmitted, error: existsErr } = await supabase
    .from("system_events")
    .select("resource_id")
    .eq("event_type", "slotExpired")
    .in("resource_id", slotIds);

  if (existsErr) {
    console.error("emit-slot-system-events dedup select failed", existsErr);
    return new Response(JSON.stringify({ error: existsErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const alreadyEmittedSet = new Set((alreadyEmitted ?? []).map((r) => r.resource_id));
  const toEmit = candidates.filter((s) => !alreadyEmittedSet.has(s.id));

  if (toEmit.length === 0) {
    return new Response(
      JSON.stringify({ emitted: 0, scanned: candidates.length }),
      { headers: { "Content-Type": "application/json" } },
    );
  }

  // Project metadata fields the trigger evaluator needs onto payload, so
  // it doesn't have to re-read the resource. The slotIsUnassigned condition
  // (Slice 2.1) prefers target.context.booking_id over resource.metadata.
  const rows = toEmit.map((s) => ({
    group_id: s.group_id,
    event_type: "slotExpired",
    resource_id: s.id,
    payload: {
      assigned_member_id: s.metadata?.assigned_member_id ?? null,
      booking_id: s.metadata?.booking_id ?? null,
      ends_at: s.metadata?.ends_at ?? null,
      asset_id: s.metadata?.asset_id ?? null,
    },
  }));

  // V8 fix (mig 00302): route through record_system_events_batch RPC.
  const { error: insErr } = await supabase.rpc("record_system_events_batch", { p_events: rows });
  if (insErr) {
    console.error("emit-slot-system-events insert failed", insErr);
    return new Response(JSON.stringify({ error: insErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Flip slot status to 'expired' so the next run filters them out cheaply.
  // Idempotent: we filter by id IN (...) regardless of current status. If
  // a parallel writer beat us to a swap_request the status may already have
  // changed; this UPDATE is conservative and only writes the new status.
  const emittedIds = toEmit.map((s) => s.id);
  const { error: updErr } = await supabase
    .from("resources")
    .update({ status: "expired" })
    .in("id", emittedIds);

  if (updErr) {
    console.error("emit-slot-system-events status flip failed", updErr);
    // Non-fatal: system_event already inserted, the dedup check protects
    // us from re-emitting. Surface the error for observability but return
    // success so the cron doesn't retry the whole batch.
  }

  const finishedAt = new Date();
  console.log(
    `emit-slot-system-events: scanned ${candidates.length}, emitted ${toEmit.length} in ${finishedAt.getTime() - startedAt.getTime()}ms`,
  );

  return new Response(
    JSON.stringify({
      scanned: candidates.length,
      emitted: toEmit.length,
      duration_ms: finishedAt.getTime() - startedAt.getTime(),
    }),
    { headers: { "Content-Type": "application/json" } },
  );
}, { functionName: "emit-slot-system-events" }));
