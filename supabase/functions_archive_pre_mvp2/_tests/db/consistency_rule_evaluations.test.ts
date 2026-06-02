// supabase/functions/_tests/db/consistency_rule_evaluations.test.ts
//
// Covers ConsistencyAudit_2026-05-17 finding F5:
//   - rule_evaluations table receives one row per ExecutionResult (audit
//     trail). UNIQUE on idempotency_key prevents duplicate audit rows on
//     retry.
//
// The write happens inside process-system-events edge function after
// runRulesForEvent. This test exercises the table schema directly + the
// guard + the UPSERT pattern used by recordRuleEvaluations(). Live engine
// integration is covered by the rule engine e2e suite (dinnerHappyPath).
//
// Migrations: 00181 (table + guard + idempotency_key UNIQUE).

import { assert, assertEquals } from "jsr:@std/assert@1";
import { adminClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "../e2e/_fixtures/seedGroup.ts";
import { cleanupGroup } from "../e2e/_fixtures/cleanup.ts";

const admin = adminClient();

async function emitTriggerEvent(groupId: string): Promise<string> {
  const { data: id, error } = await admin.rpc("record_system_event", {
    p_group_id: groupId,
    p_event_type: "groupRenamed",
    p_resource_id: null,
    p_member_id: null,
    p_payload: { new_name: "trigger" },
  });
  if (error) throw error;
  return id as string;
}

async function ensureRuleVersion(
  groupId: string,
  ruleId: string,
): Promise<string> {
  const { data: existing } = await admin
    .from("rule_versions")
    .select("id")
    .eq("rule_id", ruleId)
    .eq("status", "active")
    .limit(1)
    .maybeSingle();
  if (existing) return existing.id as string;

  const { data: created, error } = await admin
    .from("rule_versions")
    .insert({
      rule_id: ruleId,
      version: 1,
      compiled: {},
      status: "active",
      effective_from: new Date().toISOString(),
      created_by: null,
    })
    .select("id")
    .single();
  if (error) throw new Error(`rule_versions insert failed: ${error.message}`);
  return created.id as string;
}

Deno.test("rule_evaluations UPSERT with onConflict idempotency_key prevents dupes", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });

    // Pick the first seeded rule.
    const { data: rules } = await admin
      .from("rules")
      .select("id")
      .eq("group_id", g.groupId)
      .limit(1);
    assert((rules ?? []).length > 0, "seedGroup with rules should yield ≥1");
    const ruleId = rules![0].id as string;
    const ruleVersionId = await ensureRuleVersion(g.groupId, ruleId);

    const eventId = await emitTriggerEvent(g.groupId);
    const idemKey = `${ruleVersionId}|${eventId}|${g.founder.memberId}|0`;

    const row = {
      rule_id: ruleId,
      rule_version_id: ruleVersionId,
      trigger_event_id: eventId,
      trigger_event_table: "system_events",
      group_id: g.groupId,
      actor_id: g.founder.memberId,
      verdict: "matched_consequences",
      consequences: { emitted_event_types: [], created_resource_ids: [] },
      conflicts_detected: [],
      error_message: null,
      idempotency_key: idemKey,
    };

    // First upsert — inserts.
    const { error: e1 } = await admin
      .from("rule_evaluations")
      .upsert(row, { onConflict: "idempotency_key", ignoreDuplicates: true });
    assert(!e1, `first upsert failed: ${e1?.message}`);

    // Second upsert with same idempotency_key — must be no-op.
    const { error: e2 } = await admin
      .from("rule_evaluations")
      .upsert(row, { onConflict: "idempotency_key", ignoreDuplicates: true });
    assert(!e2, `second upsert (idempotent) failed: ${e2?.message}`);

    // Verify exactly 1 row exists for this idempotency_key.
    const { data: matching } = await admin
      .from("rule_evaluations")
      .select("id")
      .eq("idempotency_key", idemKey);
    assertEquals(
      matching?.length,
      1,
      "exactly 1 row expected per idempotency_key",
    );
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("rule_evaluations rejects UPDATE/DELETE (append-only guard)", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });
    const { data: rules } = await admin
      .from("rules")
      .select("id")
      .eq("group_id", g.groupId)
      .limit(1);
    const ruleId = rules![0].id as string;
    const ruleVersionId = await ensureRuleVersion(g.groupId, ruleId);

    const eventId = await emitTriggerEvent(g.groupId);
    const { data: row, error } = await admin
      .from("rule_evaluations")
      .insert({
        rule_id: ruleId,
        rule_version_id: ruleVersionId,
        trigger_event_id: eventId,
        trigger_event_table: "system_events",
        group_id: g.groupId,
        actor_id: null,
        verdict: "matched_no_action",
        consequences: { emitted_event_types: [], created_resource_ids: [] },
        conflicts_detected: [],
        error_message: null,
        idempotency_key: `${ruleVersionId}|${eventId}|guard-test|0`,
      })
      .select("id")
      .single();
    assert(!error, `insert failed: ${error?.message}`);

    const { error: upErr } = await admin
      .from("rule_evaluations")
      .update({ verdict: "error" })
      .eq("id", row!.id as string);
    assert(upErr != null, "rule_evaluations UPDATE should be rejected");

    const { error: delErr } = await admin
      .from("rule_evaluations")
      .delete()
      .eq("id", row!.id as string);
    assert(delErr != null, "rule_evaluations DELETE should be rejected");
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("rule_evaluations verdict CHECK constraint enforces whitelist", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });
    const { data: rules } = await admin
      .from("rules")
      .select("id")
      .eq("group_id", g.groupId)
      .limit(1);
    const ruleId = rules![0].id as string;
    const ruleVersionId = await ensureRuleVersion(g.groupId, ruleId);

    const eventId = await emitTriggerEvent(g.groupId);
    const { error } = await admin
      .from("rule_evaluations")
      .insert({
        rule_id: ruleId,
        rule_version_id: ruleVersionId,
        trigger_event_id: eventId,
        trigger_event_table: "system_events",
        group_id: g.groupId,
        actor_id: null,
        verdict: "bogus_verdict",
        consequences: { emitted_event_types: [], created_resource_ids: [] },
        conflicts_detected: [],
        error_message: null,
        idempotency_key: `${ruleVersionId}|${eventId}|verdict-test|0`,
      });
    assert(error != null, "invalid verdict should be rejected by CHECK");
  } finally {
    if (g) await cleanupGroup(g);
  }
});
