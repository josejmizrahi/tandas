// Tier 6 slice 18 (mig 00136) acceptance: balance projection views.
//
// Inserts 3 ledger entries into a fresh group and asserts that both
// `member_balances_per_group` and `member_balances_per_resource`
// return the expected nets.
//
// Setup:
//   - alice (founder), bob, carla — all members of the group
//   - resourceA = scratch event created via create_event_v2
//
// Entries (all MXN):
//   1. expense $200  from alice  to (null)  resource=A
//   2. expense $150  from alice  to (null)  resource=A
//   3. settlement $50 from bob  to alice    resource=A
//
// Expected nets per member:
//   alice: received 50 - sent 350 = -300  (alice spent 350 for the group, bob settled 50 back)
//   bob:   received 0  - sent 50  = -50   (bob paid alice 50)
//   carla: not in any entry        = absent
//
// Both views (per_group and per_resource) should return the same
// numbers since all entries are resource-scoped.

import { assertEquals, assertExists } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";

const admin = adminClient();

interface BalanceRow {
  group_id?: string;
  resource_id?: string;
  member_id: string;
  currency: string;
  sent_cents: number;
  received_cents: number;
  net_cents: number;
}

async function insertEntry(args: {
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

Deno.test("Tier 6: balance projection views compute correct per-member nets", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }, { handle: "carla" }],
      seedDinnerRules: false,
    });
    const [alice, bob, carla] = group.members;

    // Create a resource (event) to attach the entries to.
    const startsAt = new Date(Date.now() + 24 * 3_600_000);
    const { data: createResult, error: createErr } = await alice.client.rpc(
      "create_event_v2",
      {
        p_group_id:        group.groupId,
        p_title:           "Cena balance test",
        p_starts_at:       startsAt.toISOString(),
        p_duration_minutes: 180,
      },
    );
    if (createErr) throw new Error(`create_event_v2: ${createErr.message}`);
    const eventId = (createResult as { id?: string })?.id ?? (createResult as unknown as string);
    if (typeof eventId !== "string") {
      throw new Error(`create_event_v2 returned no id: ${JSON.stringify(createResult)}`);
    }

    // Insert the 3 ledger entries via service-role (bypass RLS).
    await insertEntry({
      groupId:        group.groupId,
      resourceId:     eventId,
      type:           "expense",
      amountCents:    20_000,
      fromMemberId:   alice.memberId,
      toMemberId:     null,
    });
    await insertEntry({
      groupId:        group.groupId,
      resourceId:     eventId,
      type:           "expense",
      amountCents:    15_000,
      fromMemberId:   alice.memberId,
      toMemberId:     null,
    });
    await insertEntry({
      groupId:        group.groupId,
      resourceId:     eventId,
      type:           "settlement",
      amountCents:    5_000,
      fromMemberId:   bob.memberId,
      toMemberId:     alice.memberId,
    });

    // Fetch the group-level view.
    const { data: groupBalances, error: gErr } = await admin
      .from("member_balances_per_group")
      .select("member_id, currency, sent_cents, received_cents, net_cents")
      .eq("group_id", group.groupId);
    if (gErr) throw new Error(`member_balances_per_group: ${gErr.message}`);

    const byMember = new Map<string, BalanceRow>();
    for (const row of (groupBalances ?? []) as BalanceRow[]) {
      byMember.set(row.member_id, row);
    }

    // alice net: received 5000 - sent (20000+15000) = -30000
    const aliceRow = byMember.get(alice.memberId);
    assertExists(aliceRow, "alice must have a group balance row");
    assertEquals(aliceRow!.sent_cents, 35_000, "alice.sent");
    assertEquals(aliceRow!.received_cents, 5_000, "alice.received");
    assertEquals(aliceRow!.net_cents, -30_000, "alice.net");
    assertEquals(aliceRow!.currency, "MXN");

    // bob net: received 0 - sent 5000 = -5000
    const bobRow = byMember.get(bob.memberId);
    assertExists(bobRow, "bob must have a group balance row");
    assertEquals(bobRow!.sent_cents, 5_000, "bob.sent");
    assertEquals(bobRow!.received_cents, 0, "bob.received");
    assertEquals(bobRow!.net_cents, -5_000, "bob.net");

    // carla should be absent — no entries involve her.
    assertEquals(byMember.has(carla.memberId), false, "carla has no balance row");

    // Resource-scoped view should return the same nets since every
    // entry was attached to the same eventId.
    const { data: resourceBalances, error: rErr } = await admin
      .from("member_balances_per_resource")
      .select("member_id, currency, sent_cents, received_cents, net_cents")
      .eq("resource_id", eventId);
    if (rErr) throw new Error(`member_balances_per_resource: ${rErr.message}`);

    const byMemberResource = new Map<string, BalanceRow>();
    for (const row of (resourceBalances ?? []) as BalanceRow[]) {
      byMemberResource.set(row.member_id, row);
    }
    assertEquals(byMemberResource.get(alice.memberId)?.net_cents, -30_000);
    assertEquals(byMemberResource.get(bob.memberId)?.net_cents, -5_000);
    assertEquals(byMemberResource.has(carla.memberId), false);
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 6: balance views ignore group-level entries from the resource scope", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const [alice, bob] = group.members;

    // Group-level entry (no resource_id): alice → bob $100
    await insertEntry({
      groupId:        group.groupId,
      resourceId:     null,
      type:           "settlement",
      amountCents:    10_000,
      fromMemberId:   alice.memberId,
      toMemberId:     bob.memberId,
    });

    // Group view: both members have rows.
    const { data: groupRows } = await admin
      .from("member_balances_per_group")
      .select("member_id, net_cents")
      .eq("group_id", group.groupId);
    const groupMap = new Map<string, number>();
    for (const r of (groupRows ?? []) as Array<{ member_id: string; net_cents: number }>) {
      groupMap.set(r.member_id, r.net_cents);
    }
    assertEquals(groupMap.get(alice.memberId), -10_000);
    assertEquals(groupMap.get(bob.memberId),   10_000);

    // Resource view: NO rows because the entry has resource_id = null.
    // Pick any random uuid — there's no resource to attach to.
    const fakeResourceId = crypto.randomUUID();
    const { data: resourceRows } = await admin
      .from("member_balances_per_resource")
      .select("member_id")
      .eq("resource_id", fakeResourceId);
    assertEquals(resourceRows?.length ?? 0, 0, "resource view excludes group-level entries");
  } finally {
    if (group) await cleanupGroup(group);
  }
});
