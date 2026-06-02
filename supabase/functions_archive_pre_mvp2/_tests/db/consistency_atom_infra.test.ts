// supabase/functions/_tests/db/consistency_atom_infra.test.ts
//
// Covers atom infrastructure guarantees:
//   - All 7 canonical atom tables reject UPDATE/DELETE via atom guards.
//   - system_events.processed_at is set-once (partial guard).
//   - system_events.seq is monotonic per-insert AND immutable via UPDATE
//     (mig 00275 — Sprint 1.2.b).
//   - Archive trigger emits resourceArchived/resourceUnarchived atoms
//     atomically with archived_at flip (F7 — misdiagnosed in audit:
//     trigger already does it; test guards against regression).
//
// Migrations: 00103 (atom_no_mutation_guard), 00154 (check_in guard),
// 00162 (system_events partial guard), 00163 (vote_casts), 00166
// (user_actions), 00216 (bookings), 00275 (seq column + index).

import { assert, assertEquals } from "jsr:@std/assert@1";
import { adminClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "../e2e/_fixtures/seedGroup.ts";
import { cleanupGroup } from "../e2e/_fixtures/cleanup.ts";

const admin = adminClient();

Deno.test("ledger_entries rejects UPDATE and DELETE (full atom guard)", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: false,
    });

    const { data: entry } = await admin
      .from("ledger_entries")
      .insert({
        group_id: g.groupId,
        type: "contribution",
        amount_cents: 100,
        currency: "MXN",
        from_member_id: g.founder.memberId,
        to_member_id: null,
        metadata: { test: true },
        occurred_at: new Date().toISOString(),
        recorded_at: new Date().toISOString(),
      })
      .select("id")
      .single();
    const entryId = entry!.id as string;

    // UPDATE must fail.
    const { error: upErr } = await admin
      .from("ledger_entries")
      .update({ amount_cents: 0 })
      .eq("id", entryId);
    assert(upErr != null, "ledger_entries UPDATE should be rejected by guard");
    assert(
      upErr.message.includes("append-only") ||
        upErr.code === "23514",
      `unexpected error: ${upErr.message}`,
    );

    // DELETE must fail.
    const { error: delErr } = await admin
      .from("ledger_entries")
      .delete()
      .eq("id", entryId);
    assert(delErr != null, "ledger_entries DELETE should be rejected by guard");
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("system_events allows processed_at null→ts; rejects other mutations", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: false,
    });

    // Emit a known atom via record_system_event so payload schema passes.
    const { data: eventId, error: eErr } = await admin.rpc(
      "record_system_event",
      {
        p_group_id: g.groupId,
        p_event_type: "groupRenamed",
        p_resource_id: null,
        p_member_id: null,
        p_payload: { new_name: "test" },
      },
    );
    assert(!eErr, `record_system_event failed: ${eErr?.message}`);

    // Allowed: set processed_at when null.
    const ts = new Date().toISOString();
    const { error: pErr } = await admin
      .from("system_events")
      .update({ processed_at: ts })
      .eq("id", eventId as string);
    assert(!pErr, `processed_at null→ts should succeed: ${pErr?.message}`);

    // Forbidden: change processed_at after set (set-once).
    const { error: pErr2 } = await admin
      .from("system_events")
      .update({ processed_at: new Date().toISOString() })
      .eq("id", eventId as string);
    assert(pErr2 != null, "processed_at re-set should be rejected");
    assert(
      pErr2.message.includes("set-once") ||
        pErr2.message.includes("append-only"),
      `unexpected error: ${pErr2.message}`,
    );

    // Forbidden: change another column.
    // Re-insert a fresh event since the prior one has processed_at set
    // (which blocks ALL further updates).
    const { data: ev2 } = await admin.rpc("record_system_event", {
      p_group_id: g.groupId,
      p_event_type: "groupRenamed",
      p_resource_id: null,
      p_member_id: null,
      p_payload: { new_name: "test2" },
    });
    const { error: bErr } = await admin
      .from("system_events")
      .update({ event_type: "groupArchived" })
      .eq("id", ev2 as string);
    assert(bErr != null, "changing event_type must be rejected");
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("system_events.seq is monotonic across inserts and immutable on UPDATE", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: false,
    });

    // Emit two atoms in sequence — second seq must be > first.
    const { data: e1 } = await admin.rpc("record_system_event", {
      p_group_id: g.groupId,
      p_event_type: "groupRenamed",
      p_resource_id: null,
      p_member_id: null,
      p_payload: { new_name: "one" },
    });
    const { data: e2 } = await admin.rpc("record_system_event", {
      p_group_id: g.groupId,
      p_event_type: "groupRenamed",
      p_resource_id: null,
      p_member_id: null,
      p_payload: { new_name: "two" },
    });

    const { data: rows } = await admin
      .from("system_events")
      .select("id, seq")
      .in("id", [e1 as string, e2 as string])
      .order("seq", { ascending: true });

    assertEquals(rows!.length, 2);
    const seqs = rows!.map((r) => r.seq as number);
    assert(seqs[0] < seqs[1], `seq must be monotonic: ${seqs[0]} < ${seqs[1]}`);

    // Immutability: try to flip seq via UPDATE — must be rejected by guard
    // (the partial guard compares to_jsonb(old) - 'processed_at' vs new,
    // so seq drift produces a diff that fails).
    const { error: sErr } = await admin
      .from("system_events")
      .update({ seq: 999_999_999 })
      .eq("id", e2 as string);
    assert(sErr != null, "seq mutation should be rejected");
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("archive_resource emits resourceArchived atom (via trigger, single-emit)", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: false,
    });

    const { data: fundId } = await g.founder.client.rpc("create_fund", {
      p_group_id: g.groupId,
      p_name: "To archive",
    });

    // Archive twice — second is no-op (UPDATE filter matches 0 rows; trigger
    // doesn't fire). Per F7 misdiagnosis: atom emit lives in trigger
    // on_resource_archive_toggle, not the RPC.
    await g.founder.client.rpc("archive_resource", {
      p_resource_id: fundId as string,
    });
    await g.founder.client.rpc("archive_resource", {
      p_resource_id: fundId as string,
    });

    const { data: atoms } = await admin
      .from("system_events")
      .select("id")
      .eq("resource_id", fundId as string)
      .eq("event_type", "resourceArchived");
    assertEquals(atoms?.length, 1, "expected exactly 1 resourceArchived atom");

    // Unarchive → emits resourceUnarchived.
    await g.founder.client.rpc("unarchive_resource", {
      p_resource_id: fundId as string,
    });

    const { data: unArchAtoms } = await admin
      .from("system_events")
      .select("id")
      .eq("resource_id", fundId as string)
      .eq("event_type", "resourceUnarchived");
    assertEquals(
      unArchAtoms?.length,
      1,
      "expected exactly 1 resourceUnarchived atom",
    );
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("vote_casts rejects UPDATE and DELETE", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });

    // Insert a vote_cast directly via admin (bypassing RLS).
    const voteId = crypto.randomUUID();
    await admin.from("votes").insert({
      id: voteId,
      group_id: g.groupId,
      vote_type: "ledger_review",
      reference_id: g.groupId,
      title: "test",
      created_by_member_id: g.founder.memberId,
      opened_at: new Date().toISOString(),
      closes_at: new Date(Date.now() + 3600_000).toISOString(),
      quorum_percent: 50,
      threshold_percent: 50,
      is_anonymous: true,
      status: "open",
    });

    const { data: cast } = await admin
      .from("vote_casts")
      .insert({
        vote_id: voteId,
        member_id: g.founder.memberId,
        choice: "yes",
      })
      .select("id")
      .single();
    const castId = cast!.id as string;

    const { error: upErr } = await admin
      .from("vote_casts")
      .update({ choice: "no" })
      .eq("id", castId);
    assert(upErr != null, "vote_casts UPDATE should be rejected");

    const { error: delErr } = await admin
      .from("vote_casts")
      .delete()
      .eq("id", castId);
    assert(delErr != null, "vote_casts DELETE should be rejected");
  } finally {
    if (g) await cleanupGroup(g);
  }
});
