// Phase 2 Slice 2.5 — Palco scenario E2E.
//
// Validates the Roadmap §3 Fase 2 slogan: "una familia de 5 crea un
// palco → admin asigna 17 partidos → un miembro rechaza → multa se
// aplica → otro pide swap → vote".
//
// Success criterion (canonical Phase 2 metric): the test should drive
// the entire scenario through public RPCs + the polymorphic resources
// table without requiring any per-vertical platform code. ResourceRow
// (slot/asset/booking) + the rule engine evaluators (Slice 2.1) +
// the slot-expired emitter (Slice 2.2) + the lifecycle RPCs (Slice 2.3)
// + the rule + vote primitives have to compose end-to-end.
//
// Walks the canonical chain:
//   1. Founder creates a shared_resource group (auto-seeds modules,
//      defaultRules incl. shared_no_show, defaultRoles).
//   2. Founder creates Asset "Palco Estadio Azteca" with capacity 5.
//   3. Founder creates 17 slot resources under that asset.
//   4. Founder assigns each slot to a rotating family member.
//   5. One family member's slot is left without booking, then ends_at
//      is forced into the past + slot.status reset so the cron picks it.
//   6. emit-slot-system-events cron emits a slotExpired system_event.
//   7. process-system-events cron picks it up, evaluates shared_no_show
//      rule (slotIsUnassigned condition + fine consequence) → fines the
//      assigned holder.
//   8. Another family member calls request_slot_swap on a different
//      slot, opening a vote.
//
// Cleanup is robust: cleanupGroup tears down everything via cascade.
//
// Run prerequisites: see supabase/functions/_tests/README.md (local
// supabase running, env vars set).

import { assertEquals, assert } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";
import { invokeCron } from "./_fixtures/invokeCron.ts";

const admin = adminClient();

Deno.test("palco shared_resource scenario — 5 family members, 17 slots, 1 no-show fined, 1 swap vote opened", async () => {
  let group: SeededGroup | null = null;
  try {
    // ────────────────────────────────────────────────────────────────
    // STEP 1: Family of 5 creates a shared_resource group.
    //   create_group_with_admin reads templates.config (mig 00066) and
    //   auto-seeds defaultModules + defaultRules + defaultRoles via
    //   seed_template_rules (mig 00062) + seed_template_roles (mig 00067).
    // ────────────────────────────────────────────────────────────────
    group = await seedGroup({
      memberSpecs: [
        { handle: "papa" },     // founder/admin
        { handle: "mama" },
        { handle: "hijo1" },
        { handle: "hija1" },
        { handle: "hijo2" },
      ],
      baseTemplate: "shared_resource",
    });
    const [papa, mama, hijo1, hija1, hijo2] = group.members;

    // Sanity: shared_no_show rule was seeded into public.rules via
    // seed_template_rules (driven by templates.config.defaultRules).
    const { data: seededRules } = await admin
      .from("rules")
      .select("slug, is_active, trigger, conditions, consequences")
      .eq("group_id", group.groupId)
      .eq("slug", "shared_no_show")
      .single();
    assert(seededRules, "shared_no_show rule must be seeded by template");
    assertEquals((seededRules.trigger as { eventType: string }).eventType, "slotExpired");
    assertEquals(seededRules.is_active, true);

    // ────────────────────────────────────────────────────────────────
    // STEP 2: Founder creates the asset (palco).
    // ────────────────────────────────────────────────────────────────
    const { data: assetId, error: assetErr } = await papa.client.rpc("create_asset", {
      p_group_id: group.groupId,
      p_name: "Palco Estadio Azteca",
      p_capacity: 5,
    });
    if (assetErr) throw new Error(`create_asset failed: ${assetErr.message}`);
    assert(typeof assetId === "string", "create_asset must return uuid");

    // ────────────────────────────────────────────────────────────────
    // STEP 3 + 4: Founder creates 17 slots and assigns each to a
    // rotating family member.
    // ────────────────────────────────────────────────────────────────
    const PARTIDOS = 17;
    const family = [papa, mama, hijo1, hija1, hijo2];
    const now = Date.now();
    const slotIds: string[] = [];
    for (let i = 0; i < PARTIDOS; i++) {
      const startsAt = new Date(now + (i + 1) * 86_400_000);  // +1d, +2d, ...
      const endsAt   = new Date(startsAt.getTime() + 3 * 3_600_000);
      const { data: slotId, error: slotErr } = await papa.client.rpc("create_slot", {
        p_asset_id: assetId,
        p_starts_at: startsAt.toISOString(),
        p_ends_at: endsAt.toISOString(),
      });
      if (slotErr) throw new Error(`create_slot[${i}] failed: ${slotErr.message}`);
      slotIds.push(slotId as string);

      const holder = family[i % family.length];
      const { error: assignErr } = await papa.client.rpc("assign_slot", {
        p_slot_id: slotId,
        p_member_id: holder.memberId,
      });
      if (assignErr) throw new Error(`assign_slot[${i}] failed: ${assignErr.message}`);
    }

    // 17 slot resources persisted, all status='assigned'.
    const { data: slotsCheck } = await admin
      .from("resources")
      .select("id, status")
      .eq("group_id", group.groupId)
      .eq("resource_type", "slot");
    assertEquals(slotsCheck?.length, PARTIDOS);
    assert(slotsCheck?.every((r) => r.status === "assigned"));

    // ────────────────────────────────────────────────────────────────
    // STEP 5: One member rejects their slot — i.e., it ends without
    // a booking attached. Force one slot's ends_at into the past +
    // status back to 'assigned' (the cron will flip it on emission).
    // ────────────────────────────────────────────────────────────────
    const expiredSlotId = slotIds[2]; // hijo1's slot (index 2 % 5 == 2)
    const yesterday = new Date(now - 24 * 3_600_000);
    const yesterdayPlus3 = new Date(yesterday.getTime() + 3 * 3_600_000);

    // Patch via service role (the RPC layer doesn't expose ends_at edits).
    const { data: expiredRow } = await admin
      .from("resources")
      .select("metadata")
      .eq("id", expiredSlotId)
      .single();
    const metadata = expiredRow?.metadata as Record<string, unknown>;
    metadata.starts_at = yesterday.toISOString();
    metadata.ends_at = yesterdayPlus3.toISOString();
    await admin.from("resources").update({ metadata }).eq("id", expiredSlotId);

    // ────────────────────────────────────────────────────────────────
    // STEP 6: emit-slot-system-events cron emits slotExpired event.
    // Real cron fires every 5 min; for the test we invoke directly.
    // ────────────────────────────────────────────────────────────────
    const emitResp = await invokeCron("emit-slot-system-events");
    assertEquals(emitResp.ok, true, "emit-slot-system-events must return 2xx");
    const emitBody = emitResp.body as { emitted?: number; scanned?: number };
    assert((emitBody.emitted ?? 0) >= 1, "must emit ≥1 slotExpired event");

    const { data: emittedEvents } = await admin
      .from("system_events")
      .select("id, event_type, resource_id, payload")
      .eq("group_id", group.groupId)
      .eq("event_type", "slotExpired");
    assertEquals(emittedEvents?.length, 1);
    assertEquals(emittedEvents?.[0].resource_id, expiredSlotId);

    // ────────────────────────────────────────────────────────────────
    // STEP 7: process-system-events runs the engine. shared_no_show
    // rule fires: slotExpired trigger evaluator returns 1 target
    // (the assigned holder = hijo1), slotIsUnassigned condition reads
    // booking_id=null on payload → true, fine consequence proposes
    // a fine for hijo1.
    // ────────────────────────────────────────────────────────────────
    const procResp = await invokeCron("process-system-events");
    assertEquals(procResp.ok, true, "process-system-events must return 2xx");

    // hijo1 gets a fine row (auto_generated=true, status='proposed').
    const { data: fines } = await admin
      .from("fines")
      .select("id, user_id, amount, status, reason, auto_generated, resource_id")
      .eq("group_id", group.groupId);
    assertEquals(fines?.length, 1, "exactly one fine must be proposed");
    assertEquals(fines?.[0].user_id, hijo1.userId);
    assertEquals(fines?.[0].auto_generated, true);
    assertEquals(fines?.[0].resource_id, expiredSlotId);

    // ────────────────────────────────────────────────────────────────
    // STEP 8: Another member (mama) requests a swap of HER slot
    // (index 1 % 5 == 1) to hija1. Opens a vote of type 'slot_swap'.
    // ────────────────────────────────────────────────────────────────
    const mamasSlotId = slotIds[1];
    const { data: voteId, error: swapErr } = await mama.client.rpc("request_slot_swap", {
      p_slot_id: mamasSlotId,
      p_target_member_id: hija1.memberId,
    });
    if (swapErr) throw new Error(`request_slot_swap failed: ${swapErr.message}`);
    assert(typeof voteId === "string");

    // Vote of type slot_swap opened, all 5 family members eligible to vote.
    const { data: votes } = await admin
      .from("votes")
      .select("id, vote_type, status, reference_id, payload")
      .eq("id", voteId);
    assertEquals(votes?.length, 1);
    assertEquals(votes?.[0].vote_type, "slot_swap");
    assertEquals(votes?.[0].status, "open");
    assertEquals(votes?.[0].reference_id, mamasSlotId);
    const votePayload = votes?.[0].payload as Record<string, unknown>;
    assertEquals(votePayload.from_member_id, mama.memberId);
    assertEquals(votePayload.to_member_id, hija1.memberId);

    const { data: ballots } = await admin
      .from("vote_casts")
      .select("member_id, choice")
      .eq("vote_id", voteId);
    assertEquals(ballots?.length, family.length);
    assert(ballots?.every((b) => b.choice === "pending"));

    // ────────────────────────────────────────────────────────────────
    // SLOGAN VERIFIED — 6 system events tell the story.
    // ────────────────────────────────────────────────────────────────
    const { data: events } = await admin
      .from("system_events")
      .select("event_type")
      .eq("group_id", group.groupId)
      .order("occurred_at", { ascending: true });

    const eventCounts = new Map<string, number>();
    for (const e of events ?? []) {
      eventCounts.set(e.event_type, (eventCounts.get(e.event_type) ?? 0) + 1);
    }

    // assetCreated × 1 + slotAssigned × 17 + slotExpired × 1 +
    // slotSwapRequested × 1 + voteOpened × 1.
    assertEquals(eventCounts.get("assetCreated"), 1);
    assertEquals(eventCounts.get("slotAssigned"), PARTIDOS);
    assertEquals(eventCounts.get("slotExpired"), 1);
    assertEquals(eventCounts.get("slotSwapRequested"), 1);
    assertEquals(eventCounts.get("voteOpened"), 1);
  } finally {
    if (group) await cleanupGroup(group);
  }
});
