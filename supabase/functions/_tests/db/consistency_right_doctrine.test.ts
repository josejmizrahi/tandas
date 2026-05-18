// supabase/functions/_tests/db/consistency_right_doctrine.test.ts
//
// Covers ConsistencyAudit_2026-05-17 findings F2 + F10 + F20:
//   - right_state_view derives holder/delegate/status from system_events
//     (atom-driven; resources.metadata is no longer source of truth).
//   - transfer_right / delegate_right / revoke_right / suspend_right /
//     restore_right / exercise_right emit atoms only — they do NOT mutate
//     resources.metadata for lifecycle keys.
//   - update_right_metadata emits rightMetadataUpdated atom with
//     {updated_by, diff: {key: {old, new}}}; no-op patches emit nothing.
//
// Migrations: 00278 (right_state_view + right_holders_view wrapper),
// 00279 (atom-only RPCs), 00280 (rightMetadataUpdated diff atom).

import { assert, assertEquals } from "jsr:@std/assert@1";
import { adminClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "../e2e/_fixtures/seedGroup.ts";
import { cleanupGroup } from "../e2e/_fixtures/cleanup.ts";

const admin = adminClient();

Deno.test("right_state_view derives holder + status from atoms (full lifecycle)", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const alice = g.members[0];
    const bob = g.members[1];

    // create_right — Alice as holder, transferable so Bob can receive it.
    const { data: rightId, error: cErr } = await alice.client.rpc(
      "create_right",
      {
        p_group_id: g.groupId,
        p_name: "Test Right",
        p_holder_member_id: alice.memberId,
        p_target_resource_id: null,
        p_target_capability: null,
        p_scope: "resource",
        p_priority: 0,
        p_exclusive: false,
        p_transferable: true,
        p_delegable: false,
        p_divisible: false,
      },
    );
    assert(!cErr, `create_right failed: ${cErr?.message}`);

    // after_create
    let { data: view } = await admin
      .from("right_state_view")
      .select("status, holder_member_id")
      .eq("right_id", rightId as string)
      .single();
    assertEquals(view!.status, "active");
    assertEquals(view!.holder_member_id, alice.memberId);

    // transfer to Bob
    const { error: tErr } = await alice.client.rpc("transfer_right", {
      p_right_id: rightId as string,
      p_to_member_id: bob.memberId,
      p_reason: "gift",
    });
    assert(!tErr, `transfer_right failed: ${tErr?.message}`);

    ({ data: view } = await admin
      .from("right_state_view")
      .select("status, holder_member_id")
      .eq("right_id", rightId as string)
      .single());
    assertEquals(view!.status, "active");
    assertEquals(view!.holder_member_id, bob.memberId);

    // revoke
    const { error: rErr } = await alice.client.rpc("revoke_right", {
      p_right_id: rightId as string,
      p_reason: "misuse",
    });
    assert(!rErr, `revoke_right failed: ${rErr?.message}`);

    ({ data: view } = await admin
      .from("right_state_view")
      .select("status, holder_member_id")
      .eq("right_id", rightId as string)
      .single());
    assertEquals(view!.status, "revoked");
    assertEquals(
      view!.holder_member_id,
      bob.memberId,
      "revocation does not change holder",
    );

    // restore
    const { error: resErr } = await alice.client.rpc("restore_right", {
      p_right_id: rightId as string,
      p_reason: "ok",
    });
    assert(!resErr, `restore_right failed: ${resErr?.message}`);

    ({ data: view } = await admin
      .from("right_state_view")
      .select("status")
      .eq("right_id", rightId as string)
      .single());
    assertEquals(view!.status, "active");

    // Idempotent revoke after second revoke.
    await alice.client.rpc("revoke_right", {
      p_right_id: rightId as string,
      p_reason: "final",
    });
    const { error: dupErr } = await alice.client.rpc("revoke_right", {
      p_right_id: rightId as string,
      p_reason: "final",
    });
    assert(!dupErr, `second revoke should be idempotent: ${dupErr?.message}`);

    // Only one rightRevoked atom per revoke wave (second was no-op).
    const { data: revAtoms } = await admin
      .from("system_events")
      .select("id")
      .eq("resource_id", rightId as string)
      .eq("event_type", "rightRevoked");
    assertEquals(
      revAtoms?.length,
      2,
      "expected 2 rightRevoked atoms (initial + final), second revoke was no-op",
    );
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("right lifecycle RPCs do NOT mutate resources.metadata holder/suspended keys", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const alice = g.members[0];
    const bob = g.members[1];

    const { data: rightId } = await alice.client.rpc("create_right", {
      p_group_id: g.groupId,
      p_name: "Test",
      p_holder_member_id: alice.memberId,
      p_target_resource_id: null,
      p_target_capability: null,
      p_scope: "resource",
      p_priority: 0,
      p_exclusive: false,
      p_transferable: true,
      p_delegable: true,
      p_divisible: false,
    });

    // After create: metadata.holder_member_id is set by create_right (genesis).
    // Subsequent lifecycle RPCs MUST NOT update it.
    const { data: metaBefore } = await admin
      .from("resources")
      .select("metadata")
      .eq("id", rightId as string)
      .single();
    const holderBefore =
      (metaBefore!.metadata as Record<string, unknown>).holder_member_id;

    // transfer → atom only
    await alice.client.rpc("transfer_right", {
      p_right_id: rightId as string,
      p_to_member_id: bob.memberId,
      p_reason: "x",
    });
    // suspend → atom only
    await alice.client.rpc("suspend_right", {
      p_right_id: rightId as string,
      p_until: null,
      p_reason: "x",
    });
    // restore → atom only
    await alice.client.rpc("restore_right", {
      p_right_id: rightId as string,
      p_reason: "x",
    });

    const { data: metaAfter } = await admin
      .from("resources")
      .select("metadata, status")
      .eq("id", rightId as string)
      .single();
    const meta = metaAfter!.metadata as Record<string, unknown>;

    // holder_member_id in metadata is STALE (still Alice) — view is truth.
    assertEquals(
      meta.holder_member_id,
      holderBefore,
      "metadata.holder_member_id should be stale (not updated by transfer)",
    );

    // suspended_* keys should NEVER appear (suspend+restore left no residue).
    assert(
      !("suspended_at" in meta),
      "metadata.suspended_at must not be set after restore",
    );
    assert(
      !("suspended_until" in meta),
      "metadata.suspended_until must not be set after restore",
    );
    assert(
      !("suspended_by" in meta),
      "metadata.suspended_by must not be set after restore",
    );

    // resources.status is stale ('active' from create_right) — view-derived
    // status is the truth, not the column.
    assertEquals(
      metaAfter!.status,
      "active",
      "resources.status stays at create-time value; view is the truth",
    );

    // View reports actual current state (status='active' after restore, holder=Bob).
    const { data: view } = await admin
      .from("right_state_view")
      .select("status, holder_member_id")
      .eq("right_id", rightId as string)
      .single();
    assertEquals(view!.status, "active");
    assertEquals(view!.holder_member_id, bob.memberId);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("update_right_metadata emits rightMetadataUpdated diff atom; no-op skipped", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: false,
    });
    const alice = g.founder;

    const { data: rightId } = await alice.client.rpc("create_right", {
      p_group_id: g.groupId,
      p_name: "Old Name",
      p_holder_member_id: alice.memberId,
      p_target_resource_id: null,
      p_target_capability: null,
      p_scope: "resource",
      p_priority: 5,
      p_exclusive: false,
      p_transferable: true,
      p_delegable: false,
      p_divisible: false,
    });

    // Change name + priority — should emit 1 atom with combined diff.
    const { error: u1Err } = await alice.client.rpc("update_right_metadata", {
      p_right_id: rightId as string,
      p_patch: { name: "New Name", priority: 10 },
    });
    assert(!u1Err, `update 1 failed: ${u1Err?.message}`);

    // No-op call — should NOT emit a second atom.
    const { error: u2Err } = await alice.client.rpc("update_right_metadata", {
      p_right_id: rightId as string,
      p_patch: { name: "New Name", priority: 10 },
    });
    assert(!u2Err, `update 2 (no-op) failed: ${u2Err?.message}`);

    // Partial diff — only transferable changes.
    const { error: u3Err } = await alice.client.rpc("update_right_metadata", {
      p_right_id: rightId as string,
      p_patch: { transferable: false },
    });
    assert(!u3Err, `update 3 failed: ${u3Err?.message}`);

    // Verify 2 atoms total (first + third call; no-op skipped).
    const { data: atoms } = await admin
      .from("system_events")
      .select("payload")
      .eq("resource_id", rightId as string)
      .eq("event_type", "rightMetadataUpdated")
      .order("occurred_at", { ascending: true });

    assertEquals(atoms?.length, 2, "expected 2 rightMetadataUpdated atoms");

    const firstDiff = (atoms![0].payload as Record<string, unknown>).diff as
      Record<string, { old: unknown; new: unknown }>;
    assertEquals(firstDiff.name.old, "Old Name");
    assertEquals(firstDiff.name.new, "New Name");
    assertEquals(firstDiff.priority.old, 5);
    assertEquals(firstDiff.priority.new, 10);

    const secondDiff =
      (atoms![1].payload as Record<string, unknown>).diff as Record<
        string,
        { old: unknown; new: unknown }
      >;
    assertEquals(secondDiff.transferable.old, true);
    assertEquals(secondDiff.transferable.new, false);
    // Only one key in the partial diff.
    assertEquals(Object.keys(secondDiff).length, 1);

    // Metadata cache also updated (acceptable since atom is paired).
    const { data: meta } = await admin
      .from("resources")
      .select("metadata")
      .eq("id", rightId as string)
      .single();
    const m = meta!.metadata as Record<string, unknown>;
    assertEquals(m.name, "New Name");
    assertEquals(m.priority, 10);
    assertEquals(m.transferable, false);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("transfer_right rejects when right.transferable=false", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const alice = g.members[0];
    const bob = g.members[1];

    const { data: rightId } = await alice.client.rpc("create_right", {
      p_group_id: g.groupId,
      p_name: "Non-transferable",
      p_holder_member_id: alice.memberId,
      p_target_resource_id: null,
      p_target_capability: null,
      p_scope: "resource",
      p_priority: 0,
      p_exclusive: false,
      p_transferable: false,
      p_delegable: false,
      p_divisible: false,
    });

    const { error } = await alice.client.rpc("transfer_right", {
      p_right_id: rightId as string,
      p_to_member_id: bob.memberId,
      p_reason: "try",
    });
    assert(error != null, "transfer_right should reject non-transferable");
    assert(
      error.message.includes("not transferable"),
      `unexpected error: ${error.message}`,
    );
  } finally {
    if (g) await cleanupGroup(g);
  }
});
