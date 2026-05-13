// Tier 6 slice 19b (mig 00140) acceptance: contribution into a fund
// fires fundDeposit; non-contribution + non-fund inflows don't.
//
// Three scenarios:
//   1. Positive: contribution against a fund → exactly one fundDeposit
//      system_event with the expected payload.
//   2. Negative type: payout against the same fund (money flowing OUT)
//      doesn't fire fundDeposit.
//   3. Negative scope: contribution against an event resource (not a
//      fund) doesn't fire fundDeposit — the semantic is "deposit INTO
//      a fund", not generic ledger inflow.

import { assertEquals, assertExists } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";

const admin = adminClient();

async function createFund(group: SeededGroup, name: string): Promise<string> {
  const { data, error } = await group.founder.client.rpc("create_fund", {
    p_group_id:            group.groupId,
    p_name:                name,
    p_target_amount_cents: null,
    p_currency:            "MXN",
  });
  if (error) throw new Error(`create_fund: ${error.message}`);
  return data as string;
}

async function insertLedgerEntry(args: {
  groupId: string;
  resourceId: string | null;
  type: string;
  amountCents: number;
  fromMemberId: string | null;
  toMemberId: string | null;
}) {
  const { error } = await admin.from("ledger_entries").insert({
    group_id:       args.groupId,
    resource_id:    args.resourceId,
    type:           args.type,
    amount_cents:   args.amountCents,
    currency:       "MXN",
    from_member_id: args.fromMemberId,
    to_member_id:   args.toMemberId,
  });
  if (error) throw new Error(`ledger_entries insert (${args.type}): ${error.message}`);
}

async function fundDepositsFor(resourceId: string) {
  const { data, error } = await admin
    .from("system_events")
    .select("id, payload, resource_id")
    .eq("event_type", "fundDeposit")
    .eq("resource_id", resourceId);
  if (error) throw new Error(`system_events fetch: ${error.message}`);
  return (data ?? []) as Array<{ id: string; payload: Record<string, unknown>; resource_id: string }>;
}

Deno.test("Tier 6.19b: contribution into a fund fires fundDeposit", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const fundId = await createFund(group, "Bote año nuevo");

    await insertLedgerEntry({
      groupId:      group.groupId,
      resourceId:   fundId,
      type:         "contribution",
      amountCents:  12500,  // $125 MXN
      fromMemberId: group.members[0].memberId,
      toMemberId:   null,
    });

    const events = await fundDepositsFor(fundId);
    assertEquals(events.length, 1, "exactly one fundDeposit emit");
    const payload = events[0].payload;
    assertEquals(payload.amount_cents,     12500, "payload.amount_cents");
    assertEquals(payload.currency,         "MXN", "payload.currency");
    assertEquals(payload.from_member_id,   group.members[0].memberId, "payload.from_member_id");
    assertEquals(payload.fund_resource_id, fundId, "payload.fund_resource_id");
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 6.19b: payout against the same fund does NOT fire fundDeposit", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const fundId = await createFund(group, "Bote test payout");

    await insertLedgerEntry({
      groupId:      group.groupId,
      resourceId:   fundId,
      type:         "payout",
      amountCents:  5000,
      fromMemberId: null,
      toMemberId:   group.members[1].memberId,
    });

    const events = await fundDepositsFor(fundId);
    assertEquals(events.length, 0, "payout must not emit fundDeposit");
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 6.19b: contribution against an event (non-fund) does NOT fire fundDeposit", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });

    // Build an event resource — not a fund.
    const startsAt = new Date(Date.now() + 24 * 3_600_000);
    const { data: result, error: cErr } = await group.founder.client.rpc(
      "create_event_v2",
      {
        p_group_id:        group.groupId,
        p_title:           "Cena no-fund test",
        p_starts_at:       startsAt.toISOString(),
        p_duration_minutes: 180,
      },
    );
    if (cErr) throw new Error(`create_event_v2: ${cErr.message}`);
    const eventId = (result as { id?: string })?.id ?? (result as unknown as string);
    if (typeof eventId !== "string") throw new Error("no event id");

    await insertLedgerEntry({
      groupId:      group.groupId,
      resourceId:   eventId,
      type:         "contribution",
      amountCents:  8000,
      fromMemberId: group.members[0].memberId,
      toMemberId:   null,
    });

    // fundDeposit is keyed off the fund's resource_id; an event would
    // never appear as the resource_id of a fundDeposit row. Query
    // broadly by group_id to be defensive.
    const { data, error } = await admin
      .from("system_events")
      .select("id, resource_id")
      .eq("event_type", "fundDeposit")
      .eq("group_id", group.groupId);
    if (error) throw new Error(`system_events fetch: ${error.message}`);
    assertEquals(data?.length ?? 0, 0, "contribution to event must not emit fundDeposit");
  } finally {
    if (group) await cleanupGroup(group);
  }
});
