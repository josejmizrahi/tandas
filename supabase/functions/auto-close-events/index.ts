// auto-close-events: cron job that closes events 24h after starts_at.
//
// Deploy as a scheduled function (cron expression "0 * * * *" — every hour).
// Uses service_role to bypass RLS. Marks events as 'completed' + sets
// closed_at. Does NOT invoke evaluate_event_rules — phase 4 will add a
// separate cron that runs the rule engine for events that need it.
//
// Idempotent: skips events already in 'completed' or 'cancelled' state.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CLOSE_AFTER_HOURS = parseInt(Deno.env.get("AUTO_CLOSE_AFTER_HOURS") ?? "24");

serve(async (_req) => {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const cutoff = new Date(Date.now() - CLOSE_AFTER_HOURS * 60 * 60 * 1000);

  const { data: stale, error: selErr } = await supabase
    .from("events")
    .select("id, group_id, starts_at, status")
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
    return new Response(JSON.stringify({ closed: 0 }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const ids = stale.map((e) => e.id);
  const { error: updErr } = await supabase
    .from("events")
    .update({ status: "completed", closed_at: new Date().toISOString() })
    .in("id", ids);

  if (updErr) {
    console.error("auto-close update failed", updErr);
    return new Response(JSON.stringify({ error: updErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  console.log(`auto-closed ${ids.length} events`);
  return new Response(JSON.stringify({ closed: ids.length, ids }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
