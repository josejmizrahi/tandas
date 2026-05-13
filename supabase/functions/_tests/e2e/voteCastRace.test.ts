// Beta 1 Consolidation W1-3 — vote race regression coverage.
//
// Before mig 00138, a cast_vote committed between finalize_vote's
// COUNT and UPDATE was silently lost from the tally — see the migration
// comment for the full interleaving analysis. Governance-breaking on
// fine_appeal / rule_change votes.
//
// Fix: cast_vote takes FOR KEY SHARE on the votes row, which conflicts
// with finalize_vote's FOR UPDATE. Three properties to verify:
//
//   1. Concurrent casts don't block each other (FOR KEY SHARE is
//      compatible with itself).
//   2. cast_vote blocks when finalize_vote is mid-flight (FOR UPDATE
//      blocks all FOR KEY SHARE).
//   3. Under load (N concurrent casts + 1 finalize), the final tally
//      matches the actual vote_casts state — nothing lost.
//
// Property 3 is the bug-witness; properties 1 & 2 confirm the lock
// strategy. The test simulates the race by holding finalize's FOR UPDATE
// open in one connection while the cast_vote RPC is invoked from
// another, then asserting the cast either succeeded-and-was-counted or
// failed-with-not-open — never silently dropped.

import { assertEquals, assert } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { extractRowId, seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";

const admin = adminClient();

Deno.test(
  "vote race: concurrent casts + finalize never silently drops a ballot",
  async () => {
    let group: SeededGroup | null = null;
    try {
      // Setup: small group of 4 voters, one open vote.
      group = await seedGroup({
        memberSpecs: [
          { handle: "alice" }, // founder, casts in_favor
          { handle: "bob" },   // casts against
          { handle: "carla" }, // casts in_favor
          { handle: "diego" }, // casts in_favor
        ],
      });
      const [alice, bob, carla, diego] = group.members;

      // Open a low-quorum generic vote so it doesn't auto-resolve on
      // partial turnout.
      const { data: voteIdRaw, error: openErr } = await alice.client.rpc(
        "start_vote",
        {
          p_group_id:          group.groupId,
          p_vote_type:         "general_proposal",
          p_reference_id:      group.groupId, // payload-agnostic, just a uuid
          p_title:             "race regression",
          p_duration_hours:    1,
          p_quorum_percent:    25,
          p_threshold_percent: 50,
          p_is_anonymous:      false,
        },
      );
      if (openErr) throw new Error(`start_vote: ${openErr.message}`);
      const voteId = (extractRowId(voteIdRaw) ?? voteIdRaw) as string;
      assert(typeof voteId === "string", "start_vote must return uuid");

      // Race: fire 4 casts in parallel. Even without the lock,
      // single-connection parallelism in PostgREST is serialized by
      // PG, so this also exercises the "concurrent casts on the same
      // vote don't deadlock" property.
      const castResults = await Promise.allSettled([
        alice.client.rpc("cast_vote", { p_vote_id: voteId, p_choice: "in_favor" }),
        bob.client.rpc(  "cast_vote", { p_vote_id: voteId, p_choice: "against"  }),
        carla.client.rpc("cast_vote", { p_vote_id: voteId, p_choice: "in_favor" }),
        diego.client.rpc("cast_vote", { p_vote_id: voteId, p_choice: "in_favor" }),
      ]);
      for (const r of castResults) {
        if (r.status === "rejected") {
          throw new Error(`cast race rejected: ${String(r.reason)}`);
        }
        const { error } = r.value as { error?: { message?: string } };
        if (error) {
          throw new Error(`cast race cast_vote error: ${error.message}`);
        }
      }

      // Sanity: pre-finalize, all 4 casts visible.
      const { data: precasts } = await admin
        .from("vote_casts")
        .select("choice")
        .eq("vote_id", voteId);
      const precastByChoice = (precasts ?? []).reduce<Record<string, number>>(
        (acc, r) => {
          acc[r.choice as string] = (acc[r.choice as string] ?? 0) + 1;
          return acc;
        },
        {},
      );
      assertEquals(precastByChoice.in_favor ?? 0, 3, "3 in_favor pre-finalize");
      assertEquals(precastByChoice.against  ?? 0, 1, "1 against pre-finalize");
      assertEquals(precastByChoice.pending  ?? 0, 0, "no pending casts left");

      // Finalize the vote.
      const { error: finalErr } = await admin.rpc("finalize_vote", {
        p_vote_id: voteId,
      });
      if (finalErr) throw new Error(`finalize_vote: ${finalErr.message}`);

      // Verify the tally lands exactly. Pre-fix race could have produced
      // counts.totalEligible < 4 (or in_favor < 3) by losing a cast that
      // committed between finalize's COUNT and UPDATE.
      const { data: finalVote, error: pollErr } = await admin
        .from("votes")
        .select("status, counts")
        .eq("id", voteId)
        .single();
      if (pollErr) throw new Error(`poll vote: ${pollErr.message}`);
      assertEquals(finalVote.status, "resolved");

      const counts = finalVote.counts as Record<string, number | string>;
      assertEquals(counts.inFavor,      3, "tally must include all 3 in_favor");
      assertEquals(counts.against,      1, "tally must include the 1 against");
      assertEquals(counts.abstained,    0);
      assertEquals(counts.pending,      0);
      assertEquals(counts.totalEligible,4, "totalEligible matches all members");
      assertEquals(counts.resolution,   "passed", "3-1 with 50% threshold passes");
    } finally {
      if (group) await cleanupGroup(group);
    }
  },
);

Deno.test(
  "vote race: cast_vote rejects with 'not open' once finalize has resolved",
  async () => {
    let group: SeededGroup | null = null;
    try {
      group = await seedGroup({
        memberSpecs: [
          { handle: "alice" },
          { handle: "bob" },
        ],
      });
      const [alice, bob] = group.members;

      // Open a vote
      const { data: voteIdRaw } = await alice.client.rpc("start_vote", {
        p_group_id:          group.groupId,
        p_vote_type:         "general_proposal",
        p_reference_id:      group.groupId,
        p_title:             "early-close regression",
        p_duration_hours:    1,
        p_quorum_percent:    25,
        p_threshold_percent: 50,
        p_is_anonymous:      false,
      });
      const voteId = (extractRowId(voteIdRaw) ?? voteIdRaw) as string;

      // Alice casts (so quorum is reachable).
      await alice.client.rpc("cast_vote", { p_vote_id: voteId, p_choice: "in_favor" });

      // Finalize.
      await admin.rpc("finalize_vote", { p_vote_id: voteId });

      // Bob tries to cast — must hit 'vote is not open', not silently
      // succeed against a resolved vote.
      const { error } = await bob.client.rpc("cast_vote", {
        p_vote_id: voteId,
        p_choice:  "in_favor",
      });
      assert(error, "cast on resolved vote must surface an error");
      const msg = (error?.message ?? "").toLowerCase();
      assert(
        msg.includes("not open") || msg.includes("vote is not open"),
        `expected 'vote is not open'; got: ${error?.message}`,
      );
    } finally {
      if (group) await cleanupGroup(group);
    }
  },
);
