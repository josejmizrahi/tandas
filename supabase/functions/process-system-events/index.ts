// process-system-events: cron consumer of the system_events log.
//
// Schedule: every minute. Picks the next batch of unprocessed events
// (occurred_at oldest first), loads the matching rules + context, runs the
// rule engine, and marks each event processed.
//
// Idempotency: an event is only marked processed AFTER its consequences
// commit. If the function crashes mid-batch, the next run picks it up
// again. Consequence executors are responsible for their own dedup
// (the `fines` table uses (event_id, member_id, rule_id) as a soft key).

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { runRulesForEvent, type ConsequenceSink, type RuleContext } from "../_shared/ruleEngine.ts";
import type { Rule, SystemEvent } from "../_shared/platformTypes.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BATCH_SIZE = parseInt(Deno.env.get("BATCH_SIZE") ?? "100");

serve(async (_req) => {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // 1. Pull unprocessed events
  const { data: events, error: selErr } = await supabase
    .from("system_events")
    .select("*")
    .is("processed_at", null)
    .order("occurred_at", { ascending: true })
    .limit(BATCH_SIZE);

  if (selErr) {
    console.error("[process-system-events] select failed", selErr);
    return new Response(JSON.stringify({ error: selErr.message }), { status: 500 });
  }

  if (!events || events.length === 0) {
    return new Response(JSON.stringify({ processed: 0 }), { status: 200 });
  }

  let totalResults = 0;
  let totalErrors = 0;

  for (const event of events as SystemEvent[]) {
    try {
      // 2. Load rules for this event's group + matching the event type
      const { data: rules } = await supabase
        .from("rules")
        .select("*")
        .eq("group_id", event.group_id)
        .eq("is_active", true);

      const matchingRules = (rules ?? []).filter((r: Rule) =>
        r.trigger?.eventType === event.event_type
      );

      if (matchingRules.length === 0) {
        // No rules to run — still mark processed so we don't retry
        await markProcessed(supabase, event.id);
        continue;
      }

      // 3. Build context
      const context = await buildContext(supabase, event);

      // 4. Run engine
      const results = await runRulesForEvent(event, matchingRules as Rule[], context);
      totalResults += results.length;
      totalErrors += results.filter((r) => !r.success).length;

      // 5. Mark processed
      await markProcessed(supabase, event.id, results);
    } catch (e) {
      console.error("[process-system-events] event failed", event.id, e);
      totalErrors += 1;
      // Do NOT mark processed — let the next run retry
    }
  }

  return new Response(
    JSON.stringify({
      processed: events.length,
      consequences: totalResults,
      errors: totalErrors,
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});

async function markProcessed(
  supabase: ReturnType<typeof createClient>,
  eventId: string,
  results?: unknown[],
) {
  const update: Record<string, unknown> = { processed_at: new Date().toISOString() };
  if (results) {
    update.payload = { results };
  }
  await supabase.from("system_events").update(update).eq("id", eventId);
}

async function buildContext(
  supabase: ReturnType<typeof createClient>,
  event: SystemEvent,
): Promise<RuleContext> {
  // Members of the group
  const { data: members } = await supabase
    .from("group_members")
    .select("id, user_id, active")
    .eq("group_id", event.group_id);

  // Resource (event-shaped via legacy events table for V1; future:
  // events_view / resources)
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

      // RSVPs from event_attendance
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

  // Anti-tirania monthly fine cap context
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
