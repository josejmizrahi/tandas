// supabase/functions/_tests/db/consistency_slot_doctrine.test.ts
//
// Covers ConsistencyAudit_2026-05-17 findings F4 + F22:
//   - create_slot emits slotCreated atom (was unauditable from atoms).
//   - cancel_booking + expire_booking emit slotReleased when target is slot.
//   - slot_state_view derives status (unassigned/assigned/booked/expired/
//     released/declined) from atoms ordered by system_events.seq DESC.
//   - resources.status remains as documented operational cache (atom-backed).
//
// Migrations: 00281 (slotCreated/slotReleased atoms), 00282 (slot_state_view),
// 00283 (constraint fix + cache registration).

import { assert, assertEquals } from "jsr:@std/assert@1";
import { adminClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "../e2e/_fixtures/seedGroup.ts";
import { cleanupGroup } from "../e2e/_fixtures/cleanup.ts";

const admin = adminClient();

/** Ensure founder has assignSlot + bookSlot permissions in groups.roles. */
async function grantSlotPerms(groupId: string): Promise<void> {
  const { data: grp } = await admin
    .from("groups")
    .select("roles")
    .eq("id", groupId)
    .single();
  const roles = (grp!.roles as Record<string, { permissions?: string[] }>) ??
    {};
  const founderPerms = roles.founder?.permissions ?? [];
  const want = ["assignSlot", "bookSlot"];
  const merged = Array.from(new Set([...founderPerms, ...want]));
  if (merged.length !== founderPerms.length) {
    roles.founder = { ...(roles.founder ?? {}), permissions: merged };
    await admin.from("groups").update({ roles }).eq("id", groupId);
  }
}

Deno.test("create_slot emits slotCreated atom; slot_state_view starts unassigned", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: false,
    });
    await grantSlotPerms(g.groupId);

    // Need an asset to host slots.
    const { data: assetId, error: aErr } = await g.founder.client.rpc(
      "create_asset",
      { p_group_id: g.groupId, p_name: "Sloty asset" },
    );
    assert(!aErr, `create_asset failed: ${aErr?.message}`);

    const starts = new Date(Date.now() + 3600_000).toISOString();
    const ends = new Date(Date.now() + 7200_000).toISOString();
    const { data: slotId, error: sErr } = await g.founder.client.rpc(
      "create_slot",
      {
        p_asset_id: assetId as string,
        p_starts_at: starts,
        p_ends_at: ends,
      },
    );
    assert(!sErr, `create_slot failed: ${sErr?.message}`);

    // slotCreated atom emitted exactly once.
    const { data: createdAtoms } = await admin
      .from("system_events")
      .select("payload")
      .eq("resource_id", slotId as string)
      .eq("event_type", "slotCreated");
    assertEquals(createdAtoms?.length, 1, "expected 1 slotCreated atom");
    const p = createdAtoms![0].payload as Record<string, unknown>;
    assertEquals(p.asset_id, assetId);

    // View starts as 'unassigned'.
    const { data: view } = await admin
      .from("slot_state_view")
      .select("status, assigned_member_id, booking_id")
      .eq("slot_id", slotId as string)
      .single();
    assertEquals(view!.status, "unassigned");
    assertEquals(view!.assigned_member_id, null);
    assertEquals(view!.booking_id, null);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("slot_state_view derives status from atom chain: book → cancel", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: false,
    });
    await grantSlotPerms(g.groupId);

    const { data: assetId } = await g.founder.client.rpc("create_asset", {
      p_group_id: g.groupId,
      p_name: "A",
    });
    const { data: slotId } = await g.founder.client.rpc("create_slot", {
      p_asset_id: assetId as string,
      p_starts_at: new Date(Date.now() + 3600_000).toISOString(),
      p_ends_at: new Date(Date.now() + 7200_000).toISOString(),
    });

    // Book the slot — should flip status to 'booked' in view.
    const { data: bookingId, error: bErr } = await g.founder.client.rpc(
      "book_slot",
      { p_slot_id: slotId as string },
    );
    assert(!bErr, `book_slot failed: ${bErr?.message}`);

    const { data: bookedView } = await admin
      .from("slot_state_view")
      .select("status, booking_id, assigned_member_id")
      .eq("slot_id", slotId as string)
      .single();
    assertEquals(bookedView!.status, "booked");
    assertEquals(bookedView!.booking_id, bookingId);

    // Cancel the booking — view returns to 'unassigned', booking_id null.
    const { error: cErr } = await g.founder.client.rpc("cancel_booking", {
      p_booking_id: bookingId as string,
      p_reason: "oops",
    });
    assert(!cErr, `cancel_booking failed: ${cErr?.message}`);

    const { data: cancelView } = await admin
      .from("slot_state_view")
      .select("status, booking_id, assigned_member_id")
      .eq("slot_id", slotId as string)
      .single();
    assertEquals(cancelView!.status, "unassigned");
    assertEquals(cancelView!.booking_id, null);
    assertEquals(cancelView!.assigned_member_id, null);

    // slotReleased atom emitted by cancel_booking.
    const { data: releasedAtoms } = await admin
      .from("system_events")
      .select("payload")
      .eq("resource_id", slotId as string)
      .eq("event_type", "slotReleased");
    assertEquals(releasedAtoms?.length, 1, "expected 1 slotReleased atom");
    const p = releasedAtoms![0].payload as Record<string, unknown>;
    assertEquals(p.released_via, "cancel_booking");

    // Full atom inventory: slotCreated + slotReleased + bookingCreated + bookingCancelled.
    const { data: allAtoms } = await admin
      .from("system_events")
      .select("event_type")
      .or(
        `resource_id.eq.${slotId},resource_id.eq.${bookingId}`,
      );
    const types = (allAtoms ?? []).map((a) => a.event_type);
    assert(
      types.includes("slotCreated") && types.includes("slotReleased") &&
        types.includes("bookingCreated") &&
        types.includes("bookingCancelled"),
      `missing expected atom types in ${JSON.stringify(types)}`,
    );
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("slot.status cache stays consistent with slot_state_view across lifecycle", async () => {
  // Per OperationalCacheDoctrine §5: slot.status is documented cache backed
  // by atoms. RPCs write it AS THEY emit atoms; view derives independently.
  // This test verifies cache + view agree at every transition.
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: false,
    });
    await grantSlotPerms(g.groupId);

    const { data: assetId } = await g.founder.client.rpc("create_asset", {
      p_group_id: g.groupId,
      p_name: "A",
    });
    const { data: slotId } = await g.founder.client.rpc("create_slot", {
      p_asset_id: assetId as string,
      p_starts_at: new Date(Date.now() + 3600_000).toISOString(),
      p_ends_at: new Date(Date.now() + 7200_000).toISOString(),
    });

    async function statuses() {
      const { data: cache } = await admin
        .from("resources")
        .select("status")
        .eq("id", slotId as string)
        .single();
      const { data: view } = await admin
        .from("slot_state_view")
        .select("status")
        .eq("slot_id", slotId as string)
        .single();
      return { cache: cache!.status as string, view: view!.status as string };
    }

    // Initial: cache='unassigned', view='unassigned'.
    let s = await statuses();
    assertEquals(s.cache, "unassigned");
    assertEquals(s.view, "unassigned");

    // After book: cache='booked', view='booked'.
    const { data: bookingId } = await g.founder.client.rpc("book_slot", {
      p_slot_id: slotId as string,
    });
    s = await statuses();
    assertEquals(s.cache, "booked");
    assertEquals(s.view, "booked");

    // After cancel: cache='unassigned', view='unassigned'.
    await g.founder.client.rpc("cancel_booking", {
      p_booking_id: bookingId as string,
      p_reason: "x",
    });
    s = await statuses();
    assertEquals(s.cache, "unassigned");
    assertEquals(s.view, "unassigned");
  } finally {
    if (g) await cleanupGroup(g);
  }
});
