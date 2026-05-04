// evaluate-event-rules: immediate rule eval for an event id.
//
// Called by the iOS client (or by close_event RPC's trigger) when a host
// closes an event so the proposed fines appear without cron lag. Body:
//
//   { "event_id": "uuid" }
//
// Internally:
//   1. Inserts a `system_events` row of type `eventClosed` (idempotent — if
//      one already exists for this event_id+eventClosed within 5 min,
//      reuses it).
//   2. Calls the same engine path as `process-system-events` for that one
//      event so the fines materialize before the response returns.
//   3. Returns the run summary { rules_matched, fines_proposed, errors }.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { runRulesForEvent, type ConsequenceSink, type RuleContext } from "../_shared/ruleEngine.ts";
import { corsHeaders } from "../_shared/cors.ts";
import type { Rule, SystemEvent } from "../_shared/platformTypes.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  let body: { event_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }

  if (!body.event_id) {
    return json({ error: "event_id required" }, 400);
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // Resolve group_id from the event
  const { data: ev, error: evErr } = await supabase
    .from("events")
    .select("id, group_id")
    .eq("id", body.event_id)
    .maybeSingle();

  if (evErr || !ev) {
    return json({ error: `event not found: ${body.event_id}` }, 404);
  }

  // Insert / reuse the eventClosed system_event
  const fiveMinAgo = new Date(Date.now() - 5 * 60 * 1000).toISOString();
  const { data: existing } = await supabase
    .from("system_events")
    .select("*")
    .eq("event_type", "eventClosed")
    .eq("resource_id", body.event_id)
    .gte("occurred_at", fiveMinAgo)
    .maybeSingle();

  let systemEvent: SystemEvent;
  if (existing) {
    systemEvent = existing as SystemEvent;
  } else {
    const { data: inserted, error: insErr } = await supabase
      .from("system_events")
      .insert({
        group_id: ev.group_id,
        event_type: "eventClosed",
        resource_id: body.event_id,
        member_id: null,
        payload: {},
      })
      .select("*")
      .single();
    if (insErr || !inserted) {
      return json({ error: `system_event insert failed: ${insErr?.message}` }, 500);
    }
    systemEvent = inserted as SystemEvent;
  }

  // Skip if already processed
  if (systemEvent.processed_at) {
    return json({
      already_processed: true,
      event_id: body.event_id,
      processed_at: systemEvent.processed_at,
    });
  }

  // Load matching rules
  const { data: rules } = await supabase
    .from("rules")
    .select("*")
    .eq("group_id", ev.group_id)
    .eq("is_active", true);

  const matching = (rules ?? []).filter(
    (r: Rule) => r.trigger?.eventType === "eventClosed",
  ) as Rule[];

  if (matching.length === 0) {
    await supabase
      .from("system_events")
      .update({ processed_at: new Date().toISOString() })
      .eq("id", systemEvent.id);
    return json({ rules_matched: 0, fines_proposed: 0, errors: 0 });
  }

  // Build context (same shape as cron)
  const context = await buildContext(supabase, systemEvent);
  const results = await runRulesForEvent(systemEvent, matching, context);

  await supabase
    .from("system_events")
    .update({
      processed_at: new Date().toISOString(),
      payload: { results },
    })
    .eq("id", systemEvent.id);

  return json({
    rules_matched: matching.length,
    fines_proposed: results.flatMap((r) => r.created_resource_ids).length,
    errors: results.filter((r) => !r.success).length,
  });
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function buildContext(
  supabase: ReturnType<typeof createClient>,
  event: SystemEvent,
): Promise<RuleContext> {
  // Identical to process-system-events buildContext. Inlined to keep each
  // function self-contained (Supabase deploys per-function).
  const { data: members } = await supabase
    .from("group_members")
    .select("id, user_id, active")
    .eq("group_id", event.group_id);

  let resource: RuleContext["resource"] = null;
  let rsvps: RuleContext["rsvps"] = [];
  let checkIns: RuleContext["checkIns"] = [];

  if (event.resource_id) {
    const { data: ev } = await supabase
      .from("events_view")
      .select("*")
      .eq("resource_id", event.resource_id)
      .maybeSingle();

    if (ev) {
      resource = {
        id: ev.resource_id,
        group_id: ev.group_id,
        resource_type: ev.resource_type,
        status: ev.status,
        metadata: ev.metadata,
      };

      const { data: attendance } = await supabase
        .from("event_attendance")
        .select("user_id, rsvp_status, rsvp_at, cancelled_same_day, arrived_at")
        .eq("event_id", event.resource_id);

      const startsAt = (resource.metadata.starts_at as string | undefined) ?? null;
      const startsAtMs = startsAt ? new Date(startsAt).getTime() : null;

      rsvps = (attendance ?? []).map((a) => ({
        member_user_id: a.user_id,
        status: a.rsvp_status,
        rsvp_at: a.rsvp_at,
        cancelled_same_day: a.cancelled_same_day ?? false,
      }));

      checkIns = (attendance ?? [])
        .filter((a) => a.arrived_at != null)
        .map((a) => ({
          member_user_id: a.user_id,
          arrived_at: a.arrived_at,
          minutes_late:
            startsAtMs != null
              ? Math.round((new Date(a.arrived_at).getTime() - startsAtMs) / 60_000)
              : 0,
        }));
    }
  }

  const monthStart = new Date();
  monthStart.setDate(1);
  monthStart.setHours(0, 0, 0, 0);

  const { data: monthFines } = await supabase
    .from("fines")
    .select("member_id")
    .eq("group_id", event.group_id)
    .gte("created_at", monthStart.toISOString());

  const finesThisMonthByMember = new Map<string, number>();
  for (const f of monthFines ?? []) {
    finesThisMonthByMember.set(f.member_id, (finesThisMonthByMember.get(f.member_id) ?? 0) + 1);
  }

  const sink: ConsequenceSink = {
    proposeFine: async (args) => {
      const { data, error } = await supabase
        .from("fines")
        .insert({
          event_id: args.event_id,
          group_id: args.group_id,
          member_id: args.member_id,
          rule_id: args.rule_id,
          amount: args.amount,
          reason: args.reason,
          evidence: args.evidence,
          status: "proposed",
        })
        .select("id")
        .single();
      if (error) throw new Error(`proposeFine insert failed: ${error.message}`);
      return data.id as string;
    },
  };

  return {
    now: new Date(),
    members: (members ?? []).map((m) => ({ id: m.id, user_id: m.user_id, active: m.active })),
    resource,
    rsvps,
    checkIns,
    finesThisMonthByMember,
    sink,
  };
}
