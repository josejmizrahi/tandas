// Tier 3 (mig 00130) acceptance: start_vote consults
// p_payload->'capability_config'->'voting' before falling back to
// groups.governance.
//
// Pre-Tier-3, the only knobs that beat governance were the explicit
// per-call params (p_quorum_percent, p_threshold_percent, …). The
// wizard's per-resource voting capability config existed in
// `resource_capabilities.config` but never made it into the vote row.
//
// Three precedence scenarios:
//   1. payload.capability_config.voting set, no explicit params →
//      vote row uses the cap_config values (governance defaults
//      ignored).
//   2. payload.capability_config.voting omitted → vote row falls back
//      to groups.governance (pre-Tier-3 behavior preserved).
//   3. explicit p_quorum_percent supplied AND payload.cap_config set →
//      the explicit param wins (top of the precedence chain).

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";

const admin = adminClient();

async function fetchVote(voteId: string) {
  const { data, error } = await admin
    .from("votes")
    .select("quorum_percent, threshold_percent, is_anonymous, quorum_min_absolute")
    .eq("id", voteId)
    .single();
  if (error) throw new Error(`select vote ${voteId}: ${error.message}`);
  return data as {
    quorum_percent: number;
    threshold_percent: number;
    is_anonymous: boolean;
    quorum_min_absolute: number;
  };
}

Deno.test("Tier 3: payload.capability_config.voting overrides governance", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }, { handle: "carla" }],
      seedDinnerRules: false,
    });

    // Distinct values from the recurring_dinner governance defaults so
    // a regression to those is immediately visible.
    const capQuorum = 75;
    const capThreshold = 80;
    const capAnonymous = false;
    const capQuorumMin = 3;

    const { data: voteId, error } = await group.founder.client.rpc("start_vote", {
      p_group_id:     group.groupId,
      p_vote_type:    "general_proposal",
      p_reference_id: group.groupId, // any uuid for a general proposal
      p_title:        "Cap config wins",
      p_description:  null,
      p_payload: {
        capability_config: {
          voting: {
            quorumPercent:    capQuorum,
            thresholdPercent: capThreshold,
            anonymous:        capAnonymous,
            quorumMinAbsolute: capQuorumMin,
          },
        },
      },
    });
    if (error) throw new Error(`start_vote: ${error.message}`);
    if (typeof voteId !== "string") {
      throw new Error(`start_vote returned non-uuid: ${JSON.stringify(voteId)}`);
    }

    const row = await fetchVote(voteId);
    assertEquals(row.quorum_percent, capQuorum, "cap_config quorum must win");
    assertEquals(row.threshold_percent, capThreshold, "cap_config threshold must win");
    assertEquals(row.is_anonymous, capAnonymous, "cap_config anonymous must win");
    assertEquals(row.quorum_min_absolute, capQuorumMin, "cap_config quorum_min must win");
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 3: omitted capability_config falls back to governance", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });

    // Read governance so the assertion stays accurate if defaults shift.
    const { data: g, error: gErr } = await admin
      .from("groups")
      .select("governance")
      .eq("id", group.groupId)
      .single();
    if (gErr) throw new Error(`select governance: ${gErr.message}`);
    const gov = (g?.governance ?? {}) as Record<string, unknown>;
    const expectedQuorum   = Number(gov["votingQuorumPercent"]     ?? 50);
    const expectedThresh   = Number(gov["votingThresholdPercent"]  ?? 50);
    const expectedAnon     = gov["votesAreAnonymous"] === undefined
      ? true
      : Boolean(gov["votesAreAnonymous"]);
    const expectedQMin     = Number(gov["votingQuorumMinAbsolute"] ?? 2);

    const { data: voteId, error } = await group.founder.client.rpc("start_vote", {
      p_group_id:     group.groupId,
      p_vote_type:    "general_proposal",
      p_reference_id: group.groupId,
      p_title:        "Governance fallback",
      p_description:  null,
      p_payload:      {}, // no capability_config
    });
    if (error) throw new Error(`start_vote: ${error.message}`);
    if (typeof voteId !== "string") {
      throw new Error(`start_vote returned non-uuid: ${JSON.stringify(voteId)}`);
    }

    const row = await fetchVote(voteId);
    assertEquals(row.quorum_percent, expectedQuorum, "governance quorum fallback");
    assertEquals(row.threshold_percent, expectedThresh, "governance threshold fallback");
    assertEquals(row.is_anonymous, expectedAnon, "governance anonymous fallback");
    assertEquals(row.quorum_min_absolute, expectedQMin, "governance quorum_min fallback");
  } finally {
    if (group) await cleanupGroup(group);
  }
});

Deno.test("Tier 3: explicit per-call param still wins over capability_config", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });

    const explicitQuorum = 90;
    const capQuorum      = 60;

    const { data: voteId, error } = await group.founder.client.rpc("start_vote", {
      p_group_id:         group.groupId,
      p_vote_type:        "general_proposal",
      p_reference_id:     group.groupId,
      p_title:            "Explicit param wins",
      p_description:      null,
      p_payload: {
        capability_config: { voting: { quorumPercent: capQuorum } },
      },
      p_quorum_percent:   explicitQuorum,
    });
    if (error) throw new Error(`start_vote: ${error.message}`);
    if (typeof voteId !== "string") {
      throw new Error(`start_vote returned non-uuid: ${JSON.stringify(voteId)}`);
    }

    const row = await fetchVote(voteId);
    assertEquals(
      row.quorum_percent,
      explicitQuorum,
      "explicit p_quorum_percent must outrank capability_config",
    );
  } finally {
    if (group) await cleanupGroup(group);
  }
});
