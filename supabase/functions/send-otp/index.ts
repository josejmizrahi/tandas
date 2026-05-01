// send-otp: requests an OTP for a phone number.
//
// Tries WhatsApp via Wassenger first; falls back to SMS via Supabase Auth
// after a 5s timeout or any Wassenger error. The actual channel used is
// returned so the iOS client can update the UI ("Te mandamos por WhatsApp"
// vs "Te mandamos un SMS").
//
// Request:  { phone: "+5215555551234" }
// Response: { channel: "whatsapp" | "sms", expires_at: ISO8601 }
//
// Env (set as Supabase function secrets):
//   WASSENGER_API_KEY    — Wassenger account API key
//   WASSENGER_DEVICE_ID  — the WhatsApp device id to send from
//   WASSENGER_TIMEOUT_MS — optional, default 5000
//
// Storage: writes to public.otp_codes via the service-role connection.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { corsHeaders } from "../_shared/cors.ts";

const WASSENGER_API_KEY = Deno.env.get("WASSENGER_API_KEY") ?? "";
const WASSENGER_DEVICE_ID = Deno.env.get("WASSENGER_DEVICE_ID") ?? "";
const WASSENGER_TIMEOUT_MS = parseInt(
  Deno.env.get("WASSENGER_TIMEOUT_MS") ?? "5000",
);

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const TTL_MINUTES = 10;

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  let phone: string;
  try {
    const body = await req.json();
    phone = body.phone;
    if (!phone || typeof phone !== "string" || !phone.startsWith("+")) {
      return jsonError(400, "phone must be E.164 (+...)");
    }
  } catch {
    return jsonError(400, "invalid JSON body");
  }

  const code = generateCode();
  const expires_at = new Date(Date.now() + TTL_MINUTES * 60 * 1000);
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // Try WhatsApp first if configured.
  let channel: "whatsapp" | "sms" = "sms";
  if (WASSENGER_API_KEY && WASSENGER_DEVICE_ID) {
    const ok = await sendViaWhatsApp(phone, code);
    if (ok) channel = "whatsapp";
  }

  if (channel === "sms") {
    // Fall back to Supabase Auth SMS (Twilio under the hood).
    const { error } = await supabase.auth.signInWithOtp({ phone });
    if (error) {
      return jsonError(502, `sms send failed: ${error.message}`);
    }
    // For SMS path, Supabase Auth manages the code itself; we don't store
    // anything in otp_codes. We return channel='sms' so the verify-otp
    // function knows to forward to auth.verifyOtp.
    return jsonResponse({ channel: "sms", expires_at });
  }

  // For WhatsApp path, persist the code hash so verify-otp can validate.
  const codeHash = await sha256(`${code}:${phone}`);
  const { error: insertErr } = await supabase
    .from("otp_codes")
    .insert({
      phone_e164: phone,
      code_hash: codeHash,
      channel,
      expires_at: expires_at.toISOString(),
    });
  if (insertErr) {
    console.error("otp_codes insert failed", insertErr);
    return jsonError(500, "failed to store code");
  }

  return jsonResponse({ channel, expires_at });
});

async function sendViaWhatsApp(phone: string, code: string): Promise<boolean> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), WASSENGER_TIMEOUT_MS);
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
        message:
          `Tu código de ruul es: ${code}\n\nEste código expira en ${TTL_MINUTES} minutos. ` +
          `Si no lo solicitaste, ignora este mensaje.`,
      }),
      signal: controller.signal,
    });
    clearTimeout(timeout);
    if (!res.ok) {
      console.warn("wassenger non-2xx", res.status, await res.text());
      return false;
    }
    return true;
  } catch (err) {
    console.warn("wassenger send threw", err);
    return false;
  } finally {
    clearTimeout(timeout);
  }
}

function generateCode(): string {
  const buf = new Uint8Array(4);
  crypto.getRandomValues(buf);
  const value = (buf[0] << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3];
  return String(Math.abs(value) % 1_000_000).padStart(6, "0");
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

function jsonError(status: number, message: string) {
  return jsonResponse({ error: message }, status);
}
