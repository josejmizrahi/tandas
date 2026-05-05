// supabase/functions/_tests/db/can_modify_rules.test.ts
//
// Covers public.can_modify_rules(group_id, user_id):
//   - founder + governance.whoCanModifyRules='founder'  → true
//   - founder + governance='majorityVote'                → false
//   - anyMember + governance='anyMember'                 → true
//   - anyMember + governance='founder'                   → false
//   - inactive member + role=founder                     → false
//   - user not in group at all                           → false

import { assertEquals } from "jsr:@std/assert@1";
import { adminClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "../e2e/_fixtures/seedGroup.ts";
import { cleanupGroup } from "../e2e/_fixtures/cleanup.ts";

const admin = adminClient();

async function callCanModify(groupId: string, userId: string): Promise<boolean> {
  const { data, error } = await admin.rpc("can_modify_rules", {
    p_group_id: groupId,
    p_user_id: userId,
  });
  if (error) throw error;
  return data as boolean;
}

async function setGovernance(groupId: string, key: string, value: string) {
  const { data: g } = await admin.from("groups").select("governance").eq("id", groupId).single();
  const merged = { ...((g!.governance as Record<string, unknown>) ?? {}), [key]: value };
  await admin.from("groups").update({ governance: merged }).eq("id", groupId);
}

Deno.test("can_modify_rules — founder + governance=founder → true", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const founder = g.members[0];
    await setGovernance(g.groupId, "whoCanModifyRules", "founder");
    assertEquals(await callCanModify(g.groupId, founder.userId), true);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("can_modify_rules — founder + governance=majorityVote → false", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const founder = g.members[0];
    await setGovernance(g.groupId, "whoCanModifyRules", "majorityVote");
    assertEquals(await callCanModify(g.groupId, founder.userId), false);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("can_modify_rules — anyMember + governance=anyMember → true", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const member = g.members[1]; // bob, non-founder
    await setGovernance(g.groupId, "whoCanModifyRules", "anyMember");
    assertEquals(await callCanModify(g.groupId, member.userId), true);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("can_modify_rules — anyMember + governance=founder → false", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const member = g.members[1];
    await setGovernance(g.groupId, "whoCanModifyRules", "founder");
    assertEquals(await callCanModify(g.groupId, member.userId), false);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("can_modify_rules — inactive member + role=founder → false", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const founder = g.members[0];
    await setGovernance(g.groupId, "whoCanModifyRules", "founder");

    // Deactivate the founder's membership.
    await admin.from("group_members").update({ active: false })
      .eq("group_id", g.groupId).eq("user_id", founder.userId);

    assertEquals(await callCanModify(g.groupId, founder.userId), false);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("can_modify_rules — user not in group → false", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: false,
    });
    await setGovernance(g.groupId, "whoCanModifyRules", "anyMember");

    const randomUserId = "00000000-0000-0000-0000-000000000099";
    assertEquals(await callCanModify(g.groupId, randomUserId), false);
  } finally {
    if (g) await cleanupGroup(g);
  }
});
