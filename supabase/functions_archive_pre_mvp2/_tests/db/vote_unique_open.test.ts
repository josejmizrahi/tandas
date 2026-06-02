// supabase/functions/_tests/db/vote_unique_open.test.ts
//
// Covers migration 00025_unique_open_vote_per_reference.sql:
//   - Two open votes with same (vote_type, reference_id) → second fails
//     with unique violation.
//   - After closing the first, opening a new one with same key → succeeds.

import { assert } from "jsr:@std/assert@1";
import { adminClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "../e2e/_fixtures/seedGroup.ts";
import { cleanupGroup } from "../e2e/_fixtures/cleanup.ts";

const admin = adminClient();

Deno.test("unique index blocks duplicate open vote on same (vote_type, reference_id)", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });
    const { data: rules } = await admin.from("rules").select("id")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;

    // First open vote — succeeds.
    const { error: firstErr } = await admin.from("votes").insert({
      group_id: g.groupId,
      vote_type: "rule_repeal",
      reference_id: ruleId,
      title: "Archive rule (first)",
      created_by_member_id: g.members[0].memberId,
      opened_at: new Date().toISOString(),
      closes_at: new Date(Date.now() + 72 * 3600 * 1000).toISOString(),
      quorum_percent: 50,
      threshold_percent: 50,
      is_anonymous: true,
      status: "open",
    });
    assert(!firstErr, `first insert failed: ${firstErr?.message}`);

    // Second open vote with same (vote_type, reference_id) — must fail.
    // supabase-js v2 surfaces PostgrestError as a plain object (NOT an
    // Error subclass), so `assertRejects(fn, Error, msg)` rejects with
    // "A non-Error object was rejected" before reaching the message
    // check. Use inline assertions on the returned `error` shape
    // instead. Postgres unique violation code is `23505`.
    const { error: dupErr } = await admin.from("votes").insert({
      group_id: g!.groupId,
      vote_type: "rule_repeal",
      reference_id: ruleId,
      title: "Archive rule (second)",
      created_by_member_id: g!.members[0].memberId,
      opened_at: new Date().toISOString(),
      closes_at: new Date(Date.now() + 72 * 3600 * 1000).toISOString(),
      quorum_percent: 50,
      threshold_percent: 50,
      is_anonymous: true,
      status: "open",
    });
    assert(dupErr !== null, "expected unique violation, got success");
    assert(
      dupErr.code === "23505" || (dupErr.message ?? "").includes("duplicate key value"),
      `expected 23505 / duplicate key, got ${dupErr.code}: ${dupErr.message}`,
    );

    // Close the first vote — second can now open.
    await admin.from("votes").update({ status: "rejected" })
      .eq("group_id", g.groupId).eq("vote_type", "rule_repeal").eq("reference_id", ruleId);

    const { error: thirdErr } = await admin.from("votes").insert({
      group_id: g.groupId,
      vote_type: "rule_repeal",
      reference_id: ruleId,
      title: "Archive rule (third)",
      created_by_member_id: g.members[0].memberId,
      opened_at: new Date().toISOString(),
      closes_at: new Date(Date.now() + 72 * 3600 * 1000).toISOString(),
      quorum_percent: 50,
      threshold_percent: 50,
      is_anonymous: true,
      status: "open",
    });
    assert(!thirdErr, `third insert failed: ${thirdErr?.message}`);
  } finally {
    if (g) await cleanupGroup(g);
  }
});
