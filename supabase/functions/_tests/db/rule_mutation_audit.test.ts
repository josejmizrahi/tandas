// supabase/functions/_tests/db/rule_mutation_audit.test.ts
//
// Covers migration 00024_rule_mutation_audit.sql:
//   - UPDATE rules.enabled flip → exactly 1 ruleEnabledChanged row.
//   - UPDATE rules.consequences → exactly 1 ruleAmountChanged row.
//   - Combined UPDATE → 2 rows.
//   - UPDATE that touches neither column → 0 rows.

import { assertEquals } from "jsr:@std/assert@1";
import { adminClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "../e2e/_fixtures/seedGroup.ts";
import { cleanupGroup } from "../e2e/_fixtures/cleanup.ts";

const admin = adminClient();

async function countRuleEvents(
  groupId: string,
  ruleId: string,
  eventType: "ruleEnabledChanged" | "ruleAmountChanged",
): Promise<number> {
  const { count, error } = await admin
    .from("system_events")
    .select("id", { count: "exact", head: true })
    .eq("group_id", groupId)
    .eq("resource_id", ruleId)
    .eq("event_type", eventType);
  if (error) throw error;
  return count ?? 0;
}

Deno.test("trigger emits ruleEnabledChanged on enabled flip", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });
    const { data: rules } = await admin.from("rules").select("id,enabled")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;
    const initial = rules![0].enabled as boolean;

    await admin.from("rules").update({ enabled: !initial }).eq("id", ruleId);

    assertEquals(await countRuleEvents(g.groupId, ruleId, "ruleEnabledChanged"), 1);
    assertEquals(await countRuleEvents(g.groupId, ruleId, "ruleAmountChanged"), 0);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("trigger emits ruleAmountChanged on consequences change", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });
    const { data: rules } = await admin.from("rules").select("id,consequences")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;

    const newConsequences = [{ type: "fine", config: { amount: 999 } }];
    await admin.from("rules").update({ consequences: newConsequences }).eq("id", ruleId);

    assertEquals(await countRuleEvents(g.groupId, ruleId, "ruleAmountChanged"), 1);
    assertEquals(await countRuleEvents(g.groupId, ruleId, "ruleEnabledChanged"), 0);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("trigger emits both events on combined UPDATE", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });
    const { data: rules } = await admin.from("rules").select("id,enabled,consequences")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;
    const initial = rules![0].enabled as boolean;

    await admin.from("rules").update({
      enabled: !initial,
      consequences: [{ type: "fine", config: { amount: 555 } }],
    }).eq("id", ruleId);

    assertEquals(await countRuleEvents(g.groupId, ruleId, "ruleEnabledChanged"), 1);
    assertEquals(await countRuleEvents(g.groupId, ruleId, "ruleAmountChanged"), 1);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("trigger emits zero events on UPDATE that touches neither column", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });
    const { data: rules } = await admin.from("rules").select("id,title")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;

    await admin.from("rules").update({ title: "Renamed for test" }).eq("id", ruleId);

    assertEquals(await countRuleEvents(g.groupId, ruleId, "ruleEnabledChanged"), 0);
    assertEquals(await countRuleEvents(g.groupId, ruleId, "ruleAmountChanged"), 0);
  } finally {
    if (g) await cleanupGroup(g);
  }
});
