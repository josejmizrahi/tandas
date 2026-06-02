// send-event-notification: write event-lifecycle push intentions to the
// outbox.
//
// **V3 (Sprint D / mig RolesRemediation 2026-05-17).** Closes V5 HERESY
// from the RolesAudit: previous version accepted ANY HTTP request
// (service_role context) with arbitrary {event_id, kind, target_user_ids}
// and silently spammed pushes to the group. This version requires the
// caller's JWT, verifies membership in event.group_id, and gates each
// kind on the appropriate permission.
//
// **V2 (outbox-first)**. Composes target list + payload + deep_link for
// an event lifecycle kind (created / host_reminder / deadline_warning /
// cancelled), then inserts one row per recipient into
// `notifications_outbox` with `dispatch_status='pending'`.
//
// **Does NOT dispatch**. APNs delivery is the responsibility of the
// `dispatch-notifications` cron (separate function) which reads pending
// outbox rows and sends. Until that cron + APNs creds are wired, rows
// pile up as 'pending' and are observable via SQL.
//
// Why outbox-first:
//   - Coherente con principio "toda intención de notificar produce un
//     row" (espejo del SystemEvent log para mutaciones).
//   - Idempotency for free: parcial failures retryable.
//   - Debug en prod = SQL query, no logs.
//   - Consistente con start_vote, finalize_vote, finalize-fine-reviews
//     que ya escriben directo al outbox.
//
// Authorization (Sprint D, 2026-05-17):
//   - Authorization Bearer <JWT> required (401 otherwise).
//   - Caller must be active member of event.group_id (403).
//   - cancelled: requires has_permission(manageEvents) OR caller is
//     event creator OR host (403 otherwise).
//   - created / host_reminder / deadline_warning: any active member.
//     These kinds correspond to legitimate flows where any participant
//     might want to nudge the group (e.g. iOS coordinator re-trigger).
//
// Request: { event_id, kind, target_user_ids? }
//   kind ∈ "created" | "host_reminder" | "deadline_warning" | "cancelled"
//   target_user_ids: optional override; defaults derived from kind.
// Response: { outbox_count, outbox_ids, kind }

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { withSentry } from "../_shared/sentry.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

type Kind = "created" | "host_reminder" | "deadline_warning" | "cancelled";

interface OutboxRowId { id: string }

interface JWTPayload {
  sub?: string;
  // other fields ignored
}

serve(withSentry(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: { "Access-Control-Allow-Origin": "*" } });
  }

  // Sprint D — V5 HERESY fix: require caller JWT.
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return jsonError(401, "Authorization Bearer JWT required");
  }
  const callerInfo = decodeJWT(authHeader.slice(7));
  if (!callerInfo?.sub) {
    return jsonError(401, "could not decode JWT");
  }
  const callerUserId = callerInfo.sub;

  let event_id: string, kind: Kind, target_user_ids: string[] | undefined;
  try {
    const body = await req.json();
    event_id = body.event_id;
    kind = body.kind;
    target_user_ids = body.target_user_ids;
    if (!event_id || !kind) {
      return jsonError(400, "event_id and kind required");
    }
  } catch {
    return jsonError(400, "invalid JSON body");
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // §14 step 5c-iii.A: reads from events_view (resources projection).
  const { data: event, error: eventErr } = await supabase
    .from("events_view")
    .select("*, groups(name, event_label)")
    .eq("id", event_id)
    .single();
  if (eventErr || !event) return jsonError(404, "event not found");

  // Sprint D — V5 HERESY fix: caller must be active member of the event's group.
  const groupId = event.group_id as string;
  const { data: callerRow, error: callerErr } = await supabase
    .from("group_members")
    .select("id")
    .eq("group_id", groupId)
    .eq("user_id", callerUserId)
    .eq("active", true)
    .maybeSingle();
  if (callerErr) return jsonError(500, `caller membership lookup failed: ${callerErr.message}`);
  if (!callerRow) return jsonError(403, "caller is not an active member of this group");

  // Sprint D — V5 HERESY fix: cancelled requires manageEvents permission
  // (or caller is the event creator / host). The other kinds are
  // legitimate any-member nudges so we don't gate them further.
  if (kind === "cancelled") {
    const callerIsCreator = (event.created_by as string | null) === callerUserId;
    const callerIsHost = (event.host_id as string | null) === callerUserId;
    if (!callerIsCreator && !callerIsHost) {
      const { data: permData, error: permErr } = await supabase.rpc("has_permission", {
        p_group_id: groupId,
        p_user_id: callerUserId,
        p_permission: "manageEvents",
      });
      if (permErr) return jsonError(500, `permission lookup failed: ${permErr.message}`);
      if (permData !== true) {
        return jsonError(403, "cancelled requires manageEvents permission or creator/host");
      }
    }
  }

  // Resolve targets (user_ids) per kind.
  let targetUserIds: string[] = target_user_ids ?? [];
  if (targetUserIds.length === 0) {
    targetUserIds = await resolveTargets(supabase, event, kind);
  }

  if (targetUserIds.length === 0) {
    return ok({ outbox_count: 0, outbox_ids: [], kind });
  }

  // Outbox keys recipients by group_members.id, not user_id, so recipient
  // identity survives if the auth user is later deleted.
  const { data: members, error: memberErr } = await supabase
    .from("group_members")
    .select("id, user_id")
    .eq("group_id", groupId)
    .in("user_id", targetUserIds);

  if (memberErr) return jsonError(500, `member lookup failed: ${memberErr.message}`);

  const memberIds = (members ?? []).map((m: { id: string }) => m.id);
  if (memberIds.length === 0) {
    return ok({ outbox_count: 0, outbox_ids: [], kind });
  }

  const payload = buildPayload(event, kind);
  const deepLink = `ruul://event/${event_id}`;

  // One outbox row per recipient. The dispatcher cron picks up
  // dispatch_status='pending', looks up notification_tokens, sends APNs,
  // and marks status sent / failed / skipped.
  const rows = memberIds.map((member_id) => ({
    group_id: groupId,
    recipient_member_id: member_id,
    notification_type: kind,
    payload,
    deep_link: deepLink,
  }));

  const { data: inserted, error: insertErr } = await supabase
    .from("notifications_outbox")
    .insert(rows)
    .select("id");

  if (insertErr) return jsonError(500, `outbox insert failed: ${insertErr.message}`);

  const outboxIds = ((inserted as OutboxRowId[] | null) ?? []).map((r) => r.id);

  return ok({
    outbox_count: outboxIds.length,
    outbox_ids: outboxIds,
    kind,
  });
}, { functionName: "send-event-notification" }));

async function resolveTargets(
  supabase: ReturnType<typeof createClient>,
  event: Record<string, unknown>,
  kind: Kind,
): Promise<string[]> {
  const groupId = event.group_id as string;

  switch (kind) {
    case "created":
    case "cancelled": {
      // All active members except the creator.
      const { data } = await supabase
        .from("group_members")
        .select("user_id")
        .eq("group_id", groupId)
        .eq("active", true);
      return ((data ?? []) as Array<{ user_id: string }>)
        .map((r) => r.user_id)
        .filter((id) => id !== event.created_by);
    }
    case "host_reminder":
    case "deadline_warning": {
      // Pending RSVPs for this event.
      // §14 step 5c-iii.A: reads from attendance_view (atoms projection).
      const eventId = event.id as string;
      const { data } = await supabase
        .from("attendance_view")
        .select("user_id")
        .eq("event_id", eventId)
        .eq("rsvp_status", "pending");
      return ((data ?? []) as Array<{ user_id: string }>).map((r) => r.user_id);
    }
  }
}

function buildPayload(event: Record<string, unknown>, kind: Kind): Record<string, unknown> {
  const groupName = (event.groups as { name?: string })?.name ?? "tu grupo";
  const vocab = (event.groups as { event_label?: string })?.event_label ?? "evento";
  const title = event.title ?? capitalize(vocab);

  switch (kind) {
    case "created":
      return { title: `Nuevo ${vocab}`, body: `${groupName}: "${title}"` };
    case "host_reminder":
      return { title: "¿Confirmas?", body: `Falta tu RSVP para "${title}"` };
    case "deadline_warning":
      return {
        title: "Te queda 1h para confirmar",
        body: `"${title}" empieza pronto. Confirma o cancela.`,
      };
    case "cancelled":
      return { title: "Evento cancelado", body: `"${title}" en ${groupName} fue cancelado.` };
  }
}

function capitalize(s: string): string {
  return s.length === 0 ? s : s.charAt(0).toUpperCase() + s.slice(1);
}

function decodeJWT(token: string): JWTPayload | null {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const payload = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = payload + "=".repeat((4 - (payload.length % 4)) % 4);
    return JSON.parse(atob(padded));
  } catch {
    return null;
  }
}

function ok(body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

function jsonError(status: number, message: string) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
