// export-user-data: packages a user's data into a JSON payload (CCPA portability + LFPDPPP ARCO A).
//
// Caller authenticates with their JWT (verify_jwt=true). The function reads
// auth.uid() from the token and packages every row the user authored or
// references. Output is returned inline as JSON; the iOS client writes it to
// disk and offers the system share sheet.
//
// Request:  { request_id?: string }   // optional — if present, marks the request executed
// Response: { generated_at, user_id, profile, group_memberships[], data: { ... } }
//
// Reads via service-role (RLS bypass is intentional — user is requesting *their own* data).
//
// Restored to repo 2026-05-18 — this function had been deployed (v1, since
// 2026-05-10) but never lived in version control. Discovered while
// executing Plans/Active/CleanupAudit_2026-05-18; see
// 11_post_execution_corrections.md §5. Companion to the user-rights
// workflow tracked in `data_subject_rights_requests` table (mig 00253)
// and referenced from RuulCore/Repositories/ProfileRepository.swift.
//
// Known drift caveat (2026-05-18): the membership SELECT reads
// `group_members.role` (text column dropped in mig 00303 in favor of
// `group_members.roles` jsonb). Returns null for that field on every row.
// Fix planned: replace `role` with `roles` in the membership projection.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return jsonError(401, "missing_authorization");
  }

  const caller = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authError } = await caller.auth.getUser();
  if (authError || !user) {
    return jsonError(401, "invalid_token");
  }
  const userId = user.id;

  let requestId: string | null = null;
  try {
    const body = await req.json().catch(() => ({}));
    if (body && typeof body.request_id === "string") {
      requestId = body.request_id;
    }
  } catch {
    // body optional — ignore
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  if (requestId) {
    await admin.from("data_subject_rights_requests")
      .update({ status: "executing" })
      .eq("id", requestId)
      .eq("user_id", userId);
  }

  try {
    const exportPayload = await buildExport(admin, userId);

    if (requestId) {
      await admin.from("data_subject_rights_requests")
        .update({
          status: "completed",
          executed_at: new Date().toISOString(),
          result: {
            byte_size: JSON.stringify(exportPayload).length,
            tables_included: Object.keys(exportPayload.data),
          },
        })
        .eq("id", requestId)
        .eq("user_id", userId);
    }

    return jsonResponse(exportPayload);
  } catch (err) {
    console.error("export-user-data failed", err);
    if (requestId) {
      await admin.from("data_subject_rights_requests")
        .update({
          status: "failed",
          executed_at: new Date().toISOString(),
          error_message: String(err),
        })
        .eq("id", requestId)
        .eq("user_id", userId);
    }
    return jsonError(500, "export_failed");
  }
});

async function buildExport(
  admin: ReturnType<typeof createClient>,
  userId: string,
) {
  const [profileRes, membershipsRes, finesRes, userActionsRes, deletionLogRes, rightsRes] = await Promise.all([
    admin.from("profiles").select("*").eq("id", userId).maybeSingle(),
    admin.from("group_members").select("id, group_id, role, on_committee, turn_order, active, joined_at, display_name_override").eq("user_id", userId),
    admin.from("fines").select("*").eq("user_id", userId),
    admin.from("user_actions").select("*").eq("user_id", userId),
    admin.from("data_deletion_log").select("*").eq("user_id", userId),
    admin.from("data_subject_rights_requests").select("id, kind, status, requested_at, executed_at, result").eq("user_id", userId),
  ]);

  const memberIds: string[] = (membershipsRes.data ?? []).map((m: { id: string }) => m.id);

  const [rsvpRes, voteCastsRes, checkInsRes, systemEventsRes, ledgerOutRes, ledgerInRes, notificationsRes] = await Promise.all([
    memberIds.length
      ? admin.from("rsvp_actions").select("*").in("member_id", memberIds)
      : Promise.resolve({ data: [] as unknown[], error: null }),
    memberIds.length
      ? admin.from("vote_casts").select("*").in("member_id", memberIds)
      : Promise.resolve({ data: [] as unknown[], error: null }),
    memberIds.length
      ? admin.from("check_in_actions").select("*").in("member_id", memberIds)
      : Promise.resolve({ data: [] as unknown[], error: null }),
    memberIds.length
      ? admin.from("system_events").select("id, group_id, event_type, resource_id, member_id, payload, created_at").in("member_id", memberIds)
      : Promise.resolve({ data: [] as unknown[], error: null }),
    memberIds.length
      ? admin.from("ledger_entries").select("*").in("from_member_id", memberIds)
      : Promise.resolve({ data: [] as unknown[], error: null }),
    memberIds.length
      ? admin.from("ledger_entries").select("*").in("to_member_id", memberIds)
      : Promise.resolve({ data: [] as unknown[], error: null }),
    memberIds.length
      ? admin.from("notifications_outbox").select("id, event_type, payload, dispatch_status, scheduled_for, created_at").in("recipient_member_id", memberIds)
      : Promise.resolve({ data: [] as unknown[], error: null }),
  ]);

  return {
    generated_at: new Date().toISOString(),
    schema_version: 1,
    user_id: userId,
    profile: profileRes.data,
    group_memberships: membershipsRes.data ?? [],
    data: {
      fines: finesRes.data ?? [],
      user_actions: userActionsRes.data ?? [],
      rsvp_actions: rsvpRes.data ?? [],
      vote_casts: voteCastsRes.data ?? [],
      check_in_actions: checkInsRes.data ?? [],
      system_events: systemEventsRes.data ?? [],
      ledger_entries_paid: ledgerOutRes.data ?? [],
      ledger_entries_received: ledgerInRes.data ?? [],
      notifications: notificationsRes.data ?? [],
      data_subject_rights_requests: rightsRes.data ?? [],
      data_deletion_log: deletionLogRes.data ?? [],
    },
  };
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function jsonError(status: number, message: string) {
  return jsonResponse({ error: message }, status);
}
