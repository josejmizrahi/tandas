// verify-otp: validate a WhatsApp OTP code and PROMOTE the calling user
// from anonymous to phone-authenticated, keeping the same auth.users.id.
//
// Why this matters: ruul's founder onboarding creates the group at step 2
// (before phone verification) using the anon user's id. If OTP minted a new
// user instead of promoting, every founder would lose access to their group
// the moment they confirmed their phone (created_by points to the orphaned
// anon id, RLS denies the now-different phone-user). See
// Plans/AnonAuthUpgradeGap.md for the full background.
//
// Scope:
//   • This function ONLY handles the WhatsApp branch (we own the code via
//     Wassenger + otp_codes table). The SMS branch is handled fully on the
//     iOS client via the canonical Supabase flow:
//     `auth.updateUser({phone}) → auth.verifyOtp({type: 'phone_change'})`.
//     That flow already does anon → phone promotion natively.
//   • Caller must send their JWT in the Authorization header. We read the
//     user id from the token to know who to promote.
//
// Request:  { phone, code }   // channel implied by route (this is whatsapp)
// Response: 200 { ok: true, user_id }   — caller should call
//           supabase.auth.refreshSession() afterward to pick up the new
//           is_anonymous: false claim in the JWT.
//           4xx { error, code }
//
// Error codes (in response.code):
//   missing_auth        — no Authorization header
//   invalid_token       — JWT didn't decode
//   no_pending_code     — no otp_codes row for this phone (or expired)
//   too_many_attempts   — attempts >= 5
//   invalid_code        — hash mismatch (attempts incremented)
//   phone_already_used  — phone is claimed by a different user; caller's
//                         anon group will be lost. Client should sign out
//                         + sign in as the existing phone user.
//   promote_failed      — admin.updateUserById errored unexpectedly

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { corsHeaders } from "../_shared/cors.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const MAX_ATTEMPTS = 5;

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // 1. Read the caller's JWT from Authorization. We need their user id to
  //    decide who to promote.
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return jsonError(401, "missing_auth", "Authorization Bearer JWT required");
  }
  const callerToken = authHeader.slice(7);
  const callerInfo = decodeJWT(callerToken);
  if (!callerInfo?.sub) {
    return jsonError(401, "invalid_token", "could not decode JWT");
  }
  const callerUserId = callerInfo.sub;
  const callerIsAnonymous = callerInfo.is_anonymous === true;

  // 2. Parse body.
  let phone: string, code: string;
  try {
    const body = await req.json();
    phone = body.phone;
    code = body.code;
    if (!phone || !code) {
      return jsonError(400, "bad_request", "phone, code required");
    }
  } catch {
    return jsonError(400, "bad_request", "invalid JSON body");
  }

  return await verifyAndPromote({
    callerUserId,
    callerIsAnonymous,
    phone,
    code,
  });
});

async function verifyAndPromote(params: {
  callerUserId: string;
  callerIsAnonymous: boolean;
  phone: string;
  code: string;
}): Promise<Response> {
  const { callerUserId, callerIsAnonymous, phone, code } = params;
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // 3. Find latest pending OTP for this phone.
  const { data: rows, error: selErr } = await admin
    .from("otp_codes")
    .select("*")
    .eq("phone_e164", phone)
    .eq("channel", "whatsapp")
    .is("consumed_at", null)
    .gt("expires_at", new Date().toISOString())
    .order("created_at", { ascending: false })
    .limit(1);

  if (selErr) {
    console.error("otp_codes select failed", selErr);
    return jsonError(500, "lookup_failed", "lookup failed");
  }
  const row = rows?.[0];
  if (!row) return jsonError(401, "no_pending_code", "no pending code or expired");
  if (row.attempts >= MAX_ATTEMPTS) {
    return jsonError(429, "too_many_attempts", "too many attempts");
  }

  // 4. Validate hash.
  const expectedHash = await sha256(`${code}:${phone}`);
  if (expectedHash !== row.code_hash) {
    await admin
      .from("otp_codes")
      .update({ attempts: row.attempts + 1 })
      .eq("id", row.id);
    return jsonError(401, "invalid_code", "invalid code");
  }

  // 5. Mark consumed BEFORE promoting so a duplicate request can't double-
  //    promote. (Promote is idempotent for the SAME caller, but we want
  //    one successful verify per OTP request.)
  await admin
    .from("otp_codes")
    .update({ consumed_at: new Date().toISOString() })
    .eq("id", row.id);

  // 6. Promote anon caller → phone-authenticated user (SAME UID).
  //    If caller is already phone-authenticated and verifying, no-op.
  //    Phone format for Supabase: digits only, no leading "+".
  const phoneDigits = phone.replace(/^\+/, "");

  if (!callerIsAnonymous) {
    // Caller already has a real auth (phone or email). This shouldn't
    // happen in the normal onboarding flow — defensive no-op.
    return jsonResponse({ ok: true, user_id: callerUserId, promoted: false });
  }

  const { error: updateErr } = await admin.auth.admin.updateUserById(
    callerUserId,
    { phone: phoneDigits, phone_confirm: true },
  );

  if (updateErr) {
    const msg = updateErr.message ?? "";
    // Supabase returns "Phone already registered" or similar when another
    // user has the phone. Detection is fuzzy — match on the substring.
    if (/phone.*registered|already.*used|already.*exists/i.test(msg)) {
      return jsonError(
        409,
        "phone_already_used",
        "this phone is already linked to another account",
      );
    }
    console.error("updateUserById failed", updateErr);
    return jsonError(500, "promote_failed", msg || "promotion failed");
  }

  // 7. Caller's existing JWT now points to a phone-authenticated user with
  //    the same UID. Client should call refreshSession() to pick up the
  //    fresh claims (is_anonymous becomes false).
  return jsonResponse({ ok: true, user_id: callerUserId, promoted: true });
}

interface JWTPayload {
  sub?: string;
  is_anonymous?: boolean;
  // ... other fields ignored
}

function decodeJWT(token: string): JWTPayload | null {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    // base64url decode the payload (middle segment).
    const payload = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = payload + "=".repeat((4 - (payload.length % 4)) % 4);
    const decoded = atob(padded);
    return JSON.parse(decoded);
  } catch {
    return null;
  }
}

async function sha256(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const hash = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function jsonError(status: number, code: string, message: string) {
  return jsonResponse({ error: message, code }, status);
}
