// auto-close-events: cron job that closes events 24h after starts_at.
//
// Deploy as a scheduled function (cron expression "0 * * * *" — every hour).
// Uses service_role to bypass RLS. Marks events as 'completed' + sets
// closed_at, AND emits one `eventClosed` system_event per closed event so
// process-system-events runs the rule engine just like a manual close
// via the close_event RPC would. Without this emission, no-show / late-
// cancel rules silently never fired for hosts who forgot to close.
//
// Idempotent: skips events already in 'completed' or 'cancelled' state.
// The system_event emit is per-batch so a cron retry won't re-emit (the
// status filter prevents it from picking up the same events twice).

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { getNow } from "../_shared/time.ts";
import { withSentry } from "../_shared/sentry.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CLOSE_AFTER_HOURS = parseInt(Deno.env.get("AUTO_CLOSE_AFTER_HOURS") ?? "24");

serve(withSentry(async (req) => {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const now = getNow(req);
  const cutoff = new Date(now.getTime() - CLOSE_AFTER_HOURS * 60 * 60 * 1000);

  // §14 step 5c-iii.A: read from events_view (resources projection); writes
  // below still target the events table until 5c-iii.C refactors them.
  const { data: stale, error: selErr } = await supabase
    .from("events_view")
    .select("id, group_id, host_id, starts_at, status")
    .in("status", ["scheduled", "in_progress"])
    .lt("starts_at", cutoff.toISOString())
    .limit(100);

  if (selErr) {
    console.error("select stale events failed", selErr);
    return new Response(JSON.stringify({ error: selErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  if (!stale || stale.length === 0) {
    return new Response(JSON.stringify({ closed: 0, emitted: 0 }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  // §14 step 5c-iv: events table dropped. Close-by-batch via the new
  // bulk_close_stale_events RPC which does per-row jsonb_set on
  // resources.metadata.closed_at without trampling other metadata keys.
  const ids = stale.map((e) => e.id);
  const { error: updErr } = await supabase
    .rpc("bulk_close_stale_events", { p_ids: ids });

  if (updErr) {
    console.error("auto-close update failed", updErr);
    return new Response(JSON.stringify({ error: updErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Emit eventClosed per event so process-system-events runs the rule
  // engine on each one (mirrors close_event RPC behavior). V8 fix
  // (mig 00302): routed through record_system_events_batch RPC — one
  // round-trip, same transactional semantics as the previous direct
  // batch INSERT, but every atom is now validated via record_system_event
  // (payload schemas, known event types, etc.).
  const systemEventRows = stale.map((e) => ({
    group_id:    e.group_id,
    event_type:  "eventClosed" as const,
    resource_id: e.id,
    // We intentionally leave member_id null here because auto-close has
    // no human actor — the close was driven by a deadline, not a host
    // tap. The rule engine's eventClosed trigger doesn't read
    // event.member_id (it iterates context.members), so null is correct.
    member_id:   null,
    payload:     {
      host_id:     e.host_id ?? null,
      starts_at:   e.starts_at,
      auto_closed: true,
    },
  }));

  const { error: emitErr } = await supabase
    .rpc("record_system_events_batch", { p_events: systemEventRows });

  if (emitErr) {
    // Don't fail the whole job — the close itself succeeded. Log so the
    // operator can re-emit (running a `record_system_event` SQL block)
    // for the affected event ids if rule consequences depend on them.
    console.error("eventClosed emit failed (close succeeded, rules will not fire automatically)", {
      error:    emitErr.message,
      event_ids: ids,
    });
  }

  console.log(`auto-closed ${ids.length} events (${emitErr ? "0" : ids.length} eventClosed emitted)`);
  return new Response(JSON.stringify({
    closed:  ids.length,
    emitted: emitErr ? 0 : ids.length,
    ids,
    emit_error: emitErr?.message ?? null,
  }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}, { functionName: "auto-close-events" }));
