// evaluate-event-rules: LEGACY on-demand rule evaluator for events.
//
// 🪦 DEPRECATED — returns 410 Gone. The slug is preserved in version
// control + deployed as a stub so any rogue caller gets a clear signal
// instead of a 500. A dashboard delete is the cleaner endpoint when
// someone gets to it.
//
// History
// =======
// Plans/Active/CleanupAudit_2026-05-18/11_post_execution_corrections.md §5:
// the original v9 implementation targeted `events` + `event_attendance`
// tables — both DROPPED in mig 00159 (Constitution.md §5c-iii.C "drop
// V1 RPCs muertos"). Every invocation 500'd on the first SELECT.
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
// Deployed as a 410 stub via `mcp__supabase__deploy_edge_function` on
// 2026-05-18 (v10). The prior v9 implementation can be retrieved via
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
