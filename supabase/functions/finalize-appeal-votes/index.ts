// finalize-appeal-votes: cron that closes appeals whose voting_ends_at
// has passed, using the close_appeal_vote RPC (handles quorum/threshold +
// fine voiding + appealResolved system_event emission).
//
// Schedule: every 15 minutes (pg_cron job `finalize-appeal-votes-15min`,
// restored by mig 00328 after mig 00327's mistaken unschedule). Idempotent
// — close_appeal_vote is safe to call on already-closed appeals; it'll
// just no-op.
//
// Restored to repo 2026-05-18 — this function had been deployed to the
// Supabase project since 2026-04-15 but never lived in version control.
// Discovered while executing Plans/Active/CleanupAudit_2026-05-18; see
// 11_post_execution_corrections.md §5.
//
// Distinct from `finalize-votes` (generic vote finalizer that reads the
// `votes` table). This one reads the `appeals` table (separate workflow
// with its own quorum/threshold + fine-voiding semantics).

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(async (_req) => {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const now = new Date().toISOString();

  const { data: expired, error: selErr } = await supabase
    .from("appeals")
    .select("id")
    .eq("status", "voting")
    .lt("voting_ends_at", now)
    .limit(100);

  if (selErr) return new Response(JSON.stringify({ error: selErr.message }), { status: 500 });
  if (!expired || expired.length === 0) {
    return new Response(JSON.stringify({ closed: 0 }), { status: 200 });
  }

  let closed = 0;
  let errors = 0;
  const outcomes: Record<string, number> = {};

  for (const appeal of expired) {
    try {
      const { data: outcome, error } = await supabase.rpc("close_appeal_vote", { p_appeal_id: appeal.id });
      if (error) throw new Error(error.message);
      const out = outcome as string;
      outcomes[out] = (outcomes[out] ?? 0) + 1;
      closed += 1;
    } catch (e) {
      console.error("[finalize-appeal-votes] appeal failed", appeal.id, e);
      errors += 1;
    }
  }

  return new Response(
    JSON.stringify({ closed, errors, outcomes }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});
