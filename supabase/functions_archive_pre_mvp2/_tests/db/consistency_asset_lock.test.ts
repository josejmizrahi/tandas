// supabase/functions/_tests/db/consistency_asset_lock.test.ts
//
// Covers ConsistencyAudit_2026-05-17 finding F8:
//   - lock_asset_bookings RPC emits assetBookingsLocked atom and writes
//     cache (atom-backed). No direct UPDATE resources.metadata from
//     edge-function code anymore (Sprint 4.12).
//   - asset_booking_lock_view derives is_locked from latest atom per asset
//     ordered by system_events.seq DESC.
//   - RPC is idempotent against the view.
//
// Migration: 00284 (atoms whitelisted + RPC + view).

import { assert, assertEquals } from "jsr:@std/assert@1";
import { adminClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "../e2e/_fixtures/seedGroup.ts";
import { cleanupGroup } from "../e2e/_fixtures/cleanup.ts";

const admin = adminClient();

Deno.test("lock_asset_bookings emits atom + writes cache + idempotent", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: false,
    });

    const { data: assetId, error: aErr } = await g.founder.client.rpc(
      "create_asset",
      { p_group_id: g.groupId, p_name: "Lockable" },
    );
    assert(!aErr, `create_asset failed: ${aErr?.message}`);

    // First lock — atom emitted, view flips to is_locked=true.
    const { error: lErr } = await g.founder.client.rpc("lock_asset_bookings", {
      p_asset_id: assetId as string,
      p_reason: "maintenance overdue",
      p_rule_id: null,
    });
    assert(!lErr, `lock_asset_bookings failed: ${lErr?.message}`);

    const { data: viewAfter } = await admin
      .from("asset_booking_lock_view")
      .select("is_locked, reason")
      .eq("asset_id", assetId as string)
      .single();
    assertEquals(viewAfter!.is_locked, true);
    assertEquals(viewAfter!.reason, "maintenance overdue");

    // Cache write: resources.metadata.bookings_locked=true (acceptable cache,
    // atom-backed per OperationalCacheDoctrine §5).
    const { data: meta } = await admin
      .from("resources")
      .select("metadata")
      .eq("id", assetId as string)
      .single();
    const m = meta!.metadata as Record<string, unknown>;
    assertEquals(m.bookings_locked, true);

    // Second lock — idempotent (no second atom).
    const { error: l2Err } = await g.founder.client.rpc("lock_asset_bookings", {
      p_asset_id: assetId as string,
      p_reason: "second attempt",
      p_rule_id: null,
    });
    assert(!l2Err, `second lock should be idempotent: ${l2Err?.message}`);

    const { data: atoms } = await admin
      .from("system_events")
      .select("id")
      .eq("resource_id", assetId as string)
      .eq("event_type", "assetBookingsLocked");
    assertEquals(
      atoms?.length,
      1,
      "expected exactly 1 assetBookingsLocked atom",
    );

    // Unlock → view flips back, cache cleared.
    const { error: uErr } = await g.founder.client.rpc(
      "unlock_asset_bookings",
      { p_asset_id: assetId as string, p_reason: null },
    );
    assert(!uErr, `unlock_asset_bookings failed: ${uErr?.message}`);

    const { data: viewAfterUnlock } = await admin
      .from("asset_booking_lock_view")
      .select("is_locked")
      .eq("asset_id", assetId as string)
      .single();
    assertEquals(viewAfterUnlock!.is_locked, false);

    const { data: metaAfter } = await admin
      .from("resources")
      .select("metadata")
      .eq("id", assetId as string)
      .single();
    const mAfter = metaAfter!.metadata as Record<string, unknown>;
    assert(
      !("bookings_locked" in mAfter),
      "metadata.bookings_locked should be cleared on unlock",
    );

    // Atom counts: 1 locked + 1 unlocked.
    const { data: allAtoms } = await admin
      .from("system_events")
      .select("event_type")
      .eq("resource_id", assetId as string)
      .in("event_type", ["assetBookingsLocked", "assetBookingsUnlocked"]);
    const types = (allAtoms ?? []).map((a) => a.event_type);
    assertEquals(types.filter((t) => t === "assetBookingsLocked").length, 1);
    assertEquals(types.filter((t) => t === "assetBookingsUnlocked").length, 1);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("unlock_asset_bookings on non-locked asset is no-op", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: false,
    });
    const { data: assetId } = await g.founder.client.rpc("create_asset", {
      p_group_id: g.groupId,
      p_name: "Never locked",
    });

    // Unlock without prior lock — silent no-op (returns; no atom emitted).
    const { error } = await g.founder.client.rpc("unlock_asset_bookings", {
      p_asset_id: assetId as string,
      p_reason: null,
    });
    assert(!error, `unlock should be no-op, got: ${error?.message}`);

    const { data: atoms } = await admin
      .from("system_events")
      .select("id")
      .eq("resource_id", assetId as string)
      .in("event_type", ["assetBookingsLocked", "assetBookingsUnlocked"]);
    assertEquals(atoms?.length, 0, "expected zero lock/unlock atoms");
  } finally {
    if (g) await cleanupGroup(g);
  }
});
