// supabase/functions/_tests/db/consistency_money.test.ts
//
// Covers ConsistencyAudit_2026-05-17 findings F1 + F3:
//   - pay_fine / void_fine emit ledger_entries; never touch dropped
//     groups.fund_balance / fund_enabled or fines.paid / status columns.
//   - fund_lock / fund_unlock are atom-only; lock state derives from
//     fund_lock_view; resources.metadata.locked_* keys never written.
//   - fund_balance_view exposes is_locked / locked_at from atom-derived view.
//
// Migrations: 00273 (pay_fine/void_fine ledger), 00274 (fund_lock_view +
// RPCs), 00275 (system_events.seq tiebreak).

import { assert, assertEquals } from "jsr:@std/assert@1";
import { adminClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "../e2e/_fixtures/seedGroup.ts";
import { cleanupGroup } from "../e2e/_fixtures/cleanup.ts";

const admin = adminClient();

// =============================================================================
// F1 — pay_fine + void_fine ledger-driven
// =============================================================================

Deno.test("pay_fine emits fine_paid ledger_entry and is idempotent", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });

    // Insert a fine manually via admin (auto_generated=false simulates a
    // manually issued fine). amount=100.00 → 10000 cents.
    const { data: fine, error: fErr } = await admin
      .from("fines")
      .insert({
        group_id: g.groupId,
        user_id: g.founder.userId,
        reason: "smoke",
        amount: 100,
        auto_generated: false,
        issued_by: g.founder.userId,
      })
      .select("id")
      .single();
    assert(!fErr, `fine insert failed: ${fErr?.message}`);
    const fineId = fine.id as string;

    // First pay_fine call. Caller is the fined user himself, so the
    // permission gate passes via `f.user_id = auth.uid()` branch.
    const { error: payErr } = await g.founder.client.rpc("pay_fine", {
      p_fine_id: fineId,
    });
    assert(!payErr, `pay_fine 1 failed: ${payErr?.message}`);

    // Second call — idempotent (already paid).
    const { error: payErr2 } = await g.founder.client.rpc("pay_fine", {
      p_fine_id: fineId,
    });
    assert(!payErr2, `pay_fine 2 (idempotent) failed: ${payErr2?.message}`);

    // Verify exactly one fine_paid ledger entry exists.
    const { data: ledger } = await admin
      .from("ledger_entries")
      .select("id, type, amount_cents, from_member_id, to_member_id, metadata")
      .eq("type", "fine_paid")
      .eq("group_id", g.groupId);
    const matching = (ledger ?? []).filter(
      (r) => (r.metadata as Record<string, unknown>)?.fine_id === fineId,
    );
    assertEquals(matching.length, 1, "expected exactly 1 fine_paid entry");
    assertEquals(matching[0].amount_cents, 10000);
    assertEquals(matching[0].from_member_id, g.founder.memberId);
    assertEquals(matching[0].to_member_id, null);

    // fines_view should derive status='paid'.
    const { data: view } = await admin
      .from("fines_view")
      .select("status, paid, paid_at")
      .eq("id", fineId)
      .single();
    assertEquals(view!.status, "paid");
    assertEquals(view!.paid, true);
    assert(view!.paid_at != null, "paid_at should be derived");
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("pay_fine rejects voided fine", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });

    const { data: fine } = await admin
      .from("fines")
      .insert({
        group_id: g.groupId,
        user_id: g.founder.userId,
        reason: "smoke",
        amount: 50,
        auto_generated: false,
        issued_by: g.founder.userId,
      })
      .select("id")
      .single();
    const fineId = fine!.id as string;

    // Manually insert a fine_voided ledger entry to simulate prior void.
    await admin.from("ledger_entries").insert({
      group_id: g.groupId,
      type: "fine_voided",
      amount_cents: 5000,
      currency: "MXN",
      from_member_id: null,
      to_member_id: g.founder.memberId,
      metadata: { fine_id: fineId, reason: "test" },
      occurred_at: new Date().toISOString(),
      recorded_at: new Date().toISOString(),
    });

    // pay_fine must reject.
    const { error } = await g.founder.client.rpc("pay_fine", {
      p_fine_id: fineId,
    });
    assert(error != null, "pay_fine should have failed on voided fine");
    assert(
      error.message.includes("voided"),
      `unexpected error: ${error.message}`,
    );
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("void_fine emits fine_voided ledger + user_action + fineVoided system_event", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });

    // Ensure founder has voidFine permission. seedGroup may not include it
    // by default — patch groups.roles[founder].permissions if needed.
    const { data: grp } = await admin
      .from("groups")
      .select("roles")
      .eq("id", g.groupId)
      .single();
    const roles = (grp!.roles as Record<string, { permissions?: string[] }>) ??
      {};
    const founderPerms = roles.founder?.permissions ?? [];
    if (!founderPerms.includes("voidFine")) {
      roles.founder = {
        ...(roles.founder ?? {}),
        permissions: [...founderPerms, "voidFine"],
      };
      await admin.from("groups").update({ roles }).eq("id", g.groupId);
    }

    const { data: fine } = await admin
      .from("fines")
      .insert({
        group_id: g.groupId,
        user_id: g.founder.userId,
        reason: "smoke",
        amount: 25,
        auto_generated: false,
        issued_by: g.founder.userId,
      })
      .select("id")
      .single();
    const fineId = fine!.id as string;

    const { error: vErr } = await g.founder.client.rpc("void_fine", {
      p_fine_id: fineId,
      p_reason: "admin override",
    });
    assert(!vErr, `void_fine failed: ${vErr?.message}`);

    // Idempotent.
    const { error: vErr2 } = await g.founder.client.rpc("void_fine", {
      p_fine_id: fineId,
      p_reason: "admin override",
    });
    assert(!vErr2, `void_fine 2 (idempotent) failed: ${vErr2?.message}`);

    // Verify single fine_voided ledger entry.
    const { data: ledger } = await admin
      .from("ledger_entries")
      .select("id, type, metadata")
      .eq("type", "fine_voided")
      .eq("group_id", g.groupId);
    const matching = (ledger ?? []).filter(
      (r) => (r.metadata as Record<string, unknown>)?.fine_id === fineId,
    );
    assertEquals(matching.length, 1, "expected exactly 1 fine_voided entry");

    // user_actions row created.
    const { data: actions } = await admin
      .from("user_actions")
      .select("id, action_type")
      .eq("reference_id", fineId)
      .eq("action_type", "fineVoided");
    assertEquals(actions?.length, 1, "expected 1 fineVoided user_action");

    // system_event emitted.
    const { data: events } = await admin
      .from("system_events")
      .select("id")
      .eq("resource_id", fineId)
      .eq("event_type", "fineVoided");
    assertEquals(events?.length, 1, "expected 1 fineVoided system_event");

    // fines_view derives status='voided'.
    const { data: view } = await admin
      .from("fines_view")
      .select("status, waived")
      .eq("id", fineId)
      .single();
    assertEquals(view!.status, "voided");
    assertEquals(view!.waived, true);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

// =============================================================================
// F3 — fund_lock atom-derived
// =============================================================================

Deno.test("fund_lock emits atom, fund_lock_view derives is_locked, metadata stays clean", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: false,
    });

    // create_fund — caller becomes the fund owner.
    const { data: fundId, error: cfErr } = await g.founder.client.rpc(
      "create_fund",
      {
        p_group_id: g.groupId,
        p_name: "Test Fund",
      },
    );
    assert(!cfErr, `create_fund failed: ${cfErr?.message}`);
    assert(typeof fundId === "string", "fund id should be a uuid string");

    // Lock the fund.
    const { error: lockErr } = await g.founder.client.rpc("fund_lock", {
      p_fund_id: fundId,
      p_reason: "test",
    });
    assert(!lockErr, `fund_lock failed: ${lockErr?.message}`);

    // fund_lock_view should report is_locked=true.
    const { data: viewRow } = await admin
      .from("fund_lock_view")
      .select("is_locked, locked_at, locked_reason")
      .eq("fund_id", fundId)
      .single();
    assertEquals(viewRow!.is_locked, true);
    assert(viewRow!.locked_at != null, "locked_at should derive from atom");
    assertEquals(viewRow!.locked_reason, "test");

    // resources.metadata must NOT contain locked_* keys (atom is truth).
    const { data: resRow } = await admin
      .from("resources")
      .select("metadata")
      .eq("id", fundId)
      .single();
    const meta = resRow!.metadata as Record<string, unknown>;
    assert(!("locked_at" in meta), "metadata.locked_at must NOT be set");
    assert(!("locked_by" in meta), "metadata.locked_by must NOT be set");
    assert(
      !("locked_reason" in meta),
      "metadata.locked_reason must NOT be set",
    );

    // Double-lock should reject.
    const { error: dupErr } = await g.founder.client.rpc("fund_lock", {
      p_fund_id: fundId,
      p_reason: "second",
    });
    assert(dupErr != null, "double-lock should reject");
    assert(
      dupErr.message.includes("already locked"),
      `unexpected error: ${dupErr.message}`,
    );

    // fund_balance_view exposes is_locked.
    const { data: balView } = await admin
      .from("fund_balance_view")
      .select("is_locked, locked_at, balance_cents")
      .eq("fund_id", fundId)
      .single();
    assertEquals(balView!.is_locked, true);
    assert(balView!.locked_at != null);

    // Unlock → derived state flips.
    const { error: unlockErr } = await g.founder.client.rpc("fund_unlock", {
      p_fund_id: fundId,
    });
    assert(!unlockErr, `fund_unlock failed: ${unlockErr?.message}`);

    const { data: viewAfter } = await admin
      .from("fund_lock_view")
      .select("is_locked")
      .eq("fund_id", fundId)
      .single();
    assertEquals(viewAfter!.is_locked, false);

    // Atom count: 1 fundLocked + 1 fundUnlocked.
    const { data: atoms } = await admin
      .from("system_events")
      .select("event_type")
      .eq("resource_id", fundId);
    const types = (atoms ?? []).map((a) => a.event_type);
    assertEquals(
      types.filter((t) => t === "fundLocked").length,
      1,
      "expected 1 fundLocked atom",
    );
    assertEquals(
      types.filter((t) => t === "fundUnlocked").length,
      1,
      "expected 1 fundUnlocked atom",
    );
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("fund_unlock rejects on non-locked fund", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: false,
    });
    const { data: fundId } = await g.founder.client.rpc("create_fund", {
      p_group_id: g.groupId,
      p_name: "Never Locked",
    });

    const { error } = await g.founder.client.rpc("fund_unlock", {
      p_fund_id: fundId as string,
    });
    assert(error != null, "fund_unlock on unlocked fund should reject");
    assert(
      error.message.includes("not locked"),
      `unexpected error: ${error.message}`,
    );
  } finally {
    if (g) await cleanupGroup(g);
  }
});
