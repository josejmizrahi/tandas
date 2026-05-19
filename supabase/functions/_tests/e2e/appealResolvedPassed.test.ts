// Happy-path scenario: 3-member group, infractor opens appeal, two voters
// reach quorum and vote in_favor → appeal closes as `passed` → fine auto-
// voids via `on_fine_appeal_resolved` → `fines_view.status` flips to
// `voided`.
//
// Regression coverage for V1-04 PR #2: a broken JWT in the
// `finalize-votes-every-15min` cron had silently 401'd the closer since
// some hand-edit after mig 00327. Migs 00347 + 00348 restored the canonical
// closer; this test exercises the full happy path so any future regression
// in finalize-votes / on_fine_appeal_resolved / fines_view derivation
// surfaces here.
//
// Parallel structure to `appealQuorumFailed.test.ts`.
//
// Setup:  Alice (founder) + Bob (infractor) + Carol (regular voter).
// Eligible voters = 2 (Alice + Carol).
// Quorum: max(ceil(2 * 0.5), 2) = 2. Both vote in_favor → passed.

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

Deno.test("3-member group: appeal passes → fine_voided ledger entry → fines_view.status = voided", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [
        { handle: "alice" },   // founder
        { handle: "bob" },     // infractor
        { handle: "carol" },   // regular voter
      ],
      seedDinnerRules: true,
    });
    const [alice, bob, carol] = group.members;

    // Beta 1 W1-2 (mig 00137): monetary fines ship is_active=false.
    // Force only "Llegada tardía" on; mirrors appealQuorumFailed test.
    await admin.from("rules")
      .update({ is_active: false })
      .eq("group_id", group.groupId);
    await admin.from("rules")
      .update({ is_active: true })
      .eq("group_id", group.groupId)
      .eq("name", "Llegada tardía");

    // Event 90 min ago, Bob RSVPs going + checks in 75 min late.
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

    // Officialize fine (advance clock past the 24h review window).
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
    // Bob opens appeal. Alice + Carol should be the only eligible
    // voters (Bob excluded as infractor).
    // ──────────────────────────────────────────────────────────────

    const { data: voteId, error: startErr } = await bob.client.rpc("start_vote", {
      p_group_id:     group.groupId,
      p_vote_type:    "fine_appeal",
      p_reference_id: fine.id,
      p_title:        "Apelación: llegada tardía",
      p_payload:      { fine_id: fine.id, member_id: bob.memberId },
    });
    if (startErr) throw new Error(`start_vote: ${startErr.message}`);

    const { data: casts } = await admin
      .from("vote_casts")
      .select("member_id")
      .eq("vote_id", voteId);
    assertEquals(casts?.length, 2, "expected exactly 2 vote_casts (Alice + Carol, Bob excluded)");

    // While the appeal is open, fines_view should derive in_appeal.
    await assertFineState({
      fineId: fine.id,
      groupId: group.groupId,
      userId: bob.userId,
      expectedStatus: "in_appeal",
      expectedAmount: 300,
    });

    // Both eligible voters vote in_favor → quorum met, threshold met.
    await alice.client.rpc("cast_vote", { p_vote_id: voteId, p_choice: "in_favor" });
    await carol.client.rpc("cast_vote", { p_vote_id: voteId, p_choice: "in_favor" });

    // ──────────────────────────────────────────────────────────────
    // Advance clock past closes_at, run finalize-votes. Vote MUST
    // resolve as `passed`, which fires on_fine_appeal_resolved and
    // inserts a `fine_voided` ledger entry.
    // ──────────────────────────────────────────────────────────────

    await invokeCron("finalize-votes", {
      clockOverride: new Date(Date.now() + 73 * 3600_000),
    });

    await assertVoteResolution({
      voteId:             voteId as string,
      expectedResolution: "passed",
      expectedStatus:     "resolved",
    });

    // fines_view derives status='voided' from ledger_entries(type='fine_voided').
    await assertFineState({
      fineId: fine.id,
      groupId: group.groupId,
      userId: bob.userId,
      expectedStatus: "voided",
      expectedAmount: 300,
    });

    // Confirm the exact ledger entry on_fine_appeal_resolved should write.
    const { data: ledgerRows } = await admin
      .from("ledger_entries")
      .select("type, metadata")
      .eq("group_id", group.groupId)
      .eq("type", "fine_voided");
    assertEquals(ledgerRows?.length, 1, "expected exactly one fine_voided ledger entry");
    const row = ledgerRows![0] as { type: string; metadata: Record<string, unknown> };
    assertEquals(row.metadata.fine_id, fine.id, "ledger metadata.fine_id should reference the appealed fine");
    assertEquals(row.metadata.reason, "appeal_passed", "ledger metadata.reason should be appeal_passed");
    assertEquals(row.metadata.vote_id, voteId, "ledger metadata.vote_id should reference the resolved vote");

    // Causal chain: vote opened, two casts, then resolved.
    await assertCausalChain({
      groupId: group.groupId,
      expectedSubsequence: ["voteOpened", "voteCast", "voteCast", "voteResolved"],
    });
  } finally {
    if (group) await cleanupGroup(group);
  }
});
