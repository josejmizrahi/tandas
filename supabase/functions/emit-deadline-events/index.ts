// emit-deadline-events: cron that emits `rsvpDeadlinePassed` system events
// when an event's RSVP deadline expires. Drives the rule engine to evaluate
// rules like "no confirmó a tiempo".
//
// Suggested schedule: "*/5 * * * *" (every 5 minutes).
// Uses service_role to bypass RLS.
//
// Flow: select events whose rsvp_deadline has passed, status is still
// 'scheduled' (or 'in_progress'), AND no rsvpDeadlinePassed system_event
// has been emitted for that event yet. For each: insert one row.
//
// Idempotent: the dedup check on existing system_events skips already-
// processed events. The cron `process-system-events` then picks up the
// new row and runs matching rules.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BATCH_LIMIT = parseInt(Deno.env.get("EMIT_DEADLINES_BATCH") ?? "100");

serve(async (_req) => {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const startedAt = new Date();

  // Candidate events: active, deadline already passed.
  const { data: candidates, error: selErr } = await supabase
    .from("events")
    .select("id, group_id, rsvp_deadline, starts_at, status")
    .in("status", ["scheduled", "in_progress"])
    .not("rsvp_deadline", "is", null)
    .lt("rsvp_deadline", startedAt.toISOString())
    .limit(BATCH_LIMIT);

  if (selErr) {
    console.error("select candidate events failed", selErr);
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

  // Find which already have a rsvpDeadlinePassed event (so we don't
  // duplicate). One round-trip with `in()`.
  const eventIds = candidates.map(e => e.id);
  const { data: alreadyEmitted, error: existsErr } = await supabase
    .from("system_events")
    .select("resource_id")
    .eq("event_type", "rsvpDeadlinePassed")
    .in("resource_id", eventIds);

  if (existsErr) {
    console.error("select existing system_events failed", existsErr);
    return new Response(JSON.stringify({ error: existsErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const alreadyEmittedSet = new Set((alreadyEmitted ?? []).map(r => r.resource_id));
  const toEmit = candidates.filter(e => !alreadyEmittedSet.has(e.id));

  if (toEmit.length === 0) {
    return new Response(JSON.stringify({ emitted: 0, scanned: candidates.length }), {
      headers: { "Content-Type": "application/json" },
    });
  }

  const rows = toEmit.map(e => ({
    group_id:    e.group_id,
    event_type:  "rsvpDeadlinePassed",
    resource_id: e.id,
    payload:     {
      rsvp_deadline: e.rsvp_deadline,
      starts_at:     e.starts_at,
    },
  }));

  const { error: insErr } = await supabase.from("system_events").insert(rows);
  if (insErr) {
    console.error("insert system_events failed", insErr);
    return new Response(JSON.stringify({ error: insErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const finishedAt = new Date();
  console.log(`emit-deadline-events: scanned ${candidates.length}, emitted ${toEmit.length} in ${finishedAt.getTime() - startedAt.getTime()}ms`);

  return new Response(JSON.stringify({
    scanned: candidates.length,
    emitted: toEmit.length,
    duration_ms: finishedAt.getTime() - startedAt.getTime(),
  }), { headers: { "Content-Type": "application/json" } });
});
