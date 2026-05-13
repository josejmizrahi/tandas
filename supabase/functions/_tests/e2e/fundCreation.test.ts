// Tier 6 slice 19 (mig 00137) acceptance: fund resource_type creation.
//
// Three scenarios:
//   1. build_resource_from_draft with resource_type='fund' inserts a row
//      into `resources` with metadata{name, target_amount_cents, currency}
//      and emits `fundCreated` to system_events.
//   2. Direct create_fund RPC works for any group member (not admin-only).
//   3. Funds participate in balance projection: a contribution scoped to
//      the fund's resource_id shows up in member_balances_per_resource.

import { assertEquals, assertExists } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";

const admin = adminClient();

Deno.test("Tier 6: build_resource_from_draft creates a fund + emits fundCreated", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });

    const { data: fundId, error } = await group.founder.client.rpc(
      "build_resource_from_draft",
      {
        p_group_id:             group.groupId,
        p_resource_type:        "fund",
        p_basic_fields: {
          name:               "Bote de fin de año",
          targetAmountCents:  500000,
          currency:           "MXN",
        },
        p_enabled_capabilities: ["money", "ledger"],
        p_capability_configs:   {},
        p_series_pattern:       null,
        p_initial_rules:        [],
      },
    );
    if (error) throw new Error(`build_resource_from_draft: ${error.message}`);
    if (typeof fundId !== "string") {
      throw new Error(`expected uuid, got ${JSON.stringify(fundId)}`);
    }

    // Resource row materialized with the right metadata.
    const { data: row } = await admin
      .from("resources")
      .select("id, resource_type, status, metadata")
      .eq("id", fundId)
      .single();
    assertExists(row, "fund resource row");
    assertEquals(row!.resource_type, "fund");
    assertEquals(row!.status, "active");
    const md = row!.metadata as Record<string, unknown>;
    assertEquals(md.name, "Bote de fin de año");
    assertEquals(md.target_amount_cents, 500000);
    assertEquals(md.currency, "MXN");

    // fundCreated emitted.
    const { data: events } = await admin
      .from("system_events")
      .select("event_type, resource_id, payload")
      .eq("group_id", group.groupId)
      .eq("event_type", "fundCreated")
      .eq("resource_id", fundId);
    assertEquals(events?.length, 1, "exactly one fundCreated emit");
    const payload = events![0].payload as Record<string, unknown>;
    assertEquals(payload.name, "Bote de fin de año");
    assertEquals(payload.target_amount_cents, 500000);

    // Both capabilities persisted.
    const { data: caps } = await admin
      .from("resource_capabilities")
      .select("capability_block_id, enabled")
      .eq("resource_id", fundId);
    const capIds = new Set((caps ?? []).map((c) => c.capability_block_id));
    assertEquals(capIds.has("money"), true);
    assertEquals(capIds.has("ledger"), true);
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 6: any group member can call create_fund directly (not admin-only)", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const bob = group.members[1]; // non-founder

    const { data: fundId, error } = await bob.client.rpc("create_fund", {
      p_group_id:            group.groupId,
      p_name:                "Vaquita para regalo",
      p_target_amount_cents: null,
      p_currency:            "MXN",
    });
    if (error) throw new Error(`create_fund: ${error.message}`);
    assertEquals(typeof fundId, "string");

    const { data: row } = await admin
      .from("resources")
      .select("resource_type, metadata, created_by")
      .eq("id", fundId as string)
      .single();
    assertEquals(row!.resource_type, "fund");
    assertEquals((row!.metadata as Record<string, unknown>).name, "Vaquita para regalo");
    assertEquals(row!.created_by, bob.userId);
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 6: fund balances aggregate via member_balances_per_resource", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }, { handle: "carla" }],
      seedDinnerRules: false,
    });
    const [alice, bob, carla] = group.members;

    // Create a fund via the founder.
    const { data: fundId, error: createErr } = await alice.client.rpc("create_fund", {
      p_group_id:            group.groupId,
      p_name:                "Bote balance e2e",
      p_target_amount_cents: 30000,
      p_currency:            "MXN",
    });
    if (createErr) throw new Error(`create_fund: ${createErr.message}`);
    const fundUuid = fundId as string;

    // 3 contributions: alice $100, bob $50, carla $50 — all into the fund.
    // from_member contributes, to_member is null (fund is the recipient but
    // funds don't have a member_id; record at resource scope is enough).
    for (const [member, cents] of [[alice, 10000], [bob, 5000], [carla, 5000]] as const) {
      const { error } = await admin.from("ledger_entries").insert({
        group_id:       group.groupId,
        resource_id:    fundUuid,
        type:           "contribution",
        amount_cents:   cents,
        currency:       "MXN",
        from_member_id: member.memberId,
        to_member_id:   null,
      });
      if (error) throw new Error(`insert contribution (${member.handle}): ${error.message}`);
    }

    // The per-resource view returns one row per contributor with net_cents
    // = -cents (they each sent money, nothing received).
    const { data: balances, error: vErr } = await admin
      .from("member_balances_per_resource")
      .select("member_id, sent_cents, received_cents, net_cents")
      .eq("resource_id", fundUuid);
    if (vErr) throw new Error(`balance view: ${vErr.message}`);

    const byMember = new Map<string, { sent: number; received: number; net: number }>();
    for (const b of (balances ?? []) as Array<{ member_id: string; sent_cents: number; received_cents: number; net_cents: number }>) {
      byMember.set(b.member_id, {
        sent: b.sent_cents, received: b.received_cents, net: b.net_cents,
      });
    }
    assertEquals(byMember.get(alice.memberId)?.net, -10000, "alice net");
    assertEquals(byMember.get(bob.memberId)?.net,   -5000,  "bob net");
    assertEquals(byMember.get(carla.memberId)?.net, -5000,  "carla net");
  } finally {
    if (group) await cleanupGroup(group);
  }
});
