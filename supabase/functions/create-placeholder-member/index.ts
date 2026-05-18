// create-placeholder-member: admin creates a stand-in member that already
// counts for rotation/RSVP/fines/votes before the real person registers.
//
// Request:  { group_id: uuid, display_name: string, phone_e164: string }
//
// Responses:
//   200 { kind: "created", member_id, invite_id, placeholder_user_id }
//        WhatsApp magic link sent best-effort (not awaited).
//   409 { kind: "existing_user", user_id, display_name? }
//        Phone already belongs to a real user — client should offer
//        a regular add-existing-member flow instead.
//   409 { kind: "duplicate_placeholder", user_id }
//        Another unclaimed placeholder already owns this phone.
//   403 forbidden          — caller lacks members.invite on the group
//   401 missing/invalid auth
//   400 validation error
//   500 unexpected
//
// SECURITY: service-role admin API calls happen only inside this fn;
// auth context for permission check uses the caller's JWT.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { corsHeaders } from "../_shared/cors.ts";
import { withSentry } from "../_shared/sentry.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

serve(withSentry(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "missing auth" }, 401);

  // User-bound client → who is the caller + RLS-safe permission check.
  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) return json({ error: "invalid auth" }, 401);
  const callerId = userData.user.id;

  let group_id: string, display_name: string, phone_e164: string;
  try {
    const body = await req.json();
    group_id = body.group_id;
    display_name = (body.display_name ?? "").trim();
    phone_e164 = (body.phone_e164 ?? "").trim();
    if (!group_id || !display_name || !phone_e164) {
      return json({ error: "group_id, display_name, phone_e164 required" }, 400);
    }
    if (!/^\+\d{8,15}$/.test(phone_e164)) {
      return json({ error: "phone_e164 must be E.164 (e.g. +5215555551234)" }, 400);
    }
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }

  // Permission check.
  const { data: canInvite, error: permErr } = await userClient.rpc("has_permission", {
    p_group_id: group_id,
    p_user_id: callerId,
    // 'modifyMembers' is the canonical slug in groups.roles jsonb; granted
    // to admin + founder by default. Earlier drafts used 'members.invite'
    // which doesn't exist in the catalog — see mig 00323.
    p_permission: "modifyMembers",
  });
  if (permErr) {
    return json({ error: `permission check failed: ${permErr.message}` }, 500);
  }
  if (!canInvite) return json({ error: "forbidden" }, 403);

  // Service-role client for admin API + bypass-RLS lookups.
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // 1. Real-user phone lookup. We page through auth.admin.listUsers because
  // the SDK doesn't expose a direct phone filter that's universally
  // supported. For larger tenants this should be replaced with a service-
  // role query against auth.users by phone, but for now the page-based
  // scan is fine (early product, low user count).
  //
  // Actually: we have a simpler bypass via service role select on
  // auth.users directly via PostgREST? No — auth.users is not exposed.
  // Use a SECURITY DEFINER helper RPC? Out of scope. For now, query
  // profiles.phone (the dual-write target of mig 00185_sync_auth_phone_to_profile).
  const { data: realByProfilePhone, error: rppErr } = await admin
    .from("profiles")
    .select("id, display_name, is_placeholder, claimed_at")
    .eq("phone", phone_e164)
    .limit(2);
  if (rppErr) return json({ error: `phone lookup failed: ${rppErr.message}` }, 500);

  const realUser = (realByProfilePhone ?? []).find(
    (p) => p.is_placeholder === false || p.claimed_at !== null,
  );
  if (realUser) {
    return json({
      kind: "existing_user",
      user_id: realUser.id,
      display_name: realUser.display_name ?? null,
    }, 409);
  }

  const dupPlaceholder = (realByProfilePhone ?? []).find(
    (p) => p.is_placeholder === true && p.claimed_at === null,
  );
  if (dupPlaceholder) {
    return json({ kind: "duplicate_placeholder", user_id: dupPlaceholder.id }, 409);
  }

  // 2. Create the anonymous placeholder auth.users row.
  //
  // Supabase auth.admin.createUser requires either an email or a phone.
  // Phone would collide with the real owner when they later sign up via
  // OTP, so we mint a synthetic email under our reserved sub-domain
  // `placeholders.ruul.mx`. No MX records → no inbound email → the
  // address is unreachable on purpose. email_confirm: true marks the row
  // as confirmed so Supabase doesn't try to send a verification mail
  // (which would silently bounce).
  const placeholderEmail =
    `placeholder-${crypto.randomUUID()}@placeholders.ruul.mx`;

  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email: placeholderEmail,
    email_confirm: true,
    user_metadata: {
      placeholder: true,
      display_name,
      created_by: callerId,
    },
  });
  if (createErr || !created?.user) {
    return json({ error: `createUser failed: ${createErr?.message ?? "unknown"}` }, 500);
  }
  const placeholderUid = created.user.id;

  // 3. Some envs have an on_auth_user_created trigger that auto-inserts a
  //    profiles row from auth.users defaults. The atomic finalize RPC
  //    expects a clean slate (so it can set is_placeholder + phone). Wipe
  //    the auto-row if present; idempotent if it doesn't exist.
  await admin.from("profiles").delete().eq("id", placeholderUid);

  // 4. Atomic finalize.
  const { data: finalize, error: rpcErr } = await admin.rpc("finalize_placeholder_member", {
    p_placeholder_user_id: placeholderUid,
    p_group_id: group_id,
    p_display_name: display_name,
    p_phone_e164: phone_e164,
    p_actor_user_id: callerId,
  });
  if (rpcErr) {
    // Rollback orphan auth user.
    await admin.auth.admin.deleteUser(placeholderUid).catch(() => {});
    return json({ error: `finalize failed: ${rpcErr.message}` }, 500);
  }

  const claimToken: string = (finalize as { claim_token: string }).claim_token;
  const inviteId: string = (finalize as { invite_id: string }).invite_id;
  const memberId: string = (finalize as { member_id: string }).member_id;

  // 4. Fire WhatsApp best-effort (don't await for success).
  const { data: groupRow } = await admin.from("groups")
    .select("name, invite_code").eq("id", group_id).single();
  if (groupRow) {
    fetch(`${SUPABASE_URL}/functions/v1/send-whatsapp-invite`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        invite_id: inviteId,
        phone: phone_e164,
        group_name: (groupRow as { name: string }).name,
        invite_code: (groupRow as { invite_code: string }).invite_code,
        claim_token: claimToken,
      }),
    }).catch((err) => console.warn("whatsapp fire-and-forget failed:", err));
  }

  return json({
    kind: "created",
    member_id: memberId,
    invite_id: inviteId,
    placeholder_user_id: placeholderUid,
  });
}, { functionName: "create-placeholder-member" }));

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
