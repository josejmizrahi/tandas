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

  // Mig 00329 fix: atom emit + status flip happen in ONE transaction via
  // mark_slots_expired_batch. Previously this was two separate writes —
  // (1) record_system_events_batch RPC, (2) resources UPDATE — which could
  // diverge if the second one failed mid-batch. The new RPC loops the
  // slot_ids server-side and pairs each atom with its status transition;
  // the trigger evaluator's payload (assigned_member_id, booking_id,
  // ends_at, asset_id) is reconstructed from resources.metadata inside the
  // RPC so this edge fn no longer ships it. Per CleanupAudit_2026-05-18
  // §06.4.1.
  const emittedIds = toEmit.map((s) => s.id);
  const { data: transitionedCount, error: rpcErr } = await supabase
    .rpc("mark_slots_expired_batch", { p_slot_ids: emittedIds });

  if (rpcErr) {
    console.error("emit-slot-system-events mark_slots_expired_batch failed", rpcErr);
    return new Response(JSON.stringify({ error: rpcErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const finishedAt = new Date();
  console.log(
    `emit-slot-system-events: scanned ${candidates.length}, attempted ${toEmit.length}, transitioned ${transitionedCount ?? 0} in ${finishedAt.getTime() - startedAt.getTime()}ms`,
  );

  return new Response(
    JSON.stringify({
      scanned: candidates.length,
      emitted: transitionedCount ?? 0,
      attempted: toEmit.length,
      duration_ms: finishedAt.getTime() - startedAt.getTime(),
    }),
    { headers: { "Content-Type": "application/json" } },
  );
}, { functionName: "emit-slot-system-events" }));
