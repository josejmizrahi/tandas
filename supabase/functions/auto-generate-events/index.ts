// auto-generate-events: cron safety net for groups with auto_generate_events=true.
//
// Deploy as scheduled function ("0 */2 * * *" — every 2h). For each group
// with auto_generate_events=true, ensures at least 4 future scheduled
// events exist. Generates missing ones using the group's frequency_type +
// frequency_config + rotation_mode.
//
// V1 keeps recurrence generation client-triggered as the primary path
// (host closes event → client creates next). This cron is the safety net
// for hosts who never close events. Idempotent: only creates if count < 4.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TARGET_FUTURE_COUNT = 4;

serve(async (_req) => {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const { data: groups, error: groupsErr } = await supabase
    .from("groups")
    .select("*")
    .eq("auto_generate_events", true);

  if (groupsErr) {
    console.error("groups select failed", groupsErr);
    return new Response(JSON.stringify({ error: groupsErr.message }), { status: 500 });
  }

  let totalCreated = 0;
  for (const g of groups ?? []) {
    if (!g.frequency_type || g.frequency_type === "unscheduled") continue;

    // Find the latest scheduled future event in this group; we'll derive
    // the next dates from there (or from now() if none).
    const { data: existing } = await supabase
      .from("events")
      .select("id, starts_at, host_id")
      .eq("group_id", g.id)
      .eq("status", "scheduled")
      .gte("starts_at", new Date().toISOString())
      .order("starts_at", { ascending: false });

    const futureCount = existing?.length ?? 0;
    if (futureCount >= TARGET_FUTURE_COUNT) continue;

    const need = TARGET_FUTURE_COUNT - futureCount;
    let anchor = existing && existing.length > 0
      ? new Date(existing[0].starts_at)
      : nextDateFromNow(g.frequency_type, g.frequency_config);

    for (let i = 0; i < need; i++) {
      anchor = nextDate(anchor, g.frequency_type);
      const { error: rpcErr } = await supabase.rpc("create_event_v2", {
        p_group_id: g.id,
        p_title: `${capitalize(g.event_label || "Evento")} ${formatShort(anchor)}`,
        p_starts_at: anchor.toISOString(),
        p_duration_minutes: 180,
        p_apply_rules: true,
        p_is_recurring_generated: true,
        p_cover_image_name: g.cover_image_name,
      });
      if (rpcErr) {
        console.warn(`create_event_v2 failed for group ${g.id}`, rpcErr);
        break;
      }
      totalCreated++;
    }
  }

  return new Response(JSON.stringify({ created: totalCreated }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});

function nextDate(from: Date, type: string): Date {
  const d = new Date(from);
  switch (type) {
    case "weekly":   d.setUTCDate(d.getUTCDate() + 7); break;
    case "biweekly": d.setUTCDate(d.getUTCDate() + 14); break;
    case "monthly":  d.setUTCMonth(d.getUTCMonth() + 1); break;
    default: break;
  }
  return d;
}

function nextDateFromNow(type: string, config: Record<string, number>): Date {
  // Anchor at next occurrence based on day_of_week or day_of_month.
  const now = new Date();
  const hour = config?.hour ?? 20;
  const minute = config?.minute ?? 30;
  const candidate = new Date(now);
  candidate.setUTCHours(hour, minute, 0, 0);

  if (type === "monthly" && config?.day_of_month) {
    candidate.setUTCDate(config.day_of_month);
    if (candidate <= now) candidate.setUTCMonth(candidate.getUTCMonth() + 1);
    return candidate;
  }
  if (config?.day_of_week !== undefined) {
    const targetDow = config.day_of_week; // 0=Sun..6=Sat
    const todayDow = candidate.getUTCDay();
    let delta = (targetDow - todayDow + 7) % 7;
    if (delta === 0 && candidate <= now) delta = 7;
    candidate.setUTCDate(candidate.getUTCDate() + delta);
  }
  return candidate;
}

function capitalize(s: string): string {
  return s.length === 0 ? s : s.charAt(0).toUpperCase() + s.slice(1);
}

function formatShort(d: Date): string {
  return d.toISOString().slice(0, 10);
}
