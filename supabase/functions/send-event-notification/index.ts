// send-event-notification: dispatch APNs push notifications for event lifecycle.
//
// V1 STUB — APNs cert is not configured per Plans/EventLayerV1.md §1.2.
// This function logs the intended push but does NOT send anything to APNs.
// When you wire APNs:
//   1. Get APNs Auth Key (.p8) from Apple Developer.
//   2. Configure in Supabase Dashboard → Settings → Auth → APNs.
//   3. Replace the `sendAPNs` stub below with a real fetch to APNs HTTP/2.
//
// Request: { event_id, kind, target_user_ids? }
//   kind ∈ "created" | "host_reminder" | "deadline_warning" | "cancelled"
//   target_user_ids: optional override; defaults derived from kind.
// Response: { sent: number, kind, stubbed: true }

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

type Kind = "created" | "host_reminder" | "deadline_warning" | "cancelled";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: { "Access-Control-Allow-Origin": "*" } });
  }

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

  const { data: event, error: eventErr } = await supabase
    .from("events")
    .select("*, groups(name, event_label)")
    .eq("id", event_id)
    .single();
  if (eventErr || !event) return jsonError(404, "event not found");

  // Resolve targets per kind.
  let targets: string[] = target_user_ids ?? [];
  if (targets.length === 0) {
    targets = await resolveTargets(supabase, event, kind);
  }

  // Look up tokens for those users.
  const { data: tokens } = await supabase
    .from("notification_tokens")
    .select("token, platform")
    .in("user_id", targets);

  const payload = buildPayload(event, kind);

  // STUB: log only. Replace with real APNs sender below.
  console.log(`[STUB] would send ${tokens?.length ?? 0} push(es)`, {
    event_id,
    kind,
    targets: targets.length,
    payload,
  });

  // for (const t of tokens ?? []) await sendAPNs(t.token, payload);

  return new Response(JSON.stringify({
    sent: tokens?.length ?? 0,
    kind,
    stubbed: true,
  }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});

async function resolveTargets(
  supabase: ReturnType<typeof createClient>,
  event: Record<string, unknown>,
  kind: Kind,
): Promise<string[]> {
  const groupId = event.group_id as string;
  const hostId = event.host_id as string | null;

  switch (kind) {
    case "created":
    case "cancelled": {
      // All active members except creator.
      const { data } = await supabase
        .from("group_members")
        .select("user_id")
        .eq("group_id", groupId)
        .eq("active", true);
      return (data ?? [])
        .map((r: { user_id: string }) => r.user_id)
        .filter((id) => id !== event.created_by);
    }
    case "host_reminder": {
      // Members who haven't RSVP'd yet ('pending').
      const { data } = await supabase
        .from("event_attendance")
        .select("user_id")
        .eq("event_id", event.id)
        .eq("rsvp_status", "pending");
      return (data ?? []).map((r: { user_id: string }) => r.user_id);
    }
    case "deadline_warning": {
      // Same as host_reminder — pending RSVPs near deadline.
      const { data } = await supabase
        .from("event_attendance")
        .select("user_id")
        .eq("event_id", event.id)
        .eq("rsvp_status", "pending");
      return (data ?? []).map((r: { user_id: string }) => r.user_id);
    }
  }
}

function buildPayload(event: Record<string, unknown>, kind: Kind): Record<string, unknown> {
  const groupName = (event.groups as { name?: string })?.name ?? "tu grupo";
  const vocab = (event.groups as { event_label?: string })?.event_label ?? "evento";
  const title = event.title ?? capitalize(vocab);

  switch (kind) {
    case "created":
      return {
        title: `Nuevo ${vocab}`,
        body: `${groupName}: "${title}"`,
        deep_link: `ruul://event/${event.id}`,
      };
    case "host_reminder":
      return {
        title: "¿Confirmas?",
        body: `Falta tu RSVP para "${title}"`,
        deep_link: `ruul://event/${event.id}`,
      };
    case "deadline_warning":
      return {
        title: "Te queda 1h para confirmar",
        body: `"${title}" empieza pronto. Confirma o cancela.`,
        deep_link: `ruul://event/${event.id}`,
      };
    case "cancelled":
      return {
        title: "Evento cancelado",
        body: `"${title}" en ${groupName} fue cancelado.`,
        deep_link: `ruul://event/${event.id}`,
      };
  }
}

function capitalize(s: string): string {
  return s.length === 0 ? s : s.charAt(0).toUpperCase() + s.slice(1);
}

function jsonError(status: number, message: string) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
