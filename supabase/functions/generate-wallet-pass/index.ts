// generate-wallet-pass: generates a signed .pkpass for an event RSVP.
//
// V1 STUB — Pass Type ID + cert is not configured per
// Plans/EventLayerV1.md §1.3. This function returns 503 with a hint so
// the iOS WalletPassService.isAvailable correctly reports false.
//
// When you wire Wallet:
//   1. Apple Developer → Certificates → Pass Type ID + signing cert.
//   2. Add cert + key to Supabase secrets:
//        supabase secrets set RUUL_WALLET_PASS_TYPE_ID=...
//        supabase secrets set RUUL_WALLET_CERT_PEM=$(cat cert.pem)
//        supabase secrets set RUUL_WALLET_KEY_PEM=$(cat key.pem)
//        supabase secrets set RUUL_QR_SECRET=...  (shared with iOS)
//   3. Replace the stub below with a real .pkpass builder. Use
//      passkit-generator or a native Deno port (limited Deno support).
//
// Request: { event_id, member_id }
// Response (V1 stub): 503 { error: "wallet not configured" }

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: { "Access-Control-Allow-Origin": "*" } });
  }

  const isConfigured = Boolean(Deno.env.get("RUUL_WALLET_PASS_TYPE_ID")) &&
                       Boolean(Deno.env.get("RUUL_WALLET_CERT_PEM"));

  if (!isConfigured) {
    return new Response(
      JSON.stringify({ error: "wallet not configured", stubbed: true }),
      { status: 503, headers: { "Content-Type": "application/json" } },
    );
  }

  // Real impl placeholder — would build, sign, return .pkpass binary here.
  return new Response(
    JSON.stringify({ error: "real impl pending", stubbed: true }),
    { status: 503, headers: { "Content-Type": "application/json" } },
  );
});
