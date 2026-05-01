// Shared CORS headers for ruul edge functions.
// All functions are called from the iOS app via supabase-js / direct fetch.
// Mobile app doesn't need CORS, but local dev (Xcode → http://localhost:54321)
// does, so we include them.

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
