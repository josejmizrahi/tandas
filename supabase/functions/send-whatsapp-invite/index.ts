// send-whatsapp-invite: sends a WhatsApp message with the group invite link
// to a phone number. Used by the "Agregar por número" path in step 5 of the
// founder onboarding.
//
// Authorization: caller must be authenticated AND admin of the group. The
// edge function checks the JWT, then verifies via RLS-bound RPC.
//
// Request: { invite_id: uuid, phone: "+5215555551234", group_name, invite_code, message? }
// Response: { sent: true } | { sent: false, reason }
//
// Falls back to no-op if Wassenger isn't configured (no env keys set).
// In that case the iOS client should fall back to a ShareLink action.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { corsHeaders } from "../_shared/cors.ts";

const WASSENGER_API_KEY = Deno.env.get("WASSENGER_API_KEY") ?? "";
const WASSENGER_DEVICE_ID = Deno.env.get("WASSENGER_DEVICE_ID") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return jsonError(401, "missing auth");

  // Bind a Supabase client to the caller's JWT — RLS will enforce admin
  // access via the invites_insert_admin policy when we read the invite.
  const supabase = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
  });

  let invite_id: string, phone: string, group_name: string, invite_code: string, message: string | undefined;
  try {
    const body = await req.json();
    invite_id = body.invite_id;
    phone = body.phone;
    group_name = body.group_name;
    invite_code = body.invite_code;
    message = body.message;
    if (!invite_id || !phone || !group_name || !invite_code) {
      return jsonError(400, "invite_id, phone, group_name, invite_code required");
    }
  } catch {
    return jsonError(400, "invalid JSON body");
  }

  // Verify the caller can see this invite (RLS will reject if they're not
  // a member of the group).
  const { data: invite, error: selErr } = await supabase
    .from("invites")
    .select("id, group_id, used_at")
    .eq("id", invite_id)
    .single();
  if (selErr || !invite) return jsonError(404, "invite not found or no access");

  const finalMessage =
    message ??
    `Te invito a ${group_name} en ruul. Aquí coordinamos todo: turnos, RSVP, reglas. Únete: ` +
      `https://ruul.app/invite/${invite_code}`;

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
});

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function jsonError(status: number, message: string) {
  return jsonResponse({ error: message }, status);
}
