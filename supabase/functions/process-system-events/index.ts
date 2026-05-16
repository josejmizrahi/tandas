// process-system-events: cron consumer of the system_events log.
//
// Schedule: every minute. Picks the next batch of unprocessed events
// (occurred_at oldest first), loads the matching rules + context, runs the
// rule engine, and marks each event processed.
//
// Idempotency: an event is only marked processed AFTER its consequences
// commit. If the function crashes mid-batch, the next run picks it up
// again. proposeFine itself short-circuits if a fine already exists for
// (event_id, user_id, rule_id) in proposed/officialized/in_appeal state.
//
// Sprint 1c: proposeFine inserts user_id (not member_id) and details
// (not evidence), matching the legacy fines table schema. The cron runs
// as service role so auth.uid() is null — the rsvpChangedSameDay trigger
// resolves the target via event.payload.user_id (iOS coordinator includes
// it explicitly).

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { runRulesForEvent, type ConsequenceSink, type RuleContext } from "../_shared/ruleEngine.ts";
import {
  composeResourceLike,
  mapAttendanceToCheckIns,
  mapAttendanceToRsvps,
  type EventAttendanceRow,
  type EventsViewRow,
  type ResourcesRow,
} from "../_shared/ruleContext.ts";
import { getNow } from "../_shared/time.ts";
import type { Rule, SystemEvent } from "../_shared/platformTypes.ts";
import { withSentry } from "../_shared/sentry.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BATCH_SIZE = parseInt(Deno.env.get("BATCH_SIZE") ?? "100");

serve(withSentry(async (req) => {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const now = getNow(req);

  // 1. Pull unprocessed events
  const { data: events, error: selErr } = await supabase
    .from("system_events")
    .select("*")
    .is("processed_at", null)
    .order("occurred_at", { ascending: true })
    .limit(BATCH_SIZE);

  if (selErr) {
    console.error("[process-system-events] select failed", selErr);
    return new Response(JSON.stringify({ error: selErr.message }), { status: 500 });
  }

  if (!events || events.length === 0) {
    return new Response(JSON.stringify({ processed: 0 }), { status: 200 });
  }

  let totalResults = 0;
  let totalErrors = 0;

  for (const event of events as SystemEvent[]) {
    try {
      // 2. Load rules for this event's group + matching the event type
      const { data: rules } = await supabase
        .from("rules")
        .select("*")
        .eq("group_id", event.group_id)
        .eq("is_active", true);

      const matchingRules = (rules ?? []).filter((r: Rule) =>
        r.trigger?.eventType === event.event_type
      );

      if (matchingRules.length === 0) {
        // No rules to run — still mark processed so we don't retry
        await markProcessed(supabase, event.id, now);
        continue;
      }

      // 3. Build context
      const context = await buildContext(supabase, event, now);

      // 4. Run engine
      const results = await runRulesForEvent(event, matchingRules as Rule[], context);
      totalResults += results.length;
      totalErrors += results.filter((r) => !r.success).length;

      // 5. Mark processed
      await markProcessed(supabase, event.id, now, results);
    } catch (e) {
      console.error("[process-system-events] event failed", event.id, e);
      totalErrors += 1;
      // Do NOT mark processed — let the next run retry
    }
  }

  return new Response(
    JSON.stringify({
      processed: events.length,
      consequences: totalResults,
      errors: totalErrors,
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}, { functionName: "process-system-events" }));

async function markProcessed(
  supabase: ReturnType<typeof createClient>,
  eventId: string,
  now: Date,
  results?: unknown[],
) {
  const update: Record<string, unknown> = { processed_at: now.toISOString() };
  if (results) {
    update.payload = { results };
  }
  await supabase.from("system_events").update(update).eq("id", eventId);
}

async function buildContext(
  supabase: ReturnType<typeof createClient>,
  event: SystemEvent,
  now: Date,
): Promise<RuleContext> {
  // Members of the group
  const { data: members } = await supabase
    .from("group_members")
    .select("id, user_id, active")
    .eq("group_id", event.group_id);

  // Resource resolution — polymorphic. IO happens here; the shape decision
  // (events_view vs resources row, attendance → RSVP/check-in derivation)
  // lives in `_shared/ruleContext.ts` so it's unit-testable without a
  // live Supabase connection. See that file's doc-comment for the
  // decision tree.
  let resource: RuleContext["resource"] = null;
  let rsvps: RuleContext["rsvps"] = [];
  let checkIns: RuleContext["checkIns"] = [];

  if (event.resource_id) {
    const { data: r } = await supabase
      .from("resources")
      .select("id, group_id, resource_type, status, metadata, series_id")
      .eq("id", event.resource_id)
      .maybeSingle();

    if (r) {
      let ev: EventsViewRow | null = null;
      let attendance: EventAttendanceRow[] = [];

      if (r.resource_type === "event") {
        const evResult = await supabase
          .from("events_view")
          .select("*")
          .eq("resource_id", event.resource_id)
          .maybeSingle();
        ev = (evResult.data as EventsViewRow | null) ?? null;

        if (ev) {
          // §14 step 5c-iii.A: reads from attendance_view (atoms projection).
          const attResult = await supabase
            .from("attendance_view")
            .select("user_id, rsvp_status, rsvp_at, cancelled_same_day, arrived_at")
            .eq("event_id", event.resource_id);
          attendance = (attResult.data as EventAttendanceRow[] | null) ?? [];
        }
      }

      resource = composeResourceLike(r as ResourcesRow, ev);

      if (resource && r.resource_type === "event") {
        const startsAt = (resource.metadata.starts_at as string | undefined) ?? null;
        rsvps = mapAttendanceToRsvps(attendance);
        checkIns = mapAttendanceToCheckIns(attendance, startsAt);
      }
    }
  }

  // Anti-tirania monthly fine cap context. Sprint 1c: fines table keys by
  // user_id (not member_id) so we count + index on user_id.
  const monthStart = new Date(now.getTime());
  monthStart.setDate(1);
  monthStart.setHours(0, 0, 0, 0);

  const { data: monthFines } = await supabase
    .from("fines")
    .select("user_id")
    .eq("group_id", event.group_id)
    .gte("created_at", monthStart.toISOString());

  const finesThisMonthByMember = new Map<string, number>();
  for (const f of monthFines ?? []) {
    finesThisMonthByMember.set(f.user_id, (finesThisMonthByMember.get(f.user_id) ?? 0) + 1);
  }

  // proposeFine resolves member_id (group_members.id) → user_id (auth.users.id)
  // before inserting into the legacy fines table. Idempotent: skips if a
  // matching open fine already exists for this (event, user, rule).
  const memberIdToUserId = new Map<string, string>();
  for (const m of members ?? []) memberIdToUserId.set(m.id, m.user_id);

  const sink: ConsequenceSink = {
    proposeFine: async (args) => {
      const userId = memberIdToUserId.get(args.member_id);
      if (!userId) {
        throw new Error(`proposeFine: member ${args.member_id} not found in group ${args.group_id}`);
      }

      // §14 Step 3c: idempotency check reads from fines_view so status
      // is derived (post column drop in mig 00151).
      const { data: existing } = await supabase
        .from("fines_view")
        .select("id")
        .eq("resource_id", args.resource_id)
        .eq("user_id", userId)
        .eq("rule_id", args.rule_id)
        .in("status", ["proposed", "officialized", "in_appeal"])
        .maybeSingle();
      if (existing) return existing.id as string;

      // INSERT to the underlying fines table. The fines.status column was
      // dropped in mig 00151 — projection derives status from atoms +
      // votes + review_periods. New fines start as 'proposed' (no atoms
      // yet, no open vote, no expired review_period).
      // §14 step 5c-ii: fines.event_id was dropped; resource_id is the
      // canonical handle for both V1 events and Phase 2 non-event
      // resources.
      const { data, error } = await supabase
        .from("fines")
        .insert({
          resource_id: args.resource_id,
          group_id: args.group_id,
          user_id: userId,
          rule_id: args.rule_id,
          amount: args.amount,
          reason: args.reason,
          details: args.evidence,
          auto_generated: true,
        })
        .select("id")
        .single();
      if (error) throw new Error(`proposeFine insert failed: ${error.message}`);
      return data.id as string;
    },

    // (mig 00193) Emits a `warningEmitted` system_event via the canonical
    // record_system_event SECURITY DEFINER. The new row's id is what the
    // `emitWarning` consequence returns as `created_resource_ids`.
    emitWarning: async (args) => {
      const { data, error } = await supabase.rpc("record_system_event", {
        p_group_id:    args.group_id,
        p_event_type:  "warningEmitted",
        p_resource_id: args.resource_id,
        p_member_id:   args.member_id,
        p_payload:     {
          rule_id:        args.rule_id,
          reason:         args.reason,
          source_atom_id: args.source_atom_id,
          ...args.payload,
        },
      });
      if (error) throw new Error(`emitWarning record_system_event failed: ${error.message}`);
      return data as string;
    },

    // (mig 00194 + Sprint 8) Opens a vote via canonical start_vote RPC.
    // Returns votes.id. Caller's vote_type must pass is_known_vote_type
    // whitelist. Optional duration/quorum/threshold pass through to the
    // RPC; null falls through to group-policy defaults.
    startVote: async (args) => {
      const { data, error } = await supabase.rpc("start_vote", {
        p_group_id:          args.group_id,
        p_vote_type:         args.vote_type,
        p_reference_id:      args.reference_id,
        p_title:             args.title,
        p_description:       args.description,
        p_payload:           {
          rule_id: args.rule_id,
          ...args.payload,
        },
        p_duration_hours:    args.duration_hours,
        p_quorum_percent:    args.quorum_percent,
        p_threshold_percent: args.threshold_percent,
      });
      if (error) throw new Error(`startVote start_vote failed: ${error.message}`);
      return data as string;
    },

    // (mig 00200) Invokes the canonical transfer_right RPC as
    // service_role. The RPC's auth gate was relaxed in mig 00200 so
    // that auth.uid()=NULL (cron) bypasses the membership check; the
    // transferable=true invariant + new-holder-is-member check still
    // run. The reason is prefixed with the rule id so the audit
    // row stays traceable to the consequence even though
    // transferred_by ends up NULL on the atom.
    transferRight: async (args) => {
      const { error } = await supabase.rpc("transfer_right", {
        p_right_id:     args.right_id,
        p_to_member_id: args.to_member_id,
        p_reason:       `rule:${args.rule_id}${args.reason ? ` — ${args.reason}` : ""}`,
      });
      if (error) throw new Error(`transferRight transfer_right failed: ${error.message}`);
      return args.right_id;
    },

    // (slice 10) Invokes the canonical revoke_right RPC. Mig 00200's
    // auth gate relaxation allows the cron path. Idempotent server-side
    // (short-circuits when status='revoked').
    revokeRight: async (args) => {
      const { error } = await supabase.rpc("revoke_right", {
        p_right_id: args.right_id,
        p_reason:   `rule:${args.rule_id}${args.reason ? ` — ${args.reason}` : ""}`,
      });
      if (error) throw new Error(`revokeRight revoke_right failed: ${error.message}`);
      return args.right_id;
    },

    // (slice 10) Invokes the canonical suspend_right RPC. Sets
    // metadata.suspended_until; status stays 'active' so a follow-up
    // restore_right (manual admin) lifts the suspension cleanly.
    suspendRight: async (args) => {
      const { error } = await supabase.rpc("suspend_right", {
        p_right_id: args.right_id,
        p_until:    args.until,
        p_reason:   `rule:${args.rule_id}${args.reason ? ` — ${args.reason}` : ""}`,
      });
      if (error) throw new Error(`suspendRight suspend_right failed: ${error.message}`);
      return args.right_id;
    },

    // (mig 00227, AssetRules.md §4.3) Insert a user_actions row of
    // type assetActionApproval for the asset's admins. Idempotent via
    // a SELECT on (rule_id, reference_id, action_type, source_atom_id)
    // — re-running the rule on the same atom doesn't pile up dupes.
    // Inserts one row per active group founder; for V1 we treat the
    // founder roles list as the approver pool. assignSlot / treasurer
    // role expansion lands in a follow-up.
    createUserAction: async (args) => {
      const sourceAtomTag = args.source_atom_id ?? "no-source";

      // Idempotency: if any user_actions row already exists for this
      // (rule_id + reference_id + action_type + source_atom_id) tuple,
      // return its id without inserting more. We tag the body with the
      // source atom id so it's queryable in a single eq().
      const { data: existing } = await supabase
        .from("user_actions")
        .select("id")
        .eq("reference_id", args.resource_id)
        .eq("action_type", args.action_type)
        .ilike("body", `%[rule:${args.rule_id}][src:${sourceAtomTag}]%`)
        .limit(1)
        .maybeSingle();
      if (existing) return existing.id as string;

      // Resolve founder user_ids for this group — they're the V1
      // approver pool. group_members.roles is a jsonb array; ?| is the
      // PostgREST operator for "contains any of".
      const { data: founders, error: foundersErr } = await supabase
        .from("group_members")
        .select("user_id")
        .eq("group_id", args.group_id)
        .eq("active", true)
        .contains("roles", ["founder"]);
      if (foundersErr) {
        throw new Error(`createUserAction founders lookup failed: ${foundersErr.message}`);
      }
      const targets = (founders ?? []).map((f) => f.user_id as string);
      if (targets.length === 0) {
        // No admins to notify — log and short-circuit. Returning a
        // synthetic id keeps ExecutionResult well-formed; the rule
        // engine doesn't observe the row, only its existence.
        console.warn(`createUserAction: group ${args.group_id} has no active founder; skipping`);
        return crypto.randomUUID();
      }

      const tag = `[rule:${args.rule_id}][src:${sourceAtomTag}]`;
      const bodyText = [args.body, tag].filter(Boolean).join(" — ");

      const rows = targets.map((uid) => ({
        user_id:      uid,
        group_id:     args.group_id,
        action_type:  args.action_type,
        reference_id: args.resource_id,
        title:        args.title,
        body:         bodyText,
        priority:     "high",
      }));

      const { data, error } = await supabase
        .from("user_actions")
        .insert(rows)
        .select("id")
        .limit(1)
        .single();
      if (error) throw new Error(`createUserAction insert failed: ${error.message}`);
      return data.id as string;
    },

    // (mig 00227, AssetRules.md §4.3) Flip resources.metadata.bookings_locked
    // = true and emit a warningEmitted audit atom. Idempotent — re-firing
    // on an already-locked asset returns the asset id without re-emitting
    // the audit atom (avoids spamming the activity feed).
    setBookingsLocked: async (args) => {
      const { data: current, error: readErr } = await supabase
        .from("resources")
        .select("metadata")
        .eq("id", args.resource_id)
        .single();
      if (readErr) throw new Error(`setBookingsLocked read failed: ${readErr.message}`);

      const meta = (current?.metadata ?? {}) as Record<string, unknown>;
      if (meta.bookings_locked === true) {
        // Already locked — no-op. Return the asset id so the rule
        // engine still completes successfully (idempotent run).
        return args.resource_id;
      }

      const nextMeta = {
        ...meta,
        bookings_locked: true,
        bookings_locked_at: new Date().toISOString(),
        bookings_locked_by_rule_id: args.rule_id,
      };
      const { error: updErr } = await supabase
        .from("resources")
        .update({ metadata: nextMeta })
        .eq("id", args.resource_id);
      if (updErr) throw new Error(`setBookingsLocked update failed: ${updErr.message}`);

      // Audit atom — visibility for admins / activity feed.
      const { error: emitErr } = await supabase.rpc("record_system_event", {
        p_group_id:    args.group_id,
        p_event_type:  "warningEmitted",
        p_resource_id: args.resource_id,
        p_member_id:   null,
        p_payload:     {
          rule_id: args.rule_id,
          reason:  args.reason ?? "bookings locked by rule",
          kind:    "lockBookings",
        },
      });
      if (emitErr) {
        console.warn(`setBookingsLocked: audit atom emit failed (lock still applied): ${emitErr.message}`);
      }
      return args.resource_id;
    },

    // (mig 00227, AssetRules.md §4.1) Latest value_cents from
    // asset_valuation_view. Returns null when the asset has no
    // recorded valuation — the transferAmountAbove condition then
    // short-circuits to false.
    latestAssetValuationCents: async (assetId) => {
      const { data, error } = await supabase
        .from("asset_valuation_view")
        .select("value_cents")
        .eq("asset_id", assetId)
        .maybeSingle();
      if (error) {
        console.warn(`latestAssetValuationCents read failed: ${error.message}`);
        return null;
      }
      if (!data) return null;
      const raw = data.value_cents;
      return typeof raw === "number" ? raw : Number(raw);
    },
  };

  return {
    now,
    members: (members ?? []).map((m) => ({ id: m.id, user_id: m.user_id, active: m.active })),
    resource,
    rsvps,
    checkIns,
    finesThisMonthByMember,
    sink,
  };
}
