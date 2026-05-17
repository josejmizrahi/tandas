// emit-asset-overdue-events: cron that emits the two synthetic asset
// overdue atoms the rule engine needs to trigger AssetRules.md §1 templates.
//
//   - assetCheckoutOverdue    fired per asset whose latest assetCheckedOut
//                             row has expected_return_at in the past AND
//                             no later assetCheckedIn has closed it.
//                             Payload: { expected_return_at, checked_out_at,
//                                        days_overdue }.
//                             member_id = holder (so the rule engine fines
//                             the right person without re-resolving).
//
//   - assetMaintenanceOverdue fired per asset whose latest maintenanceLogged
//                             row has been open for > GRACE_DAYS without a
//                             matching maintenanceCompleted referencing it.
//                             Payload: { maintenance_event_id, days_open }.
//                             member_id = null (resource-scoped).
//
// Suggested schedule: "*/5 * * * *" (every 5 minutes). The cron itself
// is idempotent within a 24h window — we skip emission when the same
// atom already fired for that asset in the last day, so multiple ticks
// within the same day don't pile up duplicate fines / locks.
//
// Uses service_role to bypass RLS — system_events insertion mirrors
// emit-deadline-events.
//
// Plans/Active/AssetRules.md §5 + §9 (idempotency window).

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { withSentry } from "../_shared/sentry.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// 24h dedup window — once we've fired an overdue atom for an asset, we
// suppress further emissions for the same atom_type+resource_id until
// a day passes. Stops a single overdue checkout from spawning 1440
// fines per day (one per minute of the cron).
const DEDUP_WINDOW_HOURS = 24;

// Default grace_days for checkout/maintenance — the per-rule shape
// config can override at evaluator time, but the cron has to pick a
// floor for emission. Rules with stricter thresholds (grace_days=0)
// won't fire faster than this floor; loosen the floor only if real
// usage demands it.
const CHECKOUT_GRACE_DAYS_DEFAULT = 1;
const MAINTENANCE_GRACE_DAYS_DEFAULT = 7;

serve(withSentry(async (_req) => {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const startedAt = new Date();
  const dedupCutoff = new Date(
    startedAt.getTime() - DEDUP_WINDOW_HOURS * 3_600_000,
  ).toISOString();

  const checkoutEmitted = await emitCheckoutOverdue(supabase, startedAt, dedupCutoff);
  const maintenanceEmitted = await emitMaintenanceOverdue(supabase, startedAt, dedupCutoff);

  const finishedAt = new Date();
  console.log(
    `emit-asset-overdue-events: emitted ${checkoutEmitted} checkout + ${maintenanceEmitted} maintenance in ${finishedAt.getTime() - startedAt.getTime()}ms`,
  );

  return new Response(
    JSON.stringify({
      checkout_emitted: checkoutEmitted,
      maintenance_emitted: maintenanceEmitted,
      duration_ms: finishedAt.getTime() - startedAt.getTime(),
    }),
    { headers: { "Content-Type": "application/json" } },
  );
}, { functionName: "emit-asset-overdue-events" }));

// =============================================================================
// Checkout overdue emitter
// =============================================================================

// deno-lint-ignore no-explicit-any
async function emitCheckoutOverdue(supabase: any, now: Date, dedupCutoff: string): Promise<number> {
  // Pull every assetCheckedOut whose expected_return_at is in the past.
  // We do the join-and-exclude in two passes (Supabase REST has no
  // window functions) but the volume per group is bounded — a real
  // ops issue would be a missing index, not the read pattern.
  const { data: checkouts, error: outErr } = await supabase
    .from("system_events")
    .select("id, group_id, resource_id, member_id, occurred_at, payload")
    .eq("event_type", "assetCheckedOut")
    .not("payload->>expected_return_at", "is", null)
    .order("occurred_at", { ascending: false })
    .limit(500);

  if (outErr) {
    console.error("select assetCheckedOut failed", outErr);
    return 0;
  }
  if (!checkouts || checkouts.length === 0) return 0;

  // Latest checkout per asset wins. Same asset checked-out twice has
  // two rows; only the most recent matters for "still out".
  const latestByAsset = new Map<string, typeof checkouts[number]>();
  for (const c of checkouts) {
    if (!latestByAsset.has(c.resource_id)) {
      latestByAsset.set(c.resource_id, c);
    }
  }

  const candidates = Array.from(latestByAsset.values()).filter((c) => {
    const expectedAt = c.payload?.expected_return_at as string | undefined;
    if (!expectedAt) return false;
    const expectedMs = new Date(expectedAt).getTime();
    if (Number.isNaN(expectedMs)) return false;
    const graceMs = CHECKOUT_GRACE_DAYS_DEFAULT * 86_400_000;
    return now.getTime() - expectedMs > graceMs;
  });
  if (candidates.length === 0) return 0;

  // Filter out assets that have a later assetCheckedIn — those came back.
  const assetIds = candidates.map((c) => c.resource_id);
  const { data: checkins } = await supabase
    .from("system_events")
    .select("resource_id, occurred_at")
    .eq("event_type", "assetCheckedIn")
    .in("resource_id", assetIds);
  const latestCheckinByAsset = new Map<string, number>();
  for (const ci of checkins ?? []) {
    const ts = new Date(ci.occurred_at).getTime();
    const prev = latestCheckinByAsset.get(ci.resource_id) ?? 0;
    if (ts > prev) latestCheckinByAsset.set(ci.resource_id, ts);
  }
  const stillOut = candidates.filter((c) => {
    const checkinTs = latestCheckinByAsset.get(c.resource_id);
    if (!checkinTs) return true;
    return checkinTs < new Date(c.occurred_at).getTime();
  });
  if (stillOut.length === 0) return 0;

  // Dedup: skip assets we already emitted an overdue for in the window.
  const { data: recentOverdues } = await supabase
    .from("system_events")
    .select("resource_id")
    .eq("event_type", "assetCheckoutOverdue")
    .gte("occurred_at", dedupCutoff)
    .in("resource_id", stillOut.map((c) => c.resource_id));
  const recentlyEmitted = new Set((recentOverdues ?? []).map((r: { resource_id: string }) => r.resource_id));
  const toEmit = stillOut.filter((c) => !recentlyEmitted.has(c.resource_id));
  if (toEmit.length === 0) return 0;

  const rows = toEmit.map((c) => {
    const expectedMs = new Date(c.payload!.expected_return_at as string).getTime();
    const daysOverdue = Math.floor((now.getTime() - expectedMs) / 86_400_000);
    return {
      group_id: c.group_id,
      event_type: "assetCheckoutOverdue",
      resource_id: c.resource_id,
      member_id: c.member_id,
      payload: {
        expected_return_at: c.payload!.expected_return_at,
        checked_out_at:     c.occurred_at,
        days_overdue:       daysOverdue,
      },
    };
  });

  const { error: insErr } = await supabase.from("system_events").insert(rows);
  if (insErr) {
    console.error("insert assetCheckoutOverdue failed", insErr);
    return 0;
  }
  return rows.length;
}

// =============================================================================
// Maintenance overdue emitter
// =============================================================================

// deno-lint-ignore no-explicit-any
async function emitMaintenanceOverdue(supabase: any, now: Date, dedupCutoff: string): Promise<number> {
  // Open maintenance events = maintenanceLogged minus matching
  // maintenanceCompleted. We grab the candidates and filter client-side
  // for completion + overdue cutoff; same shape as the checkout emitter.
  const { data: logged, error: logErr } = await supabase
    .from("system_events")
    .select("id, group_id, resource_id, occurred_at, payload")
    .eq("event_type", "maintenanceLogged")
    .lt(
      "occurred_at",
      new Date(now.getTime() - MAINTENANCE_GRACE_DAYS_DEFAULT * 86_400_000).toISOString(),
    )
    .limit(500);
  if (logErr) {
    console.error("select maintenanceLogged failed", logErr);
    return 0;
  }
  if (!logged || logged.length === 0) return 0;

  // Fetch completion atoms that reference any of our candidates.
  const loggedIds = logged.map((l) => l.id);
  const { data: completed } = await supabase
    .from("system_events")
    .select("payload")
    .eq("event_type", "maintenanceCompleted")
    .in("payload->>maintenance_event_id", loggedIds.map((id) => id.toString()));
  const completedIds = new Set(
    (completed ?? []).map((c: { payload: Record<string, unknown> }) =>
      c.payload?.maintenance_event_id as string | undefined
    ).filter(Boolean),
  );
  const stillOpen = logged.filter((l) => !completedIds.has(l.id));
  if (stillOpen.length === 0) return 0;

  // Dedup window — one assetMaintenanceOverdue per asset per 24h.
  const { data: recentOverdues } = await supabase
    .from("system_events")
    .select("resource_id")
    .eq("event_type", "assetMaintenanceOverdue")
    .gte("occurred_at", dedupCutoff)
    .in("resource_id", stillOpen.map((l) => l.resource_id));
  const recentlyEmitted = new Set(
    (recentOverdues ?? []).map((r: { resource_id: string }) => r.resource_id),
  );
  const toEmit = stillOpen.filter((l) => !recentlyEmitted.has(l.resource_id));
  if (toEmit.length === 0) return 0;

  const rows = toEmit.map((l) => {
    const loggedMs = new Date(l.occurred_at).getTime();
    const daysOpen = Math.floor((now.getTime() - loggedMs) / 86_400_000);
    return {
      group_id: l.group_id,
      event_type: "assetMaintenanceOverdue",
      resource_id: l.resource_id,
      member_id: null,
      payload: {
        maintenance_event_id: l.id,
        days_open:            daysOpen,
        logged_at:            l.occurred_at,
      },
    };
  });

  const { error: insErr } = await supabase.from("system_events").insert(rows);
  if (insErr) {
    console.error("insert assetMaintenanceOverdue failed", insErr);
    return 0;
  }
  return rows.length;
}
