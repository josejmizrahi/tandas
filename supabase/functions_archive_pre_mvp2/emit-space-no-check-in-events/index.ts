// emit-space-no-check-in-events: cron that emits the synthetic
// `bookingNoCheckIn` atom the rule engine needs to trigger the
// `space_no_check_in_release` template (SpaceRules.md §1 + §3).
//
//   - bookingNoCheckIn  fired per active booking on a space whose
//                       metadata.starts_at + GRACE_MINUTES has
//                       passed AND no checkInRecorded atom exists
//                       for the (space, booker) pair.
//                       Payload: { booking_id, starts_at,
//                                  minutes_overdue, grace_minutes }.
//                       member_id = the booker (so rules can fine
//                       the right person without re-resolving).
//
// "Active booking" = a row in public.bookings whose target is a
// space (slot_id → resources where resource_type='space') AND no
// later bookingCancelled / bookingExpired atom retired it.
//
// Suggested schedule: "*/5 * * * *" (every 5 minutes). The cron
// itself is idempotent within a 24h window — we skip emission when
// a bookingNoCheckIn atom already fired for the same booking_id in
// the last day, so multiple ticks within the same day don't pile up
// duplicate fines / releases.
//
// Uses service_role to bypass RLS — system_events insertion mirrors
// emit-asset-overdue-events.
//
// Plans/Active/SpaceRules.md PR-2 + TalmudicGovernance §4.A
// (acto > estado: el atom es la verdad de "no apareció a tiempo";
// la consequence releaseBooking actua sobre el atom en PR-3).

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { withSentry } from "../_shared/sentry.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// 24h dedup window — once we've fired a bookingNoCheckIn for a
// booking, we suppress further emissions until a day passes. Stops a
// single overdue booking from spawning 288 fines per day (one per
// 5-min tick).
const DEDUP_WINDOW_HOURS = 24;

// Default grace_minutes — the per-rule shape config can override at
// evaluator time, but the cron has to pick a floor for emission.
// Rules with stricter thresholds (grace_minutes=0) won't fire faster
// than this floor; loosen the floor only if real usage demands it.
const GRACE_MINUTES_DEFAULT = 30;

// Cap candidate fetches to keep edge function execution bounded.
// Real ops issue at >500 active bookings per cron tick = need
// pagination or a precomputed candidate view, not raw select.
const CANDIDATE_LIMIT = 500;

serve(withSentry(async (_req) => {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const startedAt = new Date();
  const dedupCutoff = new Date(
    startedAt.getTime() - DEDUP_WINDOW_HOURS * 3_600_000,
  ).toISOString();
  const graceCutoffIso = new Date(
    startedAt.getTime() - GRACE_MINUTES_DEFAULT * 60_000,
  ).toISOString();

  const emitted = await emitNoCheckIn(supabase, startedAt, dedupCutoff, graceCutoffIso);

  const finishedAt = new Date();
  console.log(
    `emit-space-no-check-in-events: emitted ${emitted} in ${finishedAt.getTime() - startedAt.getTime()}ms`,
  );

  return new Response(
    JSON.stringify({
      no_check_in_emitted: emitted,
      duration_ms: finishedAt.getTime() - startedAt.getTime(),
    }),
    { headers: { "Content-Type": "application/json" } },
  );
}, { functionName: "emit-space-no-check-in-events" }));

// =============================================================================
// No-check-in emitter
// =============================================================================

// deno-lint-ignore no-explicit-any
async function emitNoCheckIn(
  supabase: any,
  now: Date,
  dedupCutoff: string,
  graceCutoffIso: string,
): Promise<number> {
  // 1) Pull bookings whose metadata.starts_at < (now - grace_minutes)
  //    and whose target is a space. Supabase REST has no join, so we
  //    fetch bookings + filter target_kind='space' in the metadata
  //    payload (book_space stamps target_kind='space'; book_slot
  //    stamps target_kind='slot' or omits, defaulting to slot).
  const { data: bookings, error: bookErr } = await supabase
    .from("bookings")
    .select("id, group_id, slot_id, member_id, metadata, created_at")
    .lt("metadata->>starts_at", graceCutoffIso)
    .eq("metadata->>target_kind", "space")
    .order("created_at", { ascending: false })
    .limit(CANDIDATE_LIMIT);

  if (bookErr) {
    console.error("select bookings failed", bookErr);
    return 0;
  }
  if (!bookings || bookings.length === 0) return 0;

  const bookingIds = bookings.map((b: { id: string }) => b.id);
  const spaceIds = Array.from(new Set(bookings.map((b: { slot_id: string }) => b.slot_id)));

  // 2) Filter out bookings that were already retired
  //    (bookingCancelled / bookingExpired). The retirement atom's
  //    payload.booking_id is the join key.
  const { data: retired } = await supabase
    .from("system_events")
    .select("payload")
    .in("event_type", ["bookingCancelled", "bookingExpired"])
    .in("payload->>booking_id", bookingIds);
  const retiredIds = new Set(
    (retired ?? []).map((r: { payload: Record<string, unknown> }) =>
      r.payload?.booking_id as string | undefined
    ).filter(Boolean),
  );
  const active = bookings.filter((b: { id: string }) => !retiredIds.has(b.id));
  if (active.length === 0) return 0;

  // 3) Filter out bookings that already have a check-in. We check
  //    check_in_actions by space resource_id AND booker member_id,
  //    AND the action's payload.booking_id matches (so different
  //    bookings on the same space don't cross-cancel each other's
  //    no-check-in atoms).
  const activeSpaceIds = Array.from(new Set(active.map((b: { slot_id: string }) => b.slot_id)));
  const activeBookingIds = active.map((b: { id: string }) => b.id);
  const { data: checkIns } = await supabase
    .from("check_in_actions")
    .select("resource_id, member_id, metadata")
    .in("resource_id", activeSpaceIds);
  const checkedInBookingIds = new Set<string>();
  for (const ci of checkIns ?? []) {
    const bid = (ci.metadata as Record<string, unknown>)?.booking_id as string | undefined;
    if (bid && activeBookingIds.includes(bid)) {
      checkedInBookingIds.add(bid);
    }
  }
  const stillMissing = active.filter((b: { id: string }) => !checkedInBookingIds.has(b.id));
  if (stillMissing.length === 0) return 0;

  // 4) Dedup: skip bookings we already emitted a no-check-in atom for
  //    in the last 24h window.
  const stillMissingIds = stillMissing.map((b: { id: string }) => b.id);
  const { data: recentOverdues } = await supabase
    .from("system_events")
    .select("payload")
    .eq("event_type", "bookingNoCheckIn")
    .gte("occurred_at", dedupCutoff)
    .in("payload->>booking_id", stillMissingIds);
  const recentlyEmitted = new Set(
    (recentOverdues ?? []).map((r: { payload: Record<string, unknown> }) =>
      r.payload?.booking_id as string | undefined
    ).filter(Boolean),
  );
  const toEmit = stillMissing.filter((b: { id: string }) => !recentlyEmitted.has(b.id));
  if (toEmit.length === 0) return 0;

  // 5) Emit one bookingNoCheckIn per qualifying booking. resource_id =
  //    the space (so rules scoped to the space match); member_id =
  //    the booker (so the consequence fines / warns the right person).
  const rows = toEmit.map(
    (b: { id: string; group_id: string; slot_id: string; member_id: string; metadata: Record<string, unknown> }) => {
      const startsAtRaw = b.metadata?.starts_at as string | undefined;
      const startsMs = startsAtRaw ? new Date(startsAtRaw).getTime() : now.getTime();
      const minutesOverdue = Math.max(
        0,
        Math.floor((now.getTime() - startsMs) / 60_000) - GRACE_MINUTES_DEFAULT,
      );
      return {
        group_id: b.group_id,
        event_type: "bookingNoCheckIn",
        resource_id: b.slot_id,
        member_id: b.member_id,
        payload: {
          booking_id:       b.id,
          starts_at:        startsAtRaw,
          minutes_overdue:  minutesOverdue,
          grace_minutes:    GRACE_MINUTES_DEFAULT,
        },
      };
    },
  );

  // V8 fix (mig 00302): route through record_system_events_batch RPC.
  const { error: insErr } = await supabase.rpc("record_system_events_batch", { p_events: rows });
  if (insErr) {
    console.error("insert bookingNoCheckIn failed", insErr);
    return 0;
  }
  // Mark space context unused in this row count to silence lints.
  void spaceIds;
  return rows.length;
}
