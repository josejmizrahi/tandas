// finalize-fine-reviews: cron job that officializes proposed fines past
// their grace period.
//
// Suggested schedule: "0 * * * *" (hourly).
// Uses service_role to bypass RLS.
//
// Flow: for each fine_review_period whose expires_at < now() and
// officialized_at is null:
//   - Set fine_review_periods.officialized_at = now().
//   - Find proposed fines on the same event (via fines_view projection).
//   - Emit a `fine_officialized` ledger atom for each. The on_fine_atom_inserted
//     trigger creates user_action 'finePending' and emits system_event
//     'fineOfficialized'; we only need to insert the notifications_outbox
//     row for push dispatch (which the atom trigger doesn't handle).
//
// Idempotent: rows with officialized_at already set are skipped; the
// fine_officialized atom emission is also gated by atom existence so a
// re-run doesn't double-emit.
//
// Constitution §14 Step 3c phase 2: this function no longer UPDATEs
// fines.status — the column is gone (mig 00151). Status derives from atom.

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

    // Read proposed fines for this event from the projection.
    // Post-Step 3c: status is derived; reading from fines_view ensures we
    // only target fines that are actually still 'proposed' (no atom yet,
    // no open appeal, no payment/void).
    const { data: fines, error: finesSelErr } = await supabase
      .from("fines_view")
      .select("id, group_id, user_id, amount, resource_id, rule_id, reason")
      .eq("event_id", rp.event_id)
      .eq("status", "proposed");
    if (finesSelErr) {
      errors.push({ event_id: rp.event_id, error: `fines select: ${finesSelErr.message}` });
      continue;
    }

    if (!fines || fines.length === 0) continue;

    for (const fine of fines) {
      // Resolve recipient_member_id once per fine: used both as the
      // ledger atom's from_member_id and as the outbox recipient. If the
      // member has since left, atom still emits (from_member_id NULL) but
      // we skip outbox (no recipient).
      const { data: memberRow } = await supabase
        .from("group_members")
        .select("id")
        .eq("group_id", fine.group_id)
        .eq("user_id", fine.user_id)
        .maybeSingle();

      // Emit the fine_officialized atom. The on_fine_atom_inserted trigger
      // creates user_action 'finePending' + emits system_event 'fineOfficialized'.
      const { error: atomErr } = await supabase
        .from("ledger_entries")
        .insert({
          group_id:       fine.group_id,
          resource_id:    fine.resource_id,
          type:           "fine_officialized",
          amount_cents:   Math.round(Number(fine.amount) * 100),
          currency:       "MXN",
          from_member_id: memberRow?.id ?? null,
          to_member_id:   null,
          metadata: {
            fine_id: fine.id,
            rule_id: fine.rule_id,
            via:     "finalize-fine-reviews-cron",
          },
          occurred_at: startedAt.toISOString(),
          recorded_at: startedAt.toISOString(),
          recorded_by: null,
        });
      if (atomErr) {
        errors.push({ event_id: rp.event_id, error: `atom insert: ${atomErr.message}` });
        continue;
      }

      // Push notification dispatch — atom trigger doesn't write to the
      // outbox. Skip if the member is gone (no recipient).
      if (memberRow?.id) {
        const { error: outboxErr } = await supabase
          .from("notifications_outbox")
          .insert({
            group_id: fine.group_id,
            recipient_member_id: memberRow.id,
            notification_type: "fineOfficialized",
            payload: {
              fine_id:  fine.id,
              event_id: rp.event_id,
              amount:   fine.amount,
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
