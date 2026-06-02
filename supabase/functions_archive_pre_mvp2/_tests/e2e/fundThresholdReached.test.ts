// Tier 6 slice 19c (mig 00141) acceptance: fundThresholdReached fires
// once when cumulative deposits cross target_amount_cents.
//
// Four scenarios:
//   1. Deposits below target → no fundThresholdReached emit.
//   2. Deposit that crosses target → exactly one fundThresholdReached
//      with the right payload (target + accumulated + currency).
//   3. Subsequent deposits past target → still only one emit total
//      (once-per-fund semantics).
//   4. Fund with no target → never emits fundThresholdReached even
//      when arbitrary amounts get deposited.

import { assertEquals, assertExists } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";

const admin = adminClient();

async function createFundWithTarget(
  group: SeededGroup,
  name: string,
  targetCents: number | null,
): Promise<string> {
  const { data, error } = await group.founder.client.rpc("create_fund", {
    p_group_id:            group.groupId,
    p_name:                name,
    p_target_amount_cents: targetCents,
    p_currency:            "MXN",
  });
  if (error) throw new Error(`create_fund: ${error.message}`);
  return data as string;
}

async function contribute(args: {
  groupId: string;
  fundId: string;
  amountCents: number;
  fromMemberId: string;
}) {
  const { error } = await admin.from("ledger_entries").insert({
    group_id:       args.groupId,
    resource_id:    args.fundId,
    type:           "contribution",
    amount_cents:   args.amountCents,
    currency:       "MXN",
    from_member_id: args.fromMemberId,
    to_member_id:   null,
  });
  if (error) throw new Error(`contribute insert: ${error.message}`);
}

async function thresholdEventsFor(fundId: string) {
  const { data, error } = await admin
    .from("system_events")
    .select("id, payload")
    .eq("event_type", "fundThresholdReached")
    .eq("resource_id", fundId);
  if (error) throw new Error(`system_events fetch: ${error.message}`);
  return (data ?? []) as Array<{ id: string; payload: Record<string, unknown> }>;
}

Deno.test("Tier 6.19c: deposits below target do NOT emit fundThresholdReached", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const fundId = await createFundWithTarget(group, "Bote $200", 20000);

    // Two $50 contributions = $100 total, half the target.
    await contribute({ groupId: group.groupId, fundId, amountCents: 5000, fromMemberId: group.members[0].memberId });
    await contribute({ groupId: group.groupId, fundId, amountCents: 5000, fromMemberId: group.members[1].memberId });

    const events = await thresholdEventsFor(fundId);
    assertEquals(events.length, 0, "no threshold emit below target");
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 6.19c: deposit crossing target emits fundThresholdReached once with payload", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const target = 20000; // $200
    const fundId = await createFundWithTarget(group, "Bote crossing", target);

    // $50 + $50 → $100 (below)
    await contribute({ groupId: group.groupId, fundId, amountCents: 5000, fromMemberId: group.members[0].memberId });
    await contribute({ groupId: group.groupId, fundId, amountCents: 5000, fromMemberId: group.members[1].memberId });
    assertEquals((await thresholdEventsFor(fundId)).length, 0, "still no emit at $100");

    // $150 → total $250 (crosses the $200 target)
    await contribute({ groupId: group.groupId, fundId, amountCents: 15000, fromMemberId: group.members[0].memberId });

    const events = await thresholdEventsFor(fundId);
    assertEquals(events.length, 1, "exactly one threshold emit on the crossing contribution");
    const payload = events[0].payload;
    assertEquals(payload.fund_resource_id,    fundId, "payload.fund_resource_id");
    assertEquals(payload.target_amount_cents, target, "payload.target_amount_cents");
    assertEquals(payload.accumulated_cents,   25000,  "payload.accumulated_cents (sum at the time of emit)");
    assertEquals(payload.currency,            "MXN",  "payload.currency");
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 6.19c: post-cross deposits do NOT re-emit fundThresholdReached", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const fundId = await createFundWithTarget(group, "Bote post-cross", 10000);

    // Cross immediately ($150 > $100 target).
    await contribute({ groupId: group.groupId, fundId, amountCents: 15000, fromMemberId: group.members[0].memberId });
    assertEquals((await thresholdEventsFor(fundId)).length, 1, "first emit");

    // Two more deposits — must NOT re-emit.
    await contribute({ groupId: group.groupId, fundId, amountCents: 5000, fromMemberId: group.members[1].memberId });
    await contribute({ groupId: group.groupId, fundId, amountCents: 5000, fromMemberId: group.members[0].memberId });
    assertEquals((await thresholdEventsFor(fundId)).length, 1, "still exactly one — dedup gate held");
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 6.19c: fund without a target never emits fundThresholdReached", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const fundId = await createFundWithTarget(group, "Bote sin meta", null);

    // Arbitrary contributions — no target means no threshold logic.
    await contribute({ groupId: group.groupId, fundId, amountCents: 100000, fromMemberId: group.members[0].memberId });
    await contribute({ groupId: group.groupId, fundId, amountCents: 200000, fromMemberId: group.members[1].memberId });

    assertEquals((await thresholdEventsFor(fundId)).length, 0, "no target → no threshold emit");
  } finally {
    if (group) await cleanupGroup(group);
  }
});
