// Seeds a fully-formed test group: auth users → group → members → rules.
//
// Returns everything the test needs to drive scenarios: the group_id,
// each member's userId + group_member id + authed Supabase client, and
// the founder reference for convenience.
//
// Idempotency note: each call uses fresh UUIDs + random emails so two
// concurrent test runs never collide. Cleanup is a separate concern
// (see cleanup.ts).

import { adminClient, createTestUser } from "./supabaseClients.ts";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

export interface MemberSpec {
  /** Human label for test readability. Becomes part of the email. */
  handle: string;
}

export interface SeededMember {
  handle: string;
  userId: string;
  memberId: string;          // group_members.id
  email: string;
  client: SupabaseClient;     // authenticated as this user
  accessToken: string;        // raw JWT — feed into userClient() for RLS tests
}

export interface SeededGroup {
  groupId: string;
  groupName: string;
  founder: SeededMember;       // alias for members[0]
  members: SeededMember[];
}

export interface SeedOpts {
  /** Display name for the group. Default includes a random suffix. */
  groupName?: string;
  /** Members to provision. The first becomes founder/admin. */
  memberSpecs: MemberSpec[];
  /** Whether to call seed_dinner_template_rules after group creation. */
  seedDinnerRules?: boolean;
  /**
   * Base template id to pass to `create_group_with_admin`. Defaults to
   * `recurring_dinner` (V1 dinner scenarios). Phase 2 tests pass
   * `shared_resource` to exercise the palco/cabaña/casa lifecycle —
   * `create_group_with_admin` auto-invokes `seed_template_rules` +
   * `seed_template_roles` so the group lands fully configured.
   */
  baseTemplate?: string;
}

export async function seedGroup(opts: SeedOpts): Promise<SeededGroup> {
  if (opts.memberSpecs.length === 0) {
    throw new Error("seedGroup: at least one member required (the founder)");
  }

  const admin = adminClient();
  const runTag = crypto.randomUUID().slice(0, 8);
  const groupName = opts.groupName ?? `e2e-${runTag}`;

  // 1. Create auth users + sign them in
  const provisioned: SeededMember[] = [];
  for (const spec of opts.memberSpecs) {
    const email = `e2e-${runTag}-${spec.handle.toLowerCase()}@test.local`;
    const password = `pwd-${crypto.randomUUID()}`;
    const { userId, client, accessToken } = await createTestUser({ email, password });
    provisioned.push({
      handle: spec.handle,
      userId,
      email,
      client,
      accessToken,
      memberId: "",   // filled in below
    });
  }

  // 2. Founder creates the group via RPC
  const founderEntry = provisioned[0];
  const { data: groupId, error: groupErr } = await founderEntry.client.rpc(
    "create_group_with_admin",
    { p_name: groupName, p_base_template: opts.baseTemplate ?? "recurring_dinner" },
  );
  if (groupErr) {
    throw new Error(`seedGroup: create_group_with_admin failed: ${groupErr.message}`);
  }
  if (!groupId) {
    throw new Error("seedGroup: create_group_with_admin returned no group_id");
  }

  // 3. Look up founder's group_members.id
  const { data: founderRow, error: founderErr } = await admin
    .from("group_members")
    .select("id")
    .eq("group_id", groupId)
    .eq("user_id", founderEntry.userId)
    .single();
  if (founderErr || !founderRow) {
    throw new Error(`seedGroup: failed to read founder member row: ${founderErr?.message}`);
  }
  founderEntry.memberId = founderRow.id;

  // 4. Insert remaining members directly via service-role (bypasses
  //    join_group_by_code flow — we don't need invite codes for tests).
  for (const m of provisioned.slice(1)) {
    const { data: insertedRow, error: insertErr } = await admin
      .from("group_members")
      .insert({
        group_id: groupId,
        user_id: m.userId,
        role: "member",
        active: true,
      })
      .select("id")
      .single();
    if (insertErr || !insertedRow) {
      throw new Error(`seedGroup: insert member ${m.handle} failed: ${insertErr?.message}`);
    }
    m.memberId = insertedRow.id;
  }

  // 5. Seed dinner template rules if requested
  if (opts.seedDinnerRules) {
    const { error: ruleErr } = await founderEntry.client.rpc(
      "seed_dinner_template_rules",
      { p_group_id: groupId },
    );
    if (ruleErr) {
      throw new Error(`seedGroup: seed_dinner_template_rules failed: ${ruleErr.message}`);
    }
  }

  return {
    groupId: groupId as string,
    groupName,
    founder: founderEntry,
    members: provisioned,
  };
}
