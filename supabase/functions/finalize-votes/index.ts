// finalize-votes: cron job that closes votes whose closes_at has passed.
//
// Deploy as a scheduled function (cron expression "*/5 * * * *" — every
// 5 minutes). Uses service_role to bypass RLS. For each open vote past
// its closes_at, calls finalize_vote(id) RPC which:
//   - computes resolution (passed | failed | quorum_failed)
//   - updates votes.status + votes.counts + votes.resolved_at
//   - emits a `voteResolved` system_event (the rule engine cron picks it
//     up and runs any rule whose trigger is `voteResolved`).
//
// Idempotent: finalize_vote returns cached resolution if already resolved.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { getNow } from "../_shared/time.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BATCH_LIMIT = parseInt(Deno.env.get("FINALIZE_VOTES_BATCH") ?? "100");

serve(async (req) => {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const startedAt = getNow(req);

  const { data: open, error: selErr } = await supabase
    .from("votes")
    .select("id, group_id, vote_type, closes_at")
    .eq("status", "open")
    .lt("closes_at", startedAt.toISOString())
    .limit(BATCH_LIMIT);

  if (selErr) {
    console.error("select open expired votes failed", selErr);
    return new Response(JSON.stringify({ error: selErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  if (!open || open.length === 0) {
    return new Response(JSON.stringify({ processed: 0 }), {
      headers: { "Content-Type": "application/json" },
    });
  }

  const results: Array<{ vote_id: string; resolution: string | null; error?: string }> = [];

  for (const v of open) {
    const { data, error } = await supabase.rpc("finalize_vote", { p_vote_id: v.id });
    if (error) {
      console.error(`finalize_vote(${v.id}) failed`, error);
      results.push({ vote_id: v.id, resolution: null, error: error.message });
    } else {
      results.push({ vote_id: v.id, resolution: data });
    }
  }

  const finishedAt = new Date();
  const successCount = results.filter(r => !r.error).length;

  console.log(`finalize-votes: processed ${results.length} votes (${successCount} ok, ${results.length - successCount} errored) in ${finishedAt.getTime() - startedAt.getTime()}ms`);

  return new Response(JSON.stringify({
    processed: results.length,
    succeeded: successCount,
    results,
    duration_ms: finishedAt.getTime() - startedAt.getTime(),
  }), { headers: { "Content-Type": "application/json" } });
});
