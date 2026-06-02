// emit-event-reminder-events: cron that emits synthetic
// `hoursBeforeEvent` system_events so rules with that trigger
// (e.g. "host con menú faltante 24h antes") actually fire.
//
// Pre-Tier-4, no upstream emitter existed for this SystemEventType
// even though it was declared, validated, decoded, evaluated, and
// templated by several rules (`dinner_host_no_menu` seeded in 00015 /
// 00018 / 00035 / 00038 / 00058 / 00059). The rule engine's
// `hoursBeforeEvent` evaluator (ruleEngine.ts:271) targets the host,
// projecting `scheduled_hours` from payload — but nothing wrote that
// system_event row, so the rule never executed. This emitter closes
// that loop.
//
// Design — rule-driven, not event-driven:
//   1. Collect distinct active `hoursBeforeEvent.config.hours` values
//      from `rules`. Most groups will use 24h; some may add 6h or 48h.
//   2. For each distinct N, find scheduled/in-progress events whose
//      `starts_at` lands in the current cron window
//      (now + N - 1h, now + N], so a 5-min cron with a 1h window
//      guarantees coverage without double-emission.
//   3. Dedup against existing rows in `system_events` keyed on
//      (resource_id, event_type='hoursBeforeEvent', payload->>'hours').
//      A second cron invocation in the same window is a no-op.
//   4. Insert one synthetic row per (event, N) with payload `{hours: N}`
//      so the rule engine's evaluator + condition can read it without
//      re-querying the rule.
//
// Suggested schedule: `*/5 * * * *`. Window of 1h tolerates up to a
// 55-min cron miss without dropping a marker; tighter windows risk
// missing emissions on cron lag (e.g. Supabase platform redeploy).
//
// Idempotency:
//   - the dedup query checks the exact (resource_id, hours) key.
//   - inserts are unconstrained at the DB level (system_events has no
//     unique index on payload), so this in-app dedup is the only gate.
//     If two cron instances run concurrently, both could see the same
//     "missing" set and double-insert. pg_cron schedules a job
//     sequentially per name, so the practical risk is zero unless an
//     operator triggers via curl + the scheduled run lands within ms.
//     Process-system-events is itself idempotent at the rule-firing
//     layer (rule_firings unique on (rule_id, system_event_id)) so a
//     dupe here is recoverable downstream.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { withSentry } from "../_shared/sentry.ts";
import { getNow } from "../_shared/time.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BATCH_LIMIT = parseInt(Deno.env.get("EMIT_REMINDERS_BATCH") ?? "200");

interface RuleRow {
  trigger: { eventType?: string; config?: { hours?: unknown } };
  is_active: boolean;
}

interface EventRow {
  id: string;
  group_id: string;
  starts_at: string;
}

function distinctHoursFromRules(rules: RuleRow[]): number[] {
  const hours = new Set<number>();
  for (const r of rules) {
    if (!r.is_active) continue;
    if (r.trigger?.eventType !== "hoursBeforeEvent") continue;
    const raw = r.trigger?.config?.hours;
    const n = typeof raw === "number" ? raw : Number(raw);
    // Reject non-finite, non-positive, or absurd values. Cap at 30d
    // (720h) — beyond that the scheduling math is meaningless and
    // probably indicates a misconfigured rule.
    if (!Number.isFinite(n) || n <= 0 || n > 720) continue;
    hours.add(Math.floor(n));
  }
  return [...hours].sort((a, b) => a - b);
}

serve(withSentry(async (req) => {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const now = getNow(req);
  const startedAt = new Date();

  // 1. Collect distinct hours offsets from active rules. A single scan
  // is cheaper than per-group queries; the rules table is small even at
  // scale (few hundred active rules per 1000 groups).
  const { data: rules, error: rulesErr } = await supabase
    .from("rules")
    .select("trigger, is_active")
    .eq("is_active", true)
    .filter("trigger->>eventType", "eq", "hoursBeforeEvent");

  if (rulesErr) {
    console.error("emit-event-reminder-events: rules select failed", rulesErr);
    return new Response(JSON.stringify({ error: rulesErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const hoursList = distinctHoursFromRules((rules ?? []) as RuleRow[]);
  if (hoursList.length === 0) {
    return new Response(
      JSON.stringify({ emitted: 0, scanned_rules: rules?.length ?? 0 }),
      { headers: { "Content-Type": "application/json" } },
    );
  }

  // 2. For each N, find events whose starts_at lands inside the
  // window (now + (N-1)h, now + Nh]. The 1h width balances:
  //   - smaller than N to avoid back-emitting "23h reminder" for an
  //     event already 5h away
  //   - large enough to absorb cron lag (default 5-min schedule means
  //     ≤5 min skew under normal operation; 1h leaves headroom for
  //     platform redeploy gaps).
  let totalEmitted = 0;
  let totalScanned = 0;

  for (const N of hoursList) {
    const upperBoundMs = now.getTime() + N * 3_600_000;
    const lowerBoundMs = upperBoundMs - 3_600_000;
    const upperBoundIso = new Date(upperBoundMs).toISOString();
    const lowerBoundIso = new Date(lowerBoundMs).toISOString();

    // §14 step 5c-iii.A: reads from events_view (resources projection).
    const { data: candidates, error: candErr } = await supabase
      .from("events_view")
      .select("id, group_id, starts_at")
      .in("status", ["scheduled", "in_progress"])
      .gt("starts_at", lowerBoundIso)
      .lte("starts_at", upperBoundIso)
      .limit(BATCH_LIMIT);

    if (candErr) {
      console.error(
        `emit-event-reminder-events: candidate select failed at hours=${N}`,
        candErr,
      );
      // Don't blow up the whole batch — skip this N, continue with the
      // others. Sentry breadcrumb above carries the diagnostic.
      continue;
    }

    if (!candidates || candidates.length === 0) continue;
    totalScanned += candidates.length;

    // 3. Dedup against existing system_events with the exact (resource_id, hours)
    // key. payload->>'hours' is text in pg; cast both sides to text for the
    // IN filter. Use `=` not `@>` so the dedup is precise (a payload like
    // {hours:24,other:1} would NOT collide with {hours:24} either way since
    // we always emit a clean {hours:N} shape ourselves).
    const candidateIds = (candidates as EventRow[]).map((e) => e.id);
    const { data: existing, error: dedupErr } = await supabase
      .from("system_events")
      .select("resource_id, payload")
      .eq("event_type", "hoursBeforeEvent")
      .in("resource_id", candidateIds);

    if (dedupErr) {
      console.error(
        `emit-event-reminder-events: dedup select failed at hours=${N}`,
        dedupErr,
      );
      continue;
    }

    const dedupKey = (resourceId: string) => `${resourceId}|${N}`;
    const alreadyEmitted = new Set<string>();
    for (const row of existing ?? []) {
      const r = row as { resource_id: string; payload: Record<string, unknown> };
      const h = Number(r.payload?.hours);
      if (Number.isFinite(h) && Math.floor(h) === N) {
        alreadyEmitted.add(dedupKey(r.resource_id));
      }
    }

    const toEmit = (candidates as EventRow[]).filter(
      (e) => !alreadyEmitted.has(dedupKey(e.id)),
    );
    if (toEmit.length === 0) continue;

    const rows = toEmit.map((e) => ({
      group_id: e.group_id,
      event_type: "hoursBeforeEvent",
      resource_id: e.id,
      payload: { hours: N, starts_at: e.starts_at },
    }));

    // V8 fix (mig 00302): route through record_system_events_batch RPC.
    const { error: insErr } = await supabase.rpc("record_system_events_batch", { p_events: rows });
    if (insErr) {
      console.error(
        `emit-event-reminder-events: insert failed at hours=${N}`,
        insErr,
      );
      continue;
    }
    totalEmitted += toEmit.length;
  }

  const finishedAt = new Date();
  console.log(
    `emit-event-reminder-events: hours=[${hoursList.join(",")}] scanned ${totalScanned} emitted ${totalEmitted} in ${finishedAt.getTime() - startedAt.getTime()}ms`,
  );

  return new Response(
    JSON.stringify({
      hours_active: hoursList,
      scanned: totalScanned,
      emitted: totalEmitted,
      duration_ms: finishedAt.getTime() - startedAt.getTime(),
    }),
    { headers: { "Content-Type": "application/json" } },
  );
}, { functionName: "emit-event-reminder-events" }));
