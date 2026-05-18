// evaluate-event-rules: LEGACY on-demand rule evaluator for events.
//
// ⚠️ DEAD ON PROD — DO NOT REDEPLOY ⚠️
//
// Plans/Active/CleanupAudit_2026-05-18/11_post_execution_corrections.md §5:
// this function is deployed to Supabase (slug `evaluate-event-rules`,
// version 9, ACTIVE) but its SELECT targets `events` + `event_attendance`
// — both DROPPED in mig 00159 (Constitution.md §5c-iii.C "drop V1 RPCs
// muertos"). Every invocation now 500s on the very first SELECT.
//
// The function was the V1 on-demand evaluator path: an iOS coordinator
// passed an event_id and the function loaded matching rules + ran the
// engine inline. The pattern was superseded by:
//
//   - the `process-system-events` cron (1/min) that drains the
//     append-only `system_events` log, which the V2 writers
//     (`close_event_no_fines` etc.) emit per Constitution §14 step 5c.
//   - the `events_view` / `attendance_view` atom-derived projections
//     (mig 00152 / 00156) for read paths that used to hit events directly.
//
// Why this file exists then: source/prod drift. The deployed bytes had
// been living only in the Supabase dashboard with no version-control
// presence. Plans/Active/CleanupAudit_2026-05-18 task #20 tracks the
// dashboard undeploy (mcp__supabase__list_edge_functions has no delete
// tool — needs a human at the dashboard). Until that happens, the
// committed source is this stub: 410 Gone so any rogue caller learns
// fast.
//
// The original 200-LOC implementation can be retrieved via
// `mcp__supabase__get_edge_function({ function_slug: "evaluate-event-rules" })`
// if archeology is ever needed.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

serve((_req) =>
  new Response(
    JSON.stringify({
      error: "gone",
      message:
        "evaluate-event-rules is deprecated and has no live DB dependencies. " +
        "Rule evaluation now runs through the process-system-events cron over " +
        "the system_events atom log. Undeploy pending — see Plans/Active/" +
        "CleanupAudit_2026-05-18 task #20.",
    }),
    {
      status: 410, // Gone
      headers: { "Content-Type": "application/json" },
    },
  )
);
