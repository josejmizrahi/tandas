// finalize-fine-reviews: cron job that officializes proposed fines past
// their grace period.
//
// Suggested schedule: "0 * * * *" (hourly).
// Uses service_role to bypass RLS.
//
// Flow: for each fine_review_period whose expires_at < now() and
// officialized_at is null:
//   - Set fine_review_periods.officialized_at = now().
//   - Update related fines on the same event from status='proposed' to
//     status='official'.
//   - Emit a `fineOfficialized` system event per officialized fine so the
//     rule engine + history pick it up.
//
// Idempotent: rows with officialized_at already set are skipped.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { getNow } from "../_shared/time.ts";
import { withSentry } from "../_shared/sentry.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BATCH_LIMIT = parseInt(Deno.env.get("FINALIZE_FINES_BATCH") ?? "50");

serve(withSentry(async (req) => {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const startedAt = getNow(req);

  const { data: expired, error: selErr } = await supabase
    .from("fine_review_periods")
    .select("id, event_id, proposed_at, expires_at")
    .is("officialized_at", null)
    .lt("expires_at", startedAt.toISOString())
    .limit(BATCH_LIMIT);

  if (selErr) {
    console.error("select expired review periods failed", selErr);
    return new Response(JSON.stringify({ error: selErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  if (!expired || expired.length === 0) {
    return new Response(JSON.stringify({ processed: 0 }), {
      headers: { "Content-Type": "application/json" },
    });
  }

  let officializedFines = 0;
  const errors: Array<{ event_id: string; error: string }> = [];

  for (const rp of expired) {
    const { error: rpErr } = await supabase
      .from("fine_review_periods")
      .update({ officialized_at: startedAt.toISOString() })
      .eq("id", rp.id);
    if (rpErr) {
      errors.push({ event_id: rp.event_id, error: `review_period: ${rpErr.message}` });
      continue;
    }

    const { data: fines, error: finesSelErr } = await supabase
      .from("fines")
      .select("id, group_id, user_id, amount")
      .eq("event_id", rp.event_id)
      .eq("status", "proposed");
    if (finesSelErr) {
      errors.push({ event_id: rp.event_id, error: `fines select: ${finesSelErr.message}` });
      continue;
    }

    if (!fines || fines.length === 0) continue;

    const fineIds = fines.map(f => f.id);
    const { error: updateErr } = await supabase
      .from("fines")
      .update({ status: "official" })
      .in("id", fineIds);
    if (updateErr) {
      errors.push({ event_id: rp.event_id, error: `fines update: ${updateErr.message}` });
      continue;
    }

    for (const fine of fines) {
      const { error: evErr } = await supabase
        .from("system_events")
        .insert({
          group_id:    fine.group_id,
          event_type:  "fineOfficialized",
          resource_id: rp.event_id,
          payload:     { fine_id: fine.id, member_id: fine.user_id, amount: fine.amount },
        });
      if (evErr) {
        console.error(`emit fineOfficialized for ${fine.id} failed`, evErr);
      }

      // Resolve recipient_member_id from (group_id, user_id) so the outbox
      // row points to the membership, not just the user. If the membership
      // was deleted between propose and officialize we skip the outbox
      // write rather than orphan the notification.
      const { data: memberRow } = await supabase
        .from("group_members")
        .select("id")
        .eq("group_id", fine.group_id)
        .eq("user_id", fine.user_id)
        .maybeSingle();

      if (memberRow?.id) {
        const { error: outboxErr } = await supabase
          .from("notifications_outbox")
          .insert({
            group_id: fine.group_id,
            recipient_member_id: memberRow.id,
            notification_type: "fineOfficialized",
            payload: {
              fine_id: fine.id,
              event_id: rp.event_id,
              amount: fine.amount,
            },
            deep_link: `ruul://fine/${fine.id}`,
          });
        if (outboxErr) {
          console.error(`outbox fineOfficialized for ${fine.id} failed`, outboxErr);
        }
      }

      officializedFines++;
    }
  }

  const finishedAt = new Date();
  console.log(`finalize-fine-reviews: ${expired.length} review periods, ${officializedFines} fines officialized in ${finishedAt.getTime() - startedAt.getTime()}ms (${errors.length} errors)`);

  return new Response(JSON.stringify({
    processed_review_periods: expired.length,
    officialized_fines: officializedFines,
    errors,
    duration_ms: finishedAt.getTime() - startedAt.getTime(),
  }), { headers: { "Content-Type": "application/json" } });
}, { functionName: "finalize-fine-reviews" }));
