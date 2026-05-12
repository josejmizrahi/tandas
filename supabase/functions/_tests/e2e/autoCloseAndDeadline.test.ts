// auto-close + deadline + appeal causal chain E2E.
//
// Covers the three blockers fixed by migs 00123/00124 + edge fns:
//
//   Fix #1 — auto-close-events emits eventClosed → rule engine fires.
//   Fix #2 — rsvpDeadlinePassed has a trigger evaluator in ruleEngine.
//   Fix #3 — finalize_vote on fine_appeal mutates fines.status:
//              passed → voided + waived
//              failed/quorum_failed → officialized (recovers from
//              in_appeal limbo introduced by start_fine_appeal).
//
// Scenario:
//   3 members: alice (founder + host), bob (will be fined), carla.
//   1 event in the past, RSVP deadline passed, bob never responded.
//
//   1. emit-deadline-events → rsvpDeadlinePassed → rule "no confirmó
//      a tiempo" fires for bob (responseStatusIs("pending")).
//   2. Bob starts an appeal via start_fine_appeal → fine.status flips
//      to 'in_appeal'.
//   3. Alice + Carla vote in_favor (passed).
//   4. finalize-votes → finalize_vote → fines.status='voided'.
//   5. Causal chain: rsvpDeadlinePassed → fineOfficialized →
//      appealCreated → voteOpened → voteCast → voteResolved →
//      appealResolved.
//   6. Inbox cleared: finePending + appealVotePending UserActions
//      resolved.
//
// Skipped in the same test: the auto-close-events emit. Covered by a
// separate test below to keep failure isolation clean.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";
import { invokeCron } from "./_fixtures/invokeCron.ts";
import {
  assertCausalChain,
  assertFineState,
  assertVoteResolution,
} from "./_fixtures/assertions.ts";

const admin = adminClient();

// =============================================================================
// 1. deadline → fine → appeal → vote passed → fine voided + inbox cleared
// =============================================================================

Deno.test("rsvpDeadlinePassed → fine → start_fine_appeal → vote passed → fines.status=voided", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [
        { handle: "alice" },   // founder + host
        { handle: "bob" },     // never RSVPs
        { handle: "carla" },
      ],
      seedDinnerRules: true,
    });
    const [alice, bob, carla] = group.members;

    // Activate ONLY the "no confirmó a tiempo" rule — keeps the assertion
    // surface focused on the deadline trigger. The seeded rule uses
    // trigger=eventClosed by default in the legacy template, so we patch
    // it to rsvpDeadlinePassed for this test. If the template ships with
    // rsvpDeadlinePassed natively the patch is a no-op.
    await admin.from("rules")
      .update({ is_active: false })
      .eq("group_id", group.groupId);

    const { data: existing } = await admin
      .from("rules")
      .select("id, trigger")
      .eq("group_id", group.groupId)
      .ilike("name", "%confirm%a tiempo%")
      .maybeSingle();

    let ruleId: string;
    if (existing?.id) {
      // Force the trigger to rsvpDeadlinePassed regardless of how the
      // template seeded it. Keep config + conditions + consequences.
      await admin.from("rules")
        .update({
          is_active: true,
          trigger: { eventType: "rsvpDeadlinePassed", config: {} },
        })
        .eq("id", existing.id);
      ruleId = existing.id;
    } else {
      // Template didn't ship this rule — insert one directly so the
      // engine has something to evaluate.
      const { data: inserted, error: insErr } = await admin
        .from("rules")
        .insert({
          group_id: group.groupId,
          name: "No confirmó a tiempo (e2e)",
          slug: "rsvp_no_response_fine_e2e",
          is_active: true,
          trigger: { eventType: "rsvpDeadlinePassed", config: {} },
          conditions: [{ type: "responseStatusIs", config: { status: "pending" } }],
          consequences: [{ type: "fine", config: { amount: 150 } }],
        })
        .select("id")
        .single();
      if (insErr || !inserted) {
        throw new Error(`rule insert failed: ${insErr?.message}`);
      }
      ruleId = inserted.id;
    }

    // Event already in the past, deadline already past. emit-deadline-events
    // picks it up because rsvp_deadline < now AND status='scheduled'.
    const startsAt = new Date(Date.now() + 4 * 3600_000);   // 4h ahead
    const rsvpDeadline = new Date(Date.now() - 1 * 60_000);  // 1 min ago
    const { data: eventId, error: createErr } = await alice.client.rpc(
      "create_event_v2",
      {
        p_group_id:       group.groupId,
        p_title:          "Cena con deadline pasado",
        p_starts_at:      startsAt.toISOString(),
        p_host_id:        alice.userId,
        p_rsvp_deadline:  rsvpDeadline.toISOString(),
      },
    );
    if (createErr) throw new Error(`create_event_v2: ${createErr.message}`);

    // Alice + Carla RSVP going. Bob never responds (his RSVP row stays
    // 'pending' as seeded by create_event_v2).
    for (const m of [alice, carla]) {
      const { error: rsvpErr } = await m.client.rpc("set_rsvp_v2", {
        p_event_id: eventId,
        p_status:   "going",
      });
      if (rsvpErr) throw new Error(`set_rsvp_v2 ${m.handle}: ${rsvpErr.message}`);
    }

    // ──────────────────────────────────────────────────────────────────
    // STEP 1 — emit-deadline-events runs → inserts rsvpDeadlinePassed
    // system_event for our event (because rsvp_deadline < now).
    // ──────────────────────────────────────────────────────────────────

    const emitDeadline = await invokeCron("emit-deadline-events");
    assertEquals(emitDeadline.ok, true, `emit-deadline-events failed: ${JSON.stringify(emitDeadline.body)}`);

    // Sanity: exactly one rsvpDeadlinePassed row for this event
    const { data: deadlineRows } = await admin
      .from("system_events")
      .select("id, payload")
      .eq("group_id", group.groupId)
      .eq("event_type", "rsvpDeadlinePassed")
      .eq("resource_id", eventId);
    assertEquals(deadlineRows?.length, 1, "expected exactly 1 rsvpDeadlinePassed emitted");

    // ──────────────────────────────────────────────────────────────────
    // STEP 2 — process-system-events runs rule engine. The rule fires
    // for Bob (pending RSVP) and proposes a fine.
    // ──────────────────────────────────────────────────────────────────

    const proc = await invokeCron("process-system-events");
    assertEquals(proc.ok, true, `process-system-events failed: ${JSON.stringify(proc.body)}`);

    const fine = await assertFineState({
      groupId:        group.groupId,
      userId:         bob.userId,
      expectedStatus: "proposed",
      expectedAmount: 150,
    });

    // ──────────────────────────────────────────────────────────────────
    // STEP 3 — fast-forward 25h, officialize via finalize-fine-reviews.
    // ──────────────────────────────────────────────────────────────────

    const t1 = new Date(Date.now() + 25 * 3600_000);
    const finalizeFines = await invokeCron("finalize-fine-reviews", { clockOverride: t1 });
    assertEquals(finalizeFines.ok, true, `finalize-fine-reviews failed: ${JSON.stringify(finalizeFines.body)}`);

    await assertFineState({
      fineId:         fine.id,
      groupId:        group.groupId,
      userId:         bob.userId,
      expectedStatus: "officialized",
      expectedAmount: 150,
    });

    // ──────────────────────────────────────────────────────────────────
    // STEP 4 — Bob calls start_fine_appeal (NOT raw start_vote). This
    // flips fines.status to in_appeal — the key precondition for
    // mig 00123 to mutate the fine when the vote resolves.
    // ──────────────────────────────────────────────────────────────────

    const { data: voteId, error: appealErr } = await bob.client.rpc("start_fine_appeal", {
      p_fine_id: fine.id,
      p_reason:  "El deadline estaba mal anunciado; pediría revisión.",
    });
    if (appealErr) throw new Error(`start_fine_appeal: ${appealErr.message}`);

    // Verify the appeal helper actually flipped status to in_appeal.
    await assertFineState({
      fineId:         fine.id,
      groupId:        group.groupId,
      userId:         bob.userId,
      expectedStatus: "in_appeal",
      expectedAmount: 150,
    });

    // ──────────────────────────────────────────────────────────────────
    // STEP 5 — Alice + Carla vote in_favor.
    // ──────────────────────────────────────────────────────────────────

    for (const voter of [alice, carla]) {
      const { error: castErr } = await voter.client.rpc("cast_vote", {
        p_vote_id: voteId,
        p_choice:  "in_favor",
      });
      if (castErr) throw new Error(`cast_vote ${voter.handle}: ${castErr.message}`);
    }

    // ──────────────────────────────────────────────────────────────────
    // STEP 6 — fast-forward 73h, finalize-votes. Vote resolves passed,
    // finalize_vote v4 (mig 00123) mutates fines.status → voided.
    // ──────────────────────────────────────────────────────────────────

    const t2 = new Date(Date.now() + 73 * 3600_000);
    const finalizeVotes = await invokeCron("finalize-votes", { clockOverride: t2 });
    assertEquals(finalizeVotes.ok, true, `finalize-votes failed: ${JSON.stringify(finalizeVotes.body)}`);

    await assertVoteResolution({
      voteId:             voteId as string,
      expectedResolution: "passed",
      expectedStatus:     "resolved",
    });

    // THE CONTRACT: fine moved from in_appeal → voided.
    await assertFineState({
      fineId:         fine.id,
      groupId:        group.groupId,
      userId:         bob.userId,
      expectedStatus: "voided",
      expectedAmount: 150,
    });

    // Waived flag + reason populated (mig 00123).
    const { data: voidedFine } = await admin
      .from("fines")
      .select("waived, waived_at, waived_reason")
      .eq("id", fine.id)
      .single();
    assertEquals(voidedFine?.waived, true, "passed appeal should set waived=true");
    assertEquals(typeof voidedFine?.waived_at, "string", "passed appeal should set waived_at");
    assertEquals(
      (voidedFine?.waived_reason as string ?? "").startsWith("appeal_passed"),
      true,
      `passed appeal should set waived_reason starting with 'appeal_passed', got: ${voidedFine?.waived_reason}`,
    );

    // ──────────────────────────────────────────────────────────────────
    // STEP 7 — Causal chain: every milestone observable in system_events.
    // ──────────────────────────────────────────────────────────────────

    await assertCausalChain({
      groupId: group.groupId,
      expectedSubsequence: [
        "rsvpDeadlinePassed",
        "fineOfficialized",
        "appealCreated",
        "voteOpened",
        "voteCast",
        "voteResolved",
        "appealResolved",
      ],
    });

    // ──────────────────────────────────────────────────────────────────
    // STEP 8 — Inbox cleared. mig 00123 resolves finePending +
    // appealVotePending for everyone involved when fine_appeal passes.
    // ──────────────────────────────────────────────────────────────────

    const { data: bobInbox } = await admin
      .from("user_actions")
      .select("action_type, resolved_at")
      .eq("user_id", bob.userId)
      .eq("group_id", group.groupId)
      .is("resolved_at", null);

    const bobPendingTypes = (bobInbox ?? []).map(r => r.action_type);
    assertEquals(
      bobPendingTypes.includes("finePending"),
      false,
      `Bob's finePending should be resolved after appeal passes; still pending: ${bobPendingTypes.join(",")}`,
    );

    for (const voter of [alice, carla]) {
      const { data: vInbox } = await admin
        .from("user_actions")
        .select("action_type, resolved_at")
        .eq("user_id", voter.userId)
        .eq("group_id", group.groupId)
        .eq("action_type", "appealVotePending")
        .is("resolved_at", null);
      assertEquals(
        vInbox?.length, 0,
        `${voter.handle}'s appealVotePending must be resolved`,
      );
    }

    // Suppress unused warnings for ruleId (some test runners flag it
    // even though we use it implicitly via the patch).
    void ruleId;
  } finally {
    if (group) await cleanupGroup(group);
  }
});

// =============================================================================
// 2. auto-close-events emits eventClosed → no-show rule fires
// =============================================================================

Deno.test("auto-close-events emits eventClosed → rule engine fires no-show fine", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [
        { handle: "alice" },   // founder + host
        { handle: "bob" },     // RSVP'd going, never checks in
        { handle: "carla" },   // RSVP'd declined — should NOT be fined
      ],
      seedDinnerRules: true,
    });
    const [alice, bob, carla] = group.members;

    // Activate only the no-show rule.
    await admin.from("rules")
      .update({ is_active: false })
      .eq("group_id", group.groupId);

    const { data: existing } = await admin
      .from("rules")
      .select("id")
      .eq("group_id", group.groupId)
      .ilike("name", "%no%show%")
      .maybeSingle();

    if (existing?.id) {
      await admin.from("rules").update({ is_active: true }).eq("id", existing.id);
    } else {
      // Insert a synthetic no-show rule keyed on eventClosed + going + !checkIn.
      const { error: insErr } = await admin
        .from("rules")
        .insert({
          group_id: group.groupId,
          name: "No-show (e2e auto-close)",
          slug: "no_show_event_close_e2e",
          is_active: true,
          trigger: { eventType: "eventClosed", config: {} },
          conditions: [
            { type: "responseStatusIs", config: { status: "going" } },
            { type: "checkInExists",    config: { exists: false } },
          ],
          consequences: [{ type: "fine", config: { amount: 250 } }],
        });
      if (insErr) throw new Error(`no-show rule insert: ${insErr.message}`);
    }

    // Event in the past, way past the auto-close cutoff (default 24h).
    const startsAt = new Date(Date.now() - 30 * 3600_000); // 30h ago
    const { data: eventId, error: createErr } = await alice.client.rpc(
      "create_event_v2",
      {
        p_group_id:  group.groupId,
        p_title:     "Cena olvidada (host no cierra)",
        p_starts_at: startsAt.toISOString(),
        p_host_id:   alice.userId,
      },
    );
    if (createErr) throw new Error(`create_event_v2: ${createErr.message}`);

    // RSVPs: bob going, carla declined. Bob never checks in.
    await bob.client.rpc("set_rsvp_v2",   { p_event_id: eventId, p_status: "going" });
    await carla.client.rpc("set_rsvp_v2", { p_event_id: eventId, p_status: "declined" });

    // ──────────────────────────────────────────────────────────────────
    // STEP 1 — auto-close-events runs. The event is 30h old (past the
    // 24h default cutoff) and status='scheduled' so it gets closed AND
    // an eventClosed system_event is emitted (Fix #1).
    // ──────────────────────────────────────────────────────────────────

    const autoClose = await invokeCron("auto-close-events");
    assertEquals(autoClose.ok, true, `auto-close-events failed: ${JSON.stringify(autoClose.body)}`);
    assertEquals(
      (autoClose.body as { closed?: number; emitted?: number })?.emitted,
      1,
      `auto-close-events should emit exactly 1 eventClosed; got ${JSON.stringify(autoClose.body)}`,
    );

    // STATE: event flipped to completed
    const { data: closedEvent } = await admin
      .from("events")
      .select("status, closed_at")
      .eq("id", eventId)
      .single();
    assertEquals(closedEvent?.status, "completed", "event should be completed after auto-close");
    assertEquals(typeof closedEvent?.closed_at, "string", "closed_at should be set");

    // CAUSAL: an eventClosed system_event exists for this event
    const { data: closedSe } = await admin
      .from("system_events")
      .select("id, payload, member_id")
      .eq("group_id", group.groupId)
      .eq("event_type", "eventClosed")
      .eq("resource_id", eventId);
    assertEquals(closedSe?.length, 1, "expected exactly 1 eventClosed system_event after auto-close");
    const closedPayload = closedSe?.[0]?.payload as Record<string, unknown>;
    assertEquals(closedPayload?.auto_closed, true, "eventClosed payload should mark auto_closed=true");

    // ──────────────────────────────────────────────────────────────────
    // STEP 2 — process-system-events runs the rule engine on the
    // emitted eventClosed. Bob (going + no check-in) → fine. Carla
    // (declined) skipped.
    // ──────────────────────────────────────────────────────────────────

    const proc = await invokeCron("process-system-events");
    assertEquals(proc.ok, true, `process-system-events failed: ${JSON.stringify(proc.body)}`);

    // Bob should have exactly 1 proposed fine
    await assertFineState({
      groupId:        group.groupId,
      userId:         bob.userId,
      expectedStatus: "proposed",
      expectedAmount: 250,
    });

    // Carla should have ZERO fines (RSVP'd declined → no-show rule
    // doesn't apply because she wasn't 'going').
    const { data: carlaFines } = await admin
      .from("fines")
      .select("id")
      .eq("group_id", group.groupId)
      .eq("user_id", carla.userId);
    assertEquals(carlaFines?.length, 0, "Carla (declined) must not be fined for no-show");

    // CAUSAL: chain present.
    await assertCausalChain({
      groupId: group.groupId,
      expectedSubsequence: ["eventClosed"],
    });
  } finally {
    if (group) await cleanupGroup(group);
  }
});
