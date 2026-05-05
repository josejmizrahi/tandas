// Reads the env vars every E2E test needs. Throws loud if anything's missing
// so a CI run with bad config fails fast instead of producing confusing
// "fetch failed" errors mid-test.

export interface E2EEnv {
  supabaseUrl: string;
  serviceRoleKey: string;
  anonKey: string;
  /** Functions URL base. Defaults to <SUPABASE_URL>/functions/v1. */
  functionsUrl: string;
}

export function loadEnv(): E2EEnv {
  const supabaseUrl = required("SUPABASE_URL");
  const serviceRoleKey = required("SUPABASE_SERVICE_ROLE_KEY");
  const anonKey = required("SUPABASE_ANON_KEY");
  const functionsUrl = Deno.env.get("SUPABASE_FUNCTIONS_URL")
    ?? `${supabaseUrl.replace(/\/$/, "")}/functions/v1`;

  // Sanity check: the X-Test-Clock header only works when this flag is set.
  // We don't fail the test if it's missing — the test will still run, just
  // without clock control — but we do warn so the developer knows why
  // backdated assertions look stale.
  if (Deno.env.get("ALLOW_CLOCK_OVERRIDE") !== "true") {
    console.warn(
      "[e2e] ALLOW_CLOCK_OVERRIDE is not set to 'true'. " +
      "X-Test-Clock headers will be ignored — scenarios that depend on " +
      "advancing past grace periods or vote close times will hang or fail.",
    );
  }

  return { supabaseUrl, serviceRoleKey, anonKey, functionsUrl };
}

function required(key: string): string {
  const v = Deno.env.get(key);
  if (!v || v.length === 0) {
    throw new Error(
      `[e2e] missing env var ${key}. ` +
      `For local supabase: source from \`supabase status -o json\`. ` +
      `See supabase/functions/_tests/README.md for the full setup.`,
    );
  }
  return v;
}
