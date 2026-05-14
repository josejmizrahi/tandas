// send-fine-reminders: cron job that sends payment reminders for
// unpaid official fines at 3, 7, and 14 days.
//
// Suggested schedule: "0 12 * * *" (daily at noon UTC).
// Uses service_role to bypass RLS.
//
// V1 behaviour: identifies the candidate fines and emits a system event
// per reminder so the history reflects the nudge. Push delivery follows
// the outbox-first path: a `dispatch-notifications` cron (TBD) reads
// `notifications_outbox` rows and sends APNs once creds are configured.
// This function does NOT itself write to the outbox — that wiring is
// pending (item APNs, Plans/Audit-2026-05-06.md §9).
//
// To prevent re-firing on the same day, we record the reminder in
// fines.details.reminders[] (jsonb array). Records of the form:
//   { day_threshold: 3 | 7 | 14, sent_at: "2026-05-04T...Z" }
//
// Idempotent: a fine with a reminder already recorded for the highest
// applicable threshold is skipped.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { withSentry } from "../_shared/sentry.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BATCH_LIMIT = parseInt(Deno.env.get("FINE_REMINDERS_BATCH") ?? "200");

const THRESHOLDS_DAYS = [3, 7, 14] as const;

serve(withSentry(async (_req) => {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const startedAt = new Date();

  // Pull officialized, unpaid, un-waived fines older than 3 days. We'll
  // filter each into the appropriate threshold bucket below.
  const minAgeCutoff = new Date(startedAt);
  minAgeCutoff.setDate(minAgeCutoff.getDate() - THRESHOLDS_DAYS[0]);

  // §14 Step 3c: read derived status/paid/waived from fines_view.
  // The projection ensures status='officialized' implies !paid && !waived
  // (those are terminal states above officialized in the precedence) but
  // we keep the explicit filters for clarity. Updates to fine.details
  // below still go to the underlying fines table (details is a stored
  // column, not derived).
  const { data: fines, error: selErr } = await supabase
    .from("fines_view")
    .select("id, group_id, user_id, amount, created_at, details")
    .eq("status", "officialized")
    .eq("paid", false)
    .eq("waived", false)
    .lt("created_at", minAgeCutoff.toISOString())
    .limit(BATCH_LIMIT);

  if (selErr) {
    console.error("select unpaid fines failed", selErr);
    return new Response(JSON.stringify({ error: selErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  if (!fines || fines.length === 0) {
    return new Response(JSON.stringify({ reminders_sent: 0 }), {
      headers: { "Content-Type": "application/json" },
    });
  }

  let remindersSent = 0;
  const errors: Array<{ fine_id: string; error: string }> = [];

  for (const fine of fines) {
    const ageDays = Math.floor(
      (startedAt.getTime() - new Date(fine.created_at).getTime()) / 86_400_000
    );
    const applicableThreshold = highestApplicableThreshold(ageDays);
    if (!applicableThreshold) continue;

    const existingReminders: Array<{ day_threshold: number }> =
      fine.details?.reminders ?? [];
    if (existingReminders.some(r => r.day_threshold === applicableThreshold)) {
      continue;
    }

    const newReminder = {
      day_threshold: applicableThreshold,
      sent_at: startedAt.toISOString(),
    };
    const updatedDetails = {
      ...(fine.details ?? {}),
      reminders: [...existingReminders, newReminder],
    };

    const { error: updErr } = await supabase
      .from("fines")
      .update({ details: updatedDetails })
      .eq("id", fine.id);
    if (updErr) {
      errors.push({ fine_id: fine.id, error: `update: ${updErr.message}` });
      continue;
    }

    // Emit a system event so the timeline reflects the nudge. Push
    // delivery is the dispatcher cron's job (outbox-first path, pending).
    const { error: evErr } = await supabase
      .from("system_events")
      .insert({
        group_id:   fine.group_id,
        event_type: "fineReminderSent",
        member_id:  fine.user_id,
        payload:    {
          fine_id:       fine.id,
          amount:        fine.amount,
          day_threshold: applicableThreshold,
          age_days:      ageDays,
        },
      });
    if (evErr) {
      console.error(`emit fineReminderSent for ${fine.id} failed`, evErr);
    }

    remindersSent++;
  }

  const finishedAt = new Date();
  console.log(`send-fine-reminders: scanned ${fines.length} fines, sent ${remindersSent} reminders in ${finishedAt.getTime() - startedAt.getTime()}ms (${errors.length} errors)`);

  return new Response(JSON.stringify({
    fines_scanned: fines.length,
    reminders_sent: remindersSent,
    errors,
    duration_ms: finishedAt.getTime() - startedAt.getTime(),
  }), { headers: { "Content-Type": "application/json" } });
}, { functionName: "send-fine-reminders" }));

function highestApplicableThreshold(ageDays: number): number | null {
  // Walk THRESHOLDS_DAYS descending so the most overdue threshold wins.
  for (let i = THRESHOLDS_DAYS.length - 1; i >= 0; i--) {
    if (ageDays >= THRESHOLDS_DAYS[i]) return THRESHOLDS_DAYS[i];
  }
  return null;
}
