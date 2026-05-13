// Edge scenario: 2-member group, infractor opens appeal, quorum is
// mathematically impossible to meet → appeal closes as quorum_failed,
// fine stays officialized.
//
// This validates the combined effect of:
//   - 00023 quorum_min_absolute (default 2)
//   - 00023 infractor exclusion in start_vote(vote_type='fine_appeal')
//
// Setup:  Alice (founder) + Bob (infractor). Eligible voters = 1 (Alice).
// Quorum: max(ceil(1 * 0.5), 2) = 2. Even if Alice votes, 1 < 2 → fail.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { extractRowId, seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";
import { invokeCron } from "./_fixtures/invokeCron.ts";
import {
  assertCausalChain,
  assertFineState,
  assertVoteResolution,
} from "./_fixtures/assertions.ts";

const admin = adminClient();

// Un-quarantined 2026-05-12 Tier 0.5 cleanup. Root cause was the
// edge-tests workflow not passing `ALLOW_CLOCK_OVERRIDE` into the
// `supabase functions serve` containers, so the cron silently
// ignored X-Test-Clock and the fine never advanced past `proposed`.
// Fixed in CI commit 46aa334 by writing /tmp/edge-fn-env and adding
// `--env-file /tmp/edge-fn-env` to the serve command.
Deno.test("2-member group: infractor only eligible → quorum_failed automatic", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [
        { handle: "alice" },   // founder
        { handle: "bob" },     // infractor
      ],
      seedDinnerRules: true,
    });
    const [alice, bob] = group.members;

    // Beta 1 W1-2 (mig 00137): all monetary fines ship is_active=false.
    // Force "Llegada tardía" on and everything else off — this test
    // only exercises that rule.
    await admin.from("rules")
      .update({ is_active: false })
      .eq("group_id", group.groupId);
    await admin.from("rules")
      .update({ is_active: true })
      .eq("group_id", group.groupId)
      .eq("name", "Llegada tardía");

    // Create event 90 min ago, Bob RSVPs going + checks in 75 min late
    const startsAt = new Date(Date.now() - 90 * 60_000);
    const { data: createResult, error: createErr } = await alice.client.rpc("create_event_v2", {
      p_group_id:  group.groupId,
      p_title:     "Cena chica",
      p_starts_at: startsAt.toISOString(),
      p_host_id:   alice.userId,
    });
    if (createErr) throw new Error(`create_event_v2: ${createErr.message}`);
    const eventId = extractRowId(createResult);
    if (!eventId) throw new Error(`create_event_v2 returned no id: ${JSON.stringify(createResult)}`);

    await bob.client.rpc("set_rsvp_v2", { p_event_id: eventId, p_status: "going" });
    await alice.client.rpc("check_in_attendee", {
      p_event_id:  eventId,
      p_user_id:   bob.userId,
      p_arrived_at: new Date(startsAt.getTime() + 75 * 60_000).toISOString(),
    });

    await admin.from("system_events").insert({
      group_id:    group.groupId,
      event_type:  "checkInRecorded",
      resource_id: eventId,
      member_id:   bob.memberId,
      payload:     { method: "qr", late_minutes: 75 },
    });

    await invokeCron("process-system-events");

    const fine = await assertFineState({
      groupId: group.groupId,
      userId: bob.userId,
      expectedStatus: "proposed",
      expectedAmount: 300,
    });

    // Officialize fine
    await invokeCron("finalize-fine-reviews", {
      clockOverride: new Date(Date.now() + 25 * 3600_000),
    });
    await assertFineState({
      fineId: fine.id,
      groupId: group.groupId,
      userId: bob.userId,
      expectedStatus: "officialized",
      expectedAmount: 300,
    });

    // ──────────────────────────────────────────────────────────────
    // Bob opens appeal. Only Alice should be eligible.
    // ──────────────────────────────────────────────────────────────

    const { data: voteId, error: startErr } = await bob.client.rpc("start_vote", {
      p_group_id:     group.groupId,
      p_vote_type:    "fine_appeal",
      p_reference_id: fine.id,
      p_title:        "Apelación: llegada tardía",
      p_payload:      { fine_id: fine.id, member_id: bob.memberId },
    });
    if (startErr) throw new Error(`start_vote: ${startErr.message}`);

    // Only Alice has a vote_cast row (Bob excluded as infractor)
    const { data: casts } = await admin
      .from("vote_casts")
      .select("member_id")
      .eq("vote_id", voteId);
    assertEquals(casts?.length, 1, "expected exactly 1 vote_cast (Alice only)");
    assertEquals(casts?.[0].member_id, alice.memberId);

    // Verify the vote's quorum_min_absolute defaulted to 2
    const { data: voteRow } = await admin
      .from("votes")
      .select("quorum_min_absolute, quorum_percent")
      .eq("id", voteId)
      .single();
    assertEquals(voteRow?.quorum_min_absolute, 2, "vote.quorum_min_absolute should default to 2");

    // Alice votes — quorum still impossible to meet (max(ceil(1*0.5), 2) = 2)
    await alice.client.rpc("cast_vote", { p_vote_id: voteId, p_choice: "in_favor" });

    // ──────────────────────────────────────────────────────────────
    // Advance clock past closes_at, run finalize-votes. Vote MUST
    // resolve as quorum_failed even though Alice voted in_favor.
    // ──────────────────────────────────────────────────────────────

    await invokeCron("finalize-votes", {
      clockOverride: new Date(Date.now() + 73 * 3600_000),
    });

    await assertVoteResolution({
      voteId:             voteId as string,
      expectedResolution: "quorum_failed",
      expectedStatus:     "quorum_failed",
    });

    // Fine remains officialized — no auto-cancel on quorum_failed
    await assertFineState({
      fineId: fine.id,
      groupId: group.groupId,
      userId: bob.userId,
      expectedStatus: "officialized",
      expectedAmount: 300,
    });

    // Causal chain: vote opened, the single cast happened, then resolved
    await assertCausalChain({
      groupId: group.groupId,
      expectedSubsequence: ["voteOpened", "voteCast", "voteResolved"],
    });
  } finally {
    if (group) await cleanupGroup(group);
  }
});
