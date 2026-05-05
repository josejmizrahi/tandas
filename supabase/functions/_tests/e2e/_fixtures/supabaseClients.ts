// Supabase client factories for E2E tests.
//
// The test needs three flavors of client:
//
//   admin    — service-role; bypasses RLS. Used to create users via
//              auth.admin.createUser, query any table for assertions,
//              and clean up after the test.
//
//   authed   — anon-key client signed in as a specific user. Used to
//              call SECURITY DEFINER RPCs that require auth.uid()
//              (create_event_v2, set_rsvp_v2, close_event,
//              start_appeal, cast_vote, etc.). One per test member.
//
//   anon     — anon-key without sign-in. Rarely useful in E2E but
//              exposed for negative tests if needed.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { loadEnv } from "./env.ts";

const env = loadEnv();

export function adminClient(): SupabaseClient {
  return createClient(env.supabaseUrl, env.serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export function anonClient(): SupabaseClient {
  return createClient(env.supabaseUrl, env.anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/**
 * Creates a confirmed test user via auth.admin and signs them in. Returns
 * both the user_id and a SupabaseClient authenticated as that user — use
 * the latter for any RPC call that needs auth.uid() to resolve.
 */
export async function createTestUser(args: {
  email: string;
  password: string;
}): Promise<{ userId: string; client: SupabaseClient }> {
  const admin = adminClient();

  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email: args.email,
    password: args.password,
    email_confirm: true,
  });
  if (createErr) {
    throw new Error(`createTestUser(${args.email}) admin.createUser failed: ${createErr.message}`);
  }
  const userId = created.user!.id;

  const userClient = anonClient();
  const { error: signInErr } = await userClient.auth.signInWithPassword({
    email: args.email,
    password: args.password,
  });
  if (signInErr) {
    throw new Error(`createTestUser(${args.email}) signIn failed: ${signInErr.message}`);
  }

  return { userId, client: userClient };
}

/** Convenience: drops a user from auth (cleanup). */
export async function deleteTestUser(userId: string): Promise<void> {
  const admin = adminClient();
  const { error } = await admin.auth.admin.deleteUser(userId);
  if (error) console.warn(`[e2e] deleteTestUser(${userId}) failed (best-effort): ${error.message}`);
}
