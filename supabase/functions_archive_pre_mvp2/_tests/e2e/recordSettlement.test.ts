// Tier 6 final (mig 00145) acceptance: record_settlement RPC.
//
// Happy path:
//   - alice paid $100 expense for the group → group "owes" alice $100
//   - alice settles $50 to bob → alice's debt to bob registered;
//     balance views reflect the shift.
//
// Validation tests:
//   - amount = 0 raises
//   - missing from_member raises
//   - missing to_member raises
//   - from = to raises (no self-settlement)
//   - non-member of the group raises

import { assertEquals, assertExists, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";

const admin = adminClient();

async function callSettlement(
  client: SeededGroup["founder"]["client"],
  args: {
    groupId: string;
    fromMemberId: string | null;
    toMemberId: string | null;
    amountCents: number;
    currency?: string;
    resourceId?: string | null;
    note?: string | null;
  },
) {
  return await client.rpc("record_settlement", {
    p_group_id:       args.groupId,
    p_from_member_id: args.fromMemberId,
    p_to_member_id:   args.toMemberId,
    p_amount_cents:   args.amountCents,
    p_currency:       args.currency ?? "MXN",
    p_resource_id:    args.resourceId ?? null,
    p_note:           args.note ?? null,
  });
}

Deno.test("Tier 6 final: record_settlement happy path + balance view reflects", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const [alice, bob] = group.members;

    // Pre-state: alice paid $100 expense for the group (from=alice, to=null).
    const { error: expErr } = await admin.from("ledger_entries").insert({
      group_id:       group.groupId,
      resource_id:    null,
      type:           "expense",
      amount_cents:   10000,
      currency:       "MXN",
      from_member_id: alice.memberId,
      to_member_id:   null,
    });
    if (expErr) throw new Error(`expense insert: ${expErr.message}`);

    // Settlement: bob pays alice $40 (partial payback).
    const { data, error } = await callSettlement(alice.client, {
      groupId:      group.groupId,
      fromMemberId: bob.memberId,
      toMemberId:   alice.memberId,
      amountCents:  4000,
      note:         "Le pago lo del taxi",
    });
    if (error) throw new Error(`record_settlement: ${error.message}`);
    const row = data as Record<string, unknown>;
    assertEquals(row.type, "settlement");
    assertEquals(row.amount_cents, 4000);
    assertEquals(row.from_member_id, bob.memberId);
    assertEquals(row.to_member_id,   alice.memberId);
    const metadata = row.metadata as Record<string, unknown>;
    assertEquals(metadata.note, "Le pago lo del taxi");

    // Balance view: alice net = received 4000 - sent 10000 = -6000.
    // bob net = received 0 - sent 4000 = -4000.
    const { data: balances } = await admin
      .from("member_balances_per_group")
      .select("member_id, net_cents")
      .eq("group_id", group.groupId);
    const byMember = new Map<string, number>();
    for (const b of (balances ?? []) as Array<{ member_id: string; net_cents: number }>) {
      byMember.set(b.member_id, b.net_cents);
    }
    assertEquals(byMember.get(alice.memberId), -6000, "alice net after settle");
    assertEquals(byMember.get(bob.memberId),   -4000, "bob net after settle");
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 6 final: record_settlement rejects zero / negative / missing-side / self-settle / cross-group", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const [alice, bob] = group.members;

    // amount = 0
    const r1 = await callSettlement(alice.client, {
      groupId: group.groupId, fromMemberId: bob.memberId, toMemberId: alice.memberId, amountCents: 0,
    });
    assertExists(r1.error, "amount=0 must error");

    // negative amount
    const r2 = await callSettlement(alice.client, {
      groupId: group.groupId, fromMemberId: bob.memberId, toMemberId: alice.memberId, amountCents: -100,
    });
    assertExists(r2.error, "negative amount must error");

    // missing from
    const r3 = await callSettlement(alice.client, {
      groupId: group.groupId, fromMemberId: null, toMemberId: alice.memberId, amountCents: 1000,
    });
    assertExists(r3.error, "missing from must error");

    // missing to
    const r4 = await callSettlement(alice.client, {
      groupId: group.groupId, fromMemberId: bob.memberId, toMemberId: null, amountCents: 1000,
    });
    assertExists(r4.error, "missing to must error");

    // self-settle (from = to)
    const r5 = await callSettlement(alice.client, {
      groupId: group.groupId, fromMemberId: alice.memberId, toMemberId: alice.memberId, amountCents: 500,
    });
    assertExists(r5.error, "self-settle must error");

    // Cross-group: seed a second group, try to settle with its member.
    const otherGroup = await seedGroup({
      memberSpecs: [{ handle: "outsider" }],
      seedDinnerRules: false,
    });
    try {
      const r6 = await callSettlement(alice.client, {
        groupId: group.groupId,
        fromMemberId: alice.memberId,
        toMemberId:   otherGroup.founder.memberId,  // belongs to different group
        amountCents:  1000,
      });
      assertExists(r6.error, "cross-group to_member must error");
    } finally {
      await cleanupGroup(otherGroup);
    }
  } finally {
    if (group) await cleanupGroup(group);
  }
});
