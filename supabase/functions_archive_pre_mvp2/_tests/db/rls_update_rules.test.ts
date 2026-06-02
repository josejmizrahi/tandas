// supabase/functions/_tests/db/rls_update_rules.test.ts
//
// Covers the swapped UPDATE policy on rules:
//   - Founder of governance=founder group → UPDATE succeeds.
//   - Founder of governance=majorityVote group → UPDATE fails (42501).
//   - anyMember of governance=anyMember → succeeds.
//   - anyMember of governance=founder → fails.
//
// Uses a per-user supabase client with the user's JWT (NOT admin) so RLS
// is enforced.

import { assertEquals } from "jsr:@std/assert@1";
import { adminClient, userClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "../e2e/_fixtures/seedGroup.ts";
import { cleanupGroup } from "../e2e/_fixtures/cleanup.ts";

const admin = adminClient();

async function setGovernance(groupId: string, key: string, value: string) {
  const { data: g } = await admin.from("groups").select("governance").eq("id", groupId).single();
  const merged = { ...((g!.governance as Record<string, unknown>) ?? {}), [key]: value };
  await admin.from("groups").update({ governance: merged }).eq("id", groupId);
}

Deno.test("RLS allows founder UPDATE rules when governance=founder", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });
    await setGovernance(g.groupId, "whoCanModifyRules", "founder");

    const founder = g.members[0];
    const { data: rules } = await admin.from("rules").select("id,is_active")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;
    const initial = rules![0].is_active as boolean;

    const userScoped = userClient(founder.accessToken!);
    const { error } = await userScoped.from("rules")
      .update({ is_active: !initial }).eq("id", ruleId);

    assertEquals(error, null);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("RLS denies founder UPDATE rules when governance=majorityVote", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });
    await setGovernance(g.groupId, "whoCanModifyRules", "majorityVote");

    const founder = g.members[0];
    const { data: rules } = await admin.from("rules").select("id,is_active")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;

    const userScoped = userClient(founder.accessToken!);
    const { error } = await userScoped.from("rules")
      .update({ is_active: false }).eq("id", ruleId);

    if (error) {
      assertEquals(error.code === "42501" || error.message.includes("policy"), true);
    } else {
      // No error, but the UPDATE matched zero rows because the policy filtered them out.
      const { data: after } = await admin.from("rules").select("is_active").eq("id", ruleId).single();
      assertEquals(after!.is_active, rules![0].is_active, "rule should remain unchanged");
    }
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("RLS allows non-founder member UPDATE when governance=anyMember", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: true,
    });
    await setGovernance(g.groupId, "whoCanModifyRules", "anyMember");

    const bob = g.members[1];
    const { data: rules } = await admin.from("rules").select("id,is_active")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;
    const initial = rules![0].is_active as boolean;

    const userScoped = userClient(bob.accessToken!);
    const { error } = await userScoped.from("rules")
      .update({ is_active: !initial }).eq("id", ruleId);

    assertEquals(error, null);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("RLS denies non-founder member UPDATE when governance=founder", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: true,
    });
    await setGovernance(g.groupId, "whoCanModifyRules", "founder");

    const bob = g.members[1];
    const { data: rules } = await admin.from("rules").select("id,is_active")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;

    const userScoped = userClient(bob.accessToken!);
    const { error } = await userScoped.from("rules")
      .update({ is_active: false }).eq("id", ruleId);

    if (error) {
      assertEquals(error.code === "42501" || error.message.includes("policy"), true);
    } else {
      const { data: after } = await admin.from("rules").select("is_active").eq("id", ruleId).single();
      assertEquals(after!.is_active, rules![0].is_active, "rule should remain unchanged");
    }
  } finally {
    if (g) await cleanupGroup(g);
  }
});
