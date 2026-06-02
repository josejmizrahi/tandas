// supabase/functions/_tests/db/role_write_guards.test.ts
//
// Sprint B (mig 00285 + 00286 + 00287 + 00288) — guards on roles columns
// + cascade atoms. Plans/Active/RolesRemediation_2026-05-17.md.
//
// Covers:
//   1. assign_role / unassign_role still work (RPC path bypass)
//   2. upsert_group_role emits groupRolesChanged (op=created)
//   3. upsert_group_role emits groupRolesChanged (op=updated) on re-upsert
//   4. delete_group_role emits groupRolesChanged op=deleted + N
//      roleUnassigned (cause=role_deleted)
//   5. direct UPDATE group_members.roles by an authenticated admin (via
//      userClient) raises 42501 — the heresy path
//   6. direct UPDATE groups.roles by an authenticated admin raises 42501
//   7. service_role (auth.uid IS NULL) bypass on both tables still works
//      (migration / cron path)

import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { adminClient, userClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "../e2e/_fixtures/seedGroup.ts";
import { cleanupGroup } from "../e2e/_fixtures/cleanup.ts";

const admin = adminClient();

// -----------------------------------------------------------------------------
// 1. RPC bypass still works
// -----------------------------------------------------------------------------

Deno.test("Sprint B — assign_role still works through RPC funnel", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const bob = g.members[1];

    // Create an 'admin' role (system roles seeded by create_group_with_admin
    // depend on template — be explicit to keep this test self-contained).
    await admin.rpc("upsert_group_role", {
      p_group_id: g.groupId,
      p_role_id: "qa_admin",
      p_label: "QA Admin",
      p_permissions: ["modifyGovernance", "modifyMembers"],
      p_max_holders: null,
    }).throwOnError();

    const assign = await admin.rpc("assign_role", {
      p_group_id: g.groupId,
      p_user_id: bob.userId,
      p_role: "qa_admin",
    }).throwOnError();
    assert(assign.data !== null, "assign_role returned null");

    const { data: bobRow } = await admin.from("group_members")
      .select("roles").eq("group_id", g.groupId).eq("user_id", bob.userId).single();
    assert((bobRow!.roles as string[]).includes("qa_admin"),
      `expected qa_admin in roles, got ${JSON.stringify(bobRow!.roles)}`);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("Sprint B — unassign_role still works through RPC funnel", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const bob = g.members[1];

    await admin.rpc("upsert_group_role", {
      p_group_id: g.groupId,
      p_role_id: "qa_moderator",
      p_permissions: ["modifyRules"],
    }).throwOnError();

    await admin.rpc("assign_role", {
      p_group_id: g.groupId, p_user_id: bob.userId, p_role: "qa_moderator",
    }).throwOnError();

    await admin.rpc("unassign_role", {
      p_group_id: g.groupId, p_user_id: bob.userId, p_role: "qa_moderator",
    }).throwOnError();

    const { data: bobRow } = await admin.from("group_members")
      .select("roles").eq("group_id", g.groupId).eq("user_id", bob.userId).single();
    assert(!(bobRow!.roles as string[]).includes("qa_moderator"),
      `expected qa_moderator stripped, got ${JSON.stringify(bobRow!.roles)}`);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

// -----------------------------------------------------------------------------
// 2. Catalog atoms
// -----------------------------------------------------------------------------

Deno.test("Sprint B — upsert_group_role emits groupRolesChanged op=created", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({ memberSpecs: [{ handle: "alice" }], seedDinnerRules: false });

    await admin.rpc("upsert_group_role", {
      p_group_id: g.groupId,
      p_role_id: "qa_treasurer",
      p_label: "Treasurer",
      p_permissions: ["fundContribute", "fundAudit"],
      p_max_holders: 1,
    }).throwOnError();

    const { data: events } = await admin.from("system_events")
      .select("event_type, payload")
      .eq("group_id", g.groupId)
      .eq("event_type", "groupRolesChanged")
      .order("at", { ascending: false });

    assert(events && events.length > 0, "expected groupRolesChanged atom");
    const evt = events[0] as { payload: Record<string, unknown> };
    assertEquals(evt.payload.op, "created");
    assertEquals(evt.payload.role_id, "qa_treasurer");
    assertEquals(evt.payload.system, false);
    assertEquals((evt.payload.permissions as string[]).sort(),
      ["fundAudit", "fundContribute"].sort());
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("Sprint B — upsert_group_role emits op=updated on re-upsert", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({ memberSpecs: [{ handle: "alice" }], seedDinnerRules: false });

    await admin.rpc("upsert_group_role", {
      p_group_id: g.groupId, p_role_id: "qa_role", p_permissions: ["modifyRules"],
    }).throwOnError();

    await admin.rpc("upsert_group_role", {
      p_group_id: g.groupId, p_role_id: "qa_role", p_permissions: ["modifyRules", "modifyMembers"],
    }).throwOnError();

    const { data: events } = await admin.from("system_events")
      .select("payload")
      .eq("group_id", g.groupId)
      .eq("event_type", "groupRolesChanged")
      .order("at", { ascending: true });

    assertEquals(events!.length, 2, "expected 2 atoms (created + updated)");
    assertEquals((events![0] as { payload: Record<string, unknown> }).payload.op, "created");
    assertEquals((events![1] as { payload: Record<string, unknown> }).payload.op, "updated");
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("Sprint B — delete_group_role cascade emits roleUnassigned per holder", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }, { handle: "carol" }],
      seedDinnerRules: false,
    });
    const [, bob, carol] = g.members;

    await admin.rpc("upsert_group_role", {
      p_group_id: g.groupId, p_role_id: "qa_moderator", p_permissions: ["modifyRules"],
    }).throwOnError();

    await admin.rpc("assign_role", {
      p_group_id: g.groupId, p_user_id: bob.userId, p_role: "qa_moderator",
    }).throwOnError();
    await admin.rpc("assign_role", {
      p_group_id: g.groupId, p_user_id: carol.userId, p_role: "qa_moderator",
    }).throwOnError();

    await admin.rpc("delete_group_role", {
      p_group_id: g.groupId, p_role_id: "qa_moderator",
    }).throwOnError();

    // Verify per-holder roleUnassigned atoms.
    const { data: unassigns } = await admin.from("system_events")
      .select("payload, member_id")
      .eq("group_id", g.groupId)
      .eq("event_type", "roleUnassigned");

    const cascadeAtoms = (unassigns ?? []).filter((e: { payload: Record<string, unknown> }) =>
      e.payload.cause === "role_deleted" && e.payload.role === "qa_moderator"
    );
    assertEquals(cascadeAtoms.length, 2,
      `expected 2 cascade roleUnassigned atoms, got ${cascadeAtoms.length}`);

    // Verify catalog deletion atom.
    const { data: catChanges } = await admin.from("system_events")
      .select("payload")
      .eq("group_id", g.groupId)
      .eq("event_type", "groupRolesChanged");

    const deleted = (catChanges ?? []).find((e: { payload: Record<string, unknown> }) =>
      e.payload.op === "deleted" && e.payload.role_id === "qa_moderator"
    );
    assert(deleted, "expected groupRolesChanged op=deleted");

    // Verify catalog actually purged.
    const { data: gRow } = await admin.from("groups")
      .select("roles").eq("id", g.groupId).single();
    assert(!Object.keys(gRow!.roles as Record<string, unknown>).includes("qa_moderator"),
      "expected qa_moderator stripped from groups.roles");

    // Verify each member actually has the role stripped.
    const { data: members } = await admin.from("group_members")
      .select("user_id, roles").eq("group_id", g.groupId)
      .in("user_id", [bob.userId, carol.userId]);
    for (const m of (members ?? []) as { user_id: string; roles: string[] }[]) {
      assert(!m.roles.includes("qa_moderator"),
        `member ${m.user_id} still holds qa_moderator: ${JSON.stringify(m.roles)}`);
    }
  } finally {
    if (g) await cleanupGroup(g);
  }
});

// -----------------------------------------------------------------------------
// 3. Heresy paths — direct REST UPDATE must fail
// -----------------------------------------------------------------------------

Deno.test("Sprint B — direct UPDATE group_members.roles by founder raises 42501", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const founder = g.founder;
    const bob = g.members[1];

    // Founder is admin per create_group_with_admin. RLS members_update_admin
    // permits the UPDATE; the new trigger must reject it.
    const client = userClient(founder.accessToken);
    const { error } = await client.from("group_members")
      .update({ roles: ["member", "founder", "ghost_role"] })
      .eq("group_id", g.groupId)
      .eq("user_id", bob.userId);

    assert(error !== null, "expected error, got none");
    assertEquals(error!.code, "42501",
      `expected 42501, got ${error!.code}: ${error!.message}`);
    assert(error!.message.includes("group_members.roles"),
      `expected guard message, got: ${error!.message}`);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("Sprint B — direct UPDATE groups.roles by founder raises 42501", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({ memberSpecs: [{ handle: "alice" }], seedDinnerRules: false });
    const founder = g.founder;

    const client = userClient(founder.accessToken);
    const { error } = await client.from("groups")
      .update({ roles: { ghost: { system: false, permissions: [] } } })
      .eq("id", g.groupId);

    assert(error !== null, "expected error, got none");
    assertEquals(error!.code, "42501",
      `expected 42501, got ${error!.code}: ${error!.message}`);
    assert(error!.message.includes("groups.roles"),
      `expected guard message, got: ${error!.message}`);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

// -----------------------------------------------------------------------------
// 4. service_role bypass — migrations / cron jobs / fixtures
// -----------------------------------------------------------------------------

Deno.test("Sprint B — service_role bypass on group_members.roles still works", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const bob = g.members[1];

    // admin client = service_role JWT. auth.uid() IS NULL in this context,
    // guard short-circuits to allow.
    const { error } = await admin.from("group_members")
      .update({ roles: ["member"] })
      .eq("group_id", g.groupId)
      .eq("user_id", bob.userId);
    assertEquals(error, null, `expected null error, got: ${error?.message}`);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("Sprint B — service_role bypass on groups.roles still works", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({ memberSpecs: [{ handle: "alice" }], seedDinnerRules: false });

    // Read current to avoid clobbering the founder/member seed.
    const { data: row } = await admin.from("groups").select("roles").eq("id", g.groupId).single();
    const { error } = await admin.from("groups")
      .update({ roles: row!.roles })
      .eq("id", g.groupId);
    assertEquals(error, null, `expected null error, got: ${error?.message}`);
  } finally {
    if (g) await cleanupGroup(g);
  }
});
