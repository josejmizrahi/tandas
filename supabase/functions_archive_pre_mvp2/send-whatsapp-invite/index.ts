// send-whatsapp-invite: sends a WhatsApp message with the group invite link
// to a phone number. Used by both:
//   - founder onboarding step 5 ("Agregar por número")
//   - create-placeholder-member edge fn (placeholder claim flow)
//
// Authorization: caller must be authenticated AND admin of the group.
// Either path (user JWT or service-role internal fetch) is supported.
//
// Request: {
//   invite_id: uuid,
//   phone: "+5215555551234",
//   group_name: string,
//   invite_code: string,
//   message?: string,           // optional override; bypasses the composer
//   claim_token?: string        // optional; if present, uses placeholder
//                               // copy + /claim/<token> URL
// }
//
// Response: { sent: true } | { sent: false, reason }
//
// Falls back to no-op if Wassenger isn't configured (no env keys set).
// In that case the iOS client should fall back to a ShareLink action.
//
// Copy: WhatsApp supports *bold*, _italic_, ~strike~, ```mono```. Use
// sparingly — visual weight is the goal, not decoration.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { corsHeaders } from "../_shared/cors.ts";
import { withSentry } from "../_shared/sentry.ts";

const WASSENGER_API_KEY = Deno.env.get("WASSENGER_API_KEY") ?? "";
const WASSENGER_DEVICE_ID = Deno.env.get("WASSENGER_DEVICE_ID") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(withSentry(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return jsonError(401, "missing auth");

  // Bind a Supabase client to the caller's JWT — RLS enforces access via
  // invites_select_members. Service-role callers (internal fetch from
  // create-placeholder-member) bypass RLS automatically.
  const supabase = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
  });

  let invite_id: string, phone: string, group_name: string, invite_code: string;
  let message: string | undefined;
  let claim_token: string | undefined;
  try {
    const body = await req.json();
    invite_id = body.invite_id;
    phone = body.phone;
    group_name = body.group_name;
    invite_code = body.invite_code;
    message = body.message;
    claim_token = body.claim_token;
    if (!invite_id || !phone || !group_name || !invite_code) {
      return jsonError(400, "invite_id, phone, group_name, invite_code required");
    }
  } catch {
    return jsonError(400, "invalid JSON body");
  }

  // Verify the caller can see this invite, and grab the inviter +
  // (optional) placeholder pointer so the composer can personalize.
  const { data: invite, error: selErr } = await supabase
    .from("invites")
    .select("id, group_id, used_at, invited_by, placeholder_user_id")
    .eq("id", invite_id)
    .single();
  if (selErr || !invite) return jsonError(404, "invite not found or no access");

  // Profile lookups for personalization. Use a service-role client so a
  // weak RLS read for either profile doesn't degrade the message — the
  // edge fn already authorized via the invite SELECT above.
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const [inviterName, placeholderName] = await Promise.all([
    fetchDisplayName(admin, invite.invited_by as string),
    invite.placeholder_user_id
      ? fetchDisplayName(admin, invite.placeholder_user_id as string)
      : Promise.resolve(null),
  ]);

  const finalMessage = message ?? composeMessage({
    inviterName,
    groupName: group_name,
    claimToken: claim_token,
    placeholderName,
    inviteCode: invite_code,
  });

  if (!WASSENGER_API_KEY || !WASSENGER_DEVICE_ID) {
    return jsonResponse({ sent: false, reason: "wassenger not configured" });
  }

  try {
    const res = await fetch("https://api.wassenger.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Token: WASSENGER_API_KEY,
      },
      body: JSON.stringify({
        device: WASSENGER_DEVICE_ID,
        phone,
        message: finalMessage,
      }),
    });
    if (!res.ok) {
      const text = await res.text();
      console.warn("wassenger non-2xx", res.status, text);
      return jsonResponse({ sent: false, reason: `wassenger ${res.status}` });
    }
  } catch (err) {
    console.warn("wassenger send threw", err);
    return jsonResponse({ sent: false, reason: "network" });
  }

  return jsonResponse({ sent: true });
}, { functionName: "send-whatsapp-invite" }));

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

// deno-lint-ignore no-explicit-any
async function fetchDisplayName(admin: any, userId: string): Promise<string | null> {
  if (!userId) return null;
  const { data, error } = await admin
    .from("profiles")
    .select("display_name")
    .eq("id", userId)
    .maybeSingle();
  if (error || !data) return null;
  const name = String((data as { display_name?: string }).display_name ?? "").trim();
  return name.length > 0 ? name : null;
}

interface ComposeArgs {
  inviterName: string | null;
  groupName: string;
  claimToken?: string;
  placeholderName: string | null;
  inviteCode: string;
}

function composeMessage(a: ComposeArgs): string {
  // Inviter line — falls back gracefully when the lookup returned null.
  const inviterPrefix = a.inviterName ? `*${a.inviterName}*` : "Te";
  const inviterAction = a.inviterName ? "te" : "han";

  if (a.claimToken) {
    // Placeholder claim path: someone with admin privileges added this
    // phone as a stand-in member before the recipient signed up. They
    // already participate in rotations, RSVPs, fines, votes.
    const asLine = a.placeholderName ? ` como _${a.placeholderName}_` : "";
    return [
      `Hola 👋`,
      ``,
      `${inviterPrefix} ${inviterAction} agregó al grupo *${a.groupName}* en Ruul${asLine}.`,
      ``,
      `Tu lugar ya quedó reservado: cuentas desde hoy para turnos, RSVPs, gastos compartidos y reglas del grupo.`,
      ``,
      `Activa tu cuenta tocando este enlace:`,
      `https://ruul.mx/claim/${a.claimToken}`,
      ``,
      `_Si no esperabas esta invitación, ignora este mensaje._`,
    ].join("\n");
  }

  // Regular invite path — just the group invite code, recipient signs up
  // and joins through JoinGroupSheet.
  return [
    `Hola 👋`,
    ``,
    `${inviterPrefix} ${inviterAction} invita al grupo *${a.groupName}* en Ruul, la app para coordinar grupos: turnos, RSVPs, gastos compartidos y reglas, todo en un solo lugar.`,
    ``,
    `Únete tocando este enlace:`,
    `https://ruul.mx/invite/${a.inviteCode}`,
    ``,
    `_Si no tienes la app instalada, el enlace te lleva al App Store._`,
  ].join("\n");
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
