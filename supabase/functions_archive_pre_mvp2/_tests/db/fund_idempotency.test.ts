// supabase/functions/_tests/db/fund_idempotency.test.ts
//
// V1-01 regression coverage. Mig 00351 adds `p_client_id uuid default null`
// to fund_contribute + fund_record_expense. iOS sheets hold a stable
// UUID in @State so a re-tap after a network error reuses the same key
// and the backend returns the existing ledger row instead of inserting
// a duplicate (which would double-credit / double-debit the fund).
//
// Verifies:
//   1. Two calls with the same p_client_id → exactly one ledger row;
//      both calls return rows with the SAME ledger entry id.
//   2. Different p_client_ids → distinct ledger rows.
//   3. Null p_client_id (legacy / pre-V1-01 callers) → each call
//      inserts a new row (regression check — no dedup without a key).
//   4. The partial unique index ledger_entries_client_id_unique covers
//      both fund_contribute and fund_record_expense (same global namespace).

import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { adminClient } from "../e2e/_fixtures/supabaseClients.ts";
import { extractRowId, seedGroup, type SeededGroup } from "../e2e/_fixtures/seedGroup.ts";
import { cleanupGroup } from "../e2e/_fixtures/cleanup.ts";

const admin = adminClient();

async function createFund(groupId: string, founderUserId: string): Promise<string> {
  const { data, error } = await admin.rpc("create_resource_v2", {
    p_group_id:     groupId,
    p_resource_type: "fund",
    p_metadata:     {
      title:      "Test fund",
      currency:   "MXN",
      created_by: founderUserId,
    },
  });
  if (error) throw new Error(`create fund: ${error.message}`);
  const fundId = extractRowId(data);
  if (!fundId) throw new Error(`create fund returned no id: ${JSON.stringify(data)}`);
  return fundId;
}

Deno.test("fund_contribute with p_client_id → idempotent retry; null → not idempotent", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const [alice] = g.members;
    const fundId = await createFund(g.groupId, alice.userId);

    // (1) Same client_id twice → exactly one ledger row.
    const clientIdA = crypto.randomUUID();
    const { data: row1, error: err1 } = await alice.client.rpc("fund_contribute", {
      p_fund_id:      fundId,
      p_amount_cents: 50_000,
      p_note:         "first call",
      p_client_id:    clientIdA,
    });
    assert(!err1, `fund_contribute 1 failed: ${err1?.message}`);

    const { data: row2, error: err2 } = await alice.client.rpc("fund_contribute", {
      p_fund_id:      fundId,
      p_amount_cents: 50_000,
      p_note:         "second call (retry)",
      p_client_id:    clientIdA,
    });
    assert(!err2, `fund_contribute 2 (idempotent retry) failed: ${err2?.message}`);

    assertEquals(
      (row1 as { id: string }).id,
      (row2 as { id: string }).id,
      "retry must return the same ledger entry id",
    );

    const { count: countSameClient } = await admin
      .from("ledger_entries")
      .select("*", { count: "exact", head: true })
      .eq("group_id", g.groupId)
      .eq("type", "contribution")
      .eq("resource_id", fundId)
      .filter("metadata->>client_id", "eq", clientIdA);
    assertEquals(countSameClient, 1, "expected exactly 1 ledger row for clientIdA");

    // (2) Different client_id → distinct ledger row.
    const clientIdB = crypto.randomUUID();
    const { data: row3, error: err3 } = await alice.client.rpc("fund_contribute", {
      p_fund_id:      fundId,
      p_amount_cents: 25_000,
      p_client_id:    clientIdB,
    });
    assert(!err3, `fund_contribute 3 (new client_id) failed: ${err3?.message}`);
    assertNotEquals(
      (row1 as { id: string }).id,
      (row3 as { id: string }).id,
      "new client_id must produce a new ledger entry",
    );

    // (3) Null client_id → no dedup; second call inserts another row.
    const { error: errNull1 } = await alice.client.rpc("fund_contribute", {
      p_fund_id:      fundId,
      p_amount_cents: 10_000,
      // p_client_id intentionally omitted → defaults to null
    });
    assert(!errNull1, `legacy call 1 failed: ${errNull1?.message}`);
    const { error: errNull2 } = await alice.client.rpc("fund_contribute", {
      p_fund_id:      fundId,
      p_amount_cents: 10_000,
    });
    assert(!errNull2, `legacy call 2 failed: ${errNull2?.message}`);

    const { count: legacyCount } = await admin
      .from("ledger_entries")
      .select("*", { count: "exact", head: true })
      .eq("group_id", g.groupId)
      .eq("type", "contribution")
      .eq("resource_id", fundId)
      .eq("amount_cents", 10_000)
      .filter("metadata->>client_id", "is", null);
    assertEquals(legacyCount, 2, "legacy (null client_id) calls must NOT dedup — each tap inserts");
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("fund_record_expense with p_client_id → idempotent retry", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const [alice, bob] = g.members;
    const fundId = await createFund(g.groupId, alice.userId);

    // Seed some balance so the fund has money to spend.
    const { error: seedErr } = await alice.client.rpc("fund_contribute", {
      p_fund_id:      fundId,
      p_amount_cents: 200_000,
      p_client_id:    crypto.randomUUID(),
    });
    assert(!seedErr, `seed contribution failed: ${seedErr?.message}`);

    const clientId = crypto.randomUUID();
    const { data: r1, error: e1 } = await alice.client.rpc("fund_record_expense", {
      p_fund_id:      fundId,
      p_amount_cents: 30_000,
      p_to_member_id: bob.memberId,
      p_note:         "Bocadillos",
      p_client_id:    clientId,
    });
    assert(!e1, `expense 1 failed: ${e1?.message}`);

    const { data: r2, error: e2 } = await alice.client.rpc("fund_record_expense", {
      p_fund_id:      fundId,
      p_amount_cents: 30_000,
      p_to_member_id: bob.memberId,
      p_note:         "Bocadillos (retry)",
      p_client_id:    clientId,
    });
    assert(!e2, `expense 2 (idempotent) failed: ${e2?.message}`);

    assertEquals(
      (r1 as { id: string }).id,
      (r2 as { id: string }).id,
      "expense retry must return the same ledger entry id",
    );

    const { count } = await admin
      .from("ledger_entries")
      .select("*", { count: "exact", head: true })
      .eq("group_id", g.groupId)
      .eq("type", "expense")
      .eq("resource_id", fundId)
      .filter("metadata->>client_id", "eq", clientId);
    assertEquals(count, 1, "expected exactly 1 expense ledger row for clientId");
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("client_id namespace is global: contribute + expense with the SAME client_id collide", async () => {
  // Sanity check the doctrine that the partial unique index is global
  // across ledger types. If iOS misuses by reusing a UUID across
  // contribute + expense (which it shouldn't), the second call must
  // return the FIRST row, not create a polluting cross-type duplicate.
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const [alice, bob] = g.members;
    const fundId = await createFund(g.groupId, alice.userId);
    const sharedClientId = crypto.randomUUID();

    const { data: r1, error: e1 } = await alice.client.rpc("fund_contribute", {
      p_fund_id:      fundId,
      p_amount_cents: 50_000,
      p_client_id:    sharedClientId,
    });
    assert(!e1, `contribute failed: ${e1?.message}`);

    // Reusing the same client_id on expense should return the EXISTING
    // contribution row (not raise, not insert a parallel expense row).
    // This is a side-effect of the global namespace; if it ever feels
    // wrong, we'd tighten the index to (resource_id, type, client_id).
    const { data: r2, error: e2 } = await alice.client.rpc("fund_record_expense", {
      p_fund_id:      fundId,
      p_amount_cents: 30_000,
      p_to_member_id: bob.memberId,
      p_client_id:    sharedClientId,
    });
    assert(!e2, `expense reuse failed: ${e2?.message}`);
    assertEquals(
      (r1 as { id: string }).id,
      (r2 as { id: string }).id,
      "reused client_id must return the existing row",
    );
  } finally {
    if (g) await cleanupGroup(g);
  }
});
