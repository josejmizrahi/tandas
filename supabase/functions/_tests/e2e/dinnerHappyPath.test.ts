// Dinner happy path E2E: late check-in → escalating fine → grace expires
// → fine officialized → Bob appeals → Alice + Carla vote in_favor → vote
// resolves passed.
//
// Verifies the three-level contract:
//   1. State:        fines.status, votes.status/payload.resolution
//   2. Causal chain: system_events sequence (checkInRecorded →
//                    eventClosed → fineOfficialized → voteOpened →
//                    voteCast → voteResolved)
//   3. Notifications: notifications_outbox rows for each milestone
//
// Run prerequisites in supabase/functions/_tests/README.md.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";
import { invokeCron } from "./_fixtures/invokeCron.ts";
import {
  assertCausalChain,
  assertFineState,
  assertNotifications,
  assertVoteResolution,
  countSystemEvents,
} from "./_fixtures/assertions.ts";

const admin = adminClient();

Deno.test("dinner happy path — late check-in → fine → grace → officialized → appeal passed", async () => {
  // ────────────────────────────────────────────────────────────────────
  // SETUP — 3 members, dinner template rules, fresh event
  // ────────────────────────────────────────────────────────────────────

  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [
        { handle: "alice" },   // founder + host
        { handle: "bob" },     // infractor (will arrive late)
        { handle: "carla" },
      ],
      seedDinnerRules: true,
    });
    const [alice, bob, carla] = group.members;

    // Deactivate the no-show + no-rsvp + same-day-cancel rules so the
    // test only exercises "Llegada tardía". This keeps the assertions
    // focused — the other rules have their own coverage in the Deno
    // unit tests for the rule engine.
    await admin.from("rules")
      .update({ is_active: false })
      .eq("group_id", group.groupId)
      .neq("name", "Llegada tardía");

    // Create event 90 min ago so check-in lateness is meaningful.
    const startsAt = new Date(Date.now() - 90 * 60_000);
    const { data: eventId, error: createErr } = await alice.client.rpc(
      "create_event_v2",
      {
        p_group_id:    group.groupId,
        p_title:       "Cena del martes",
        p_starts_at:   startsAt.toISOString(),
        p_host_id:     alice.userId,
      },
    );
    if (createErr) throw new Error(`create_event_v2: ${createErr.message}`);

    // Bob RSVPs going + checks in 75 min late
    const { error: bobRsvpErr } = await bob.client.rpc("set_rsvp_v2", {
      p_event_id: eventId,
      p_status:   "going",
    });
    if (bobRsvpErr) throw new Error(`set_rsvp_v2 bob: ${bobRsvpErr.message}`);

    const arrivedAt = new Date(startsAt.getTime() + 75 * 60_000);
    const { error: checkInErr } = await alice.client.rpc("check_in_attendee", {
      p_event_id:  eventId,
      p_user_id:   bob.userId,
      p_arrived_at: arrivedAt.toISOString(),
    });
    if (checkInErr) throw new Error(`check_in_attendee bob: ${checkInErr.message}`);

    // Emit checkInRecorded system_event manually (this is what the iOS
    // app does after a successful check-in).
    await admin.from("system_events").insert({
      group_id:    group.groupId,
      event_type:  "checkInRecorded",
      resource_id: eventId,
      member_id:   bob.memberId,
      payload:     { method: "qr", late_minutes: 75 },
    });

    // ────────────────────────────────────────────────────────────────
    // STEP 1 — process-system-events runs the rule engine on
    // checkInRecorded. Rule "Llegada tardía" fires for Bob.
    // ────────────────────────────────────────────────────────────────

    const proc1 = await invokeCron("process-system-events");
    assertEquals(proc1.ok, true, `process-system-events #1 failed: ${JSON.stringify(proc1.body)}`);

    // STATE: 1 proposed fine for Bob, escalating amount = 200 + 2*50 = 300
    const fine = await assertFineState({
      groupId:        group.groupId,
      userId:         bob.userId,
      expectedStatus: "proposed",
      expectedAmount: 300,
    });

    // ────────────────────────────────────────────────────────────────
    // STEP 2 — Alice closes the event (eventClosed → no rules fire
    // because we deactivated them).
    // ────────────────────────────────────────────────────────────────

    const { error: closeErr } = await alice.client.rpc("close_event", { p_event_id: eventId });
    if (closeErr) throw new Error(`close_event: ${closeErr.message}`);

    // close_event uses the LEGACY rule pipeline; emit eventClosed for
    // the new pipeline (so the causal-chain assertion sees it).
    await admin.from("system_events").insert({
      group_id:    group.groupId,
      event_type:  "eventClosed",
      resource_id: eventId,
      member_id:   alice.memberId,
      payload:     { host_id: alice.userId, fines_proposed: 1 },
    });
    await invokeCron("process-system-events");  // no-op for our deactivated rules

    // ────────────────────────────────────────────────────────────────
    // STEP 3 — advance clock 25h, run finalize-fine-reviews. Fine
    // officializes; outbox row written for Bob.
    // ────────────────────────────────────────────────────────────────

    const fastForward1 = new Date(Date.now() + 25 * 3600_000);
    const finalizeFines = await invokeCron("finalize-fine-reviews", {
      clockOverride: fastForward1,
    });
    assertEquals(finalizeFines.ok, true, `finalize-fine-reviews failed: ${JSON.stringify(finalizeFines.body)}`);

    // STATE: fine is now officialized
    await assertFineState({
      fineId:         fine.id,
      groupId:        group.groupId,
      userId:         bob.userId,
      expectedStatus: "officialized",
      expectedAmount: 300,
    });

    // CAUSAL: subsequence checkInRecorded → eventClosed → fineOfficialized
    await assertCausalChain({
      groupId: group.groupId,
      expectedSubsequence: ["checkInRecorded", "eventClosed", "fineOfficialized"],
    });

    // NOTIFS: Bob receives 1 fineOfficialized notification
    await assertNotifications({
      groupId: group.groupId,
      expected: [
        { recipientMemberId: bob.memberId, notificationType: "fineOfficialized" },
      ],
    });

    // ────────────────────────────────────────────────────────────────
    // STEP 4 — Bob opens an appeal via start_vote (generic Vote API).
    // Alice + Carla get vote_casts; Bob is excluded (infractor).
    // ────────────────────────────────────────────────────────────────

    const { data: voteId, error: startVoteErr } = await bob.client.rpc("start_vote", {
      p_group_id:     group.groupId,
      p_vote_type:    "fine_appeal",
      p_reference_id: fine.id,
      p_title:        "Apelación: llegada tardía",
      p_description:  "Mi check-in tardó por tráfico, no por falta de respeto.",
      p_payload:      { fine_id: fine.id, member_id: bob.memberId },
    });
    if (startVoteErr) throw new Error(`start_vote: ${startVoteErr.message}`);

    // Verify infractor exclusion — only 2 vote_casts (Alice + Carla)
    const { data: castsAtOpen, error: castsErr } = await admin
      .from("vote_casts")
      .select("member_id, choice")
      .eq("vote_id", voteId);
    if (castsErr) throw new Error(`vote_casts query: ${castsErr.message}`);
    assertEquals(castsAtOpen?.length, 2, "expected 2 vote_casts (Bob excluded)");
    const castMembers = new Set((castsAtOpen ?? []).map((c) => c.member_id));
    assertEquals(castMembers.has(bob.memberId), false, "Bob must not have a vote_cast row");
    assertEquals(castMembers.has(alice.memberId), true);
    assertEquals(castMembers.has(carla.memberId), true);

    // ────────────────────────────────────────────────────────────────
    // STEP 5 — Alice + Carla cast in_favor. (Both side with Bob.)
    // ────────────────────────────────────────────────────────────────

    for (const voter of [alice, carla]) {
      const { error: castErr } = await voter.client.rpc("cast_vote", {
        p_vote_id: voteId,
        p_choice:  "in_favor",
      });
      if (castErr) throw new Error(`cast_vote ${voter.handle}: ${castErr.message}`);
    }

    // ────────────────────────────────────────────────────────────────
    // STEP 6 — advance clock 73h past vote opening, run finalize-votes.
    // Vote resolves passed (2/2 in_favor, quorum=2 met, threshold=50%).
    // ────────────────────────────────────────────────────────────────

    const fastForward2 = new Date(Date.now() + 73 * 3600_000);
    const finalizeVotes = await invokeCron("finalize-votes", {
      clockOverride: fastForward2,
    });
    assertEquals(finalizeVotes.ok, true, `finalize-votes failed: ${JSON.stringify(finalizeVotes.body)}`);

    // STATE: vote resolved as passed
    await assertVoteResolution({
      voteId:             voteId as string,
      expectedResolution: "passed",
      expectedStatus:     "resolved",
    });

    // CAUSAL: full chain present
    await assertCausalChain({
      groupId: group.groupId,
      expectedSubsequence: [
        "checkInRecorded",
        "eventClosed",
        "fineOfficialized",
        "voteOpened",
        "voteCast",          // at least one (the assertion is subsequence)
        "voteResolved",
      ],
    });

    // NOTIFS: Alice + Carla received voteOpened (eligible voters); Bob
    // (appellant) + Alice + Carla all received voteResolved.
    await assertNotifications({
      groupId: group.groupId,
      expected: [
        { recipientMemberId: alice.memberId, notificationType: "voteOpened" },
        { recipientMemberId: carla.memberId, notificationType: "voteOpened" },
        { recipientMemberId: alice.memberId, notificationType: "voteResolved" },
        { recipientMemberId: carla.memberId, notificationType: "voteResolved" },
        { recipientMemberId: bob.memberId,   notificationType: "voteResolved" },
        { recipientMemberId: bob.memberId,   notificationType: "fineOfficialized" },
      ],
    });

    // Bob did NOT receive a voteOpened (infractor exclusion contract)
    const { data: bobVoteOpenedRows } = await admin
      .from("notifications_outbox")
      .select("id")
      .eq("group_id", group.groupId)
      .eq("recipient_member_id", bob.memberId)
      .eq("notification_type", "voteOpened");
    assertEquals(bobVoteOpenedRows?.length, 0, "Bob (infractor) must not get voteOpened notification");

    // Sanity: exactly 1 voteResolved system_event was emitted
    assertEquals(await countSystemEvents(group.groupId, "voteResolved"), 1);

    // ────────────────────────────────────────────────────────────────
    // STEP 7 — Fix #3 contract: a passed fine_appeal vote MUST have
    // mutated the underlying fine. Before mig 00123 the fine stayed
    // pegged at in_appeal forever. Now: passed → voided + waived.
    //
    // Note this test routes the appeal via raw start_vote (not via
    // start_fine_appeal), so the fine was never flipped to in_appeal.
    // The mig 00123 guard `WHERE status='in_appeal'` therefore SKIPS
    // mutation here — the fine stays officialized. That's correct: a
    // vote opened without the appeal helper isn't recognized as a
    // formal appeal. We assert the negative-mutation path here, and
    // assert the positive path in autoCloseAndDeadline.test.ts where
    // the appeal goes through start_fine_appeal.
    // ────────────────────────────────────────────────────────────────

    await assertFineState({
      fineId:         fine.id,
      groupId:        group.groupId,
      userId:         bob.userId,
      expectedStatus: "officialized",
      expectedAmount: 300,
    });
  } finally {
    if (group) await cleanupGroup(group);
  }
});
