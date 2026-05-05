# EditRulesView Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lift the read-only restriction on `RulesView` so founders (and other roles per group governance) can toggle preset rules, edit flat fine amounts, and propose archive — closing the central gap that ruul cannot honor "each group writes its own social contract" past onboarding step 6.

**Architecture:** Backend-first dependency chain. Postgres migrations 00024 (`can_modify_rules` SQL function + `rules`-mutation audit trigger + RLS policy swap) and 00025 (unique index on open votes) ship first with deno tests covering the SQL + RLS contract. Then iOS layer: `GroupRule.fineShape` typed shape parser, `RuleRepository` UPDATE methods, `RuleSummaryFormatter` human-readable strings, `EditRulesCoordinator` with `canEditRules` flag, `EditRulesView` list with optimistic toggles + sync indicators, `EditRuleSheet` modal with flat-amount editor and archive button. RulesView gains a conditional pencil button.

**Tech Stack:** Postgres (Supabase), Deno 2.x for backend tests, Swift 6 + SwiftUI on iOS 26, supabase-swift SDK, existing codegen pipeline (no changes needed; the two new SystemEventTypes already shipped in `e266a16`).

**Spec reference:** `docs/superpowers/specs/2026-05-05-edit-rules-view-design.md` (commits `3a6d2ac` → `09fdb89`, pushed to origin/main).

**Pre-shipped foundation:** commit `e266a16` added `ruleEnabledChanged` and `ruleAmountChanged` to `SystemEventType` and the matching arms in `HistoryItemPresentation`. Codegen pipeline regenerated outputs automatically. No further enum work needed.

---

## File Structure

**New backend files:**
- `supabase/migrations/00024_rule_mutation_audit.sql`
- `supabase/migrations/00024_rollback.sql`
- `supabase/migrations/00025_unique_open_vote_per_reference.sql`
- `supabase/migrations/00025_rollback.sql`
- `supabase/functions/_tests/db/rule_mutation_audit.test.ts`
- `supabase/functions/_tests/db/vote_unique_open.test.ts`
- `supabase/functions/_tests/db/can_modify_rules.test.ts`
- `supabase/functions/_tests/db/rls_update_rules.test.ts`

**New iOS files:**
- `ios/Tandas/Platform/Models/GroupRule+FineShape.swift`
- `ios/TandasTests/Rules/RuleFineShapeTests.swift`
- `ios/TandasTests/Rules/RulesRepositoryTests.swift`
- `ios/TandasTests/Rules/EditRulesCoordinatorTests.swift`
- `ios/Tandas/Features/Rules/RuleSummaryFormatter.swift`
- `ios/Tandas/Features/Rules/EditRulesCoordinator.swift`
- `ios/Tandas/Features/Rules/EditRulesView.swift`
- `ios/Tandas/Features/Rules/EditRuleSheet.swift`

**Modified iOS files:**
- `ios/Tandas/Features/Rules/RulesView.swift` (conditional pencil button only)
- `ios/Tandas/Features/Rules/RulesCoordinator.swift` (add `canEditRules` flag)
- `ios/Tandas/Supabase/Repos/RuleRepository.swift` (add `setEnabled`, `setFlatFineAmount`, `pendingRepealVote` to protocol + Mock + Live; add `Vote` value type or import)

---

## Phase A — Backend (6 commits)

### Task A1: Migration 00024 — `can_modify_rules` + audit trigger + RLS swap

**Files:**
- Create: `supabase/migrations/00024_rule_mutation_audit.sql`
- Create: `supabase/migrations/00024_rollback.sql`

- [ ] **Step 1: Inspect the current `rules_update_admin` policy and capture for rollback**

Run: `grep -A 2 "rules_update_admin" supabase/migrations/00002_rls.sql`
Expected output:
```
create policy "rules_update_admin" on public.rules for update to authenticated
using (public.is_group_admin(group_id, auth.uid())) with check (public.is_group_admin(group_id, auth.uid()));
```

Save this exact text — the rollback restores it verbatim.

- [ ] **Step 2: Create `supabase/migrations/00024_rule_mutation_audit.sql`**

```sql
-- 00024_rule_mutation_audit.sql
-- Adds:
--   1. public.can_modify_rules(group_id, user_id) — governance-aware UPDATE gate.
--   2. public.emit_rule_mutation_events() trigger fn — atomic audit emission
--      for rules.enabled / rules.consequences mutations.
--   3. rules_mutation_audit AFTER UPDATE trigger.
--   4. Replaces rules_update_admin policy with rules_update_governance which
--      consults can_modify_rules instead of is_group_admin.
--
-- Companion to EditRulesView (Plan UI P0 #1, Fase 0 #5).

-- ───────────────────────────────────────────────────────────────────────
-- 1. can_modify_rules — single source of truth for "can this user UPDATE
--    rules in this group?". Consulted by RLS and (in a follow-up) by
--    GovernanceService.canPerform(.modifyRules).
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.can_modify_rules(p_group_id uuid, p_user_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_governance_value text;
  v_member group_members;
begin
  select * into v_member
  from public.group_members
  where group_id = p_group_id and user_id = p_user_id and active
  limit 1;
  if not found then return false; end if;

  select governance->>'whoCanModifyRules' into v_governance_value
  from public.groups where id = p_group_id;

  return case v_governance_value
    when 'founder'   then v_member.role = 'founder'
    when 'anyMember' then true
    -- 'majorityVote' / 'supermajorityVote' / 'host' / 'treasurer' all
    -- require routing through a vote (or a non-V1 path); direct UPDATE
    -- is denied so client checks must funnel users to the vote flow.
    else false
  end;
end;
$$;

revoke execute on function public.can_modify_rules(uuid, uuid) from public, anon;
grant  execute on function public.can_modify_rules(uuid, uuid) to authenticated;

comment on function public.can_modify_rules(uuid, uuid) is
  'Returns true if the user may UPDATE rules in the group, per governance.whoCanModifyRules. '
  'Added 2026-05-05 with EditRulesView (Plan UI P0 #1).';

-- ───────────────────────────────────────────────────────────────────────
-- 2. emit_rule_mutation_events — fires AFTER UPDATE on rules; emits one
--    system_events row per mutated column (enabled, consequences). Both
--    are emitted if both change in the same statement.
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.emit_rule_mutation_events()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
begin
  select id into v_member_id
  from public.group_members
  where group_id = new.group_id
    and user_id = auth.uid()
    and active
  limit 1;

  if new.enabled is distinct from old.enabled then
    insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
    values (new.group_id, 'ruleEnabledChanged', new.id, v_member_id, jsonb_build_object(
      'rule_title', new.title,
      'before', old.enabled,
      'after', new.enabled
    ));
  end if;

  if new.consequences is distinct from old.consequences then
    insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
    values (new.group_id, 'ruleAmountChanged', new.id, v_member_id, jsonb_build_object(
      'rule_title', new.title,
      'before', old.consequences,
      'after', new.consequences
    ));
  end if;

  return new;
end;
$$;

comment on function public.emit_rule_mutation_events() is
  'Emits ruleEnabledChanged / ruleAmountChanged system_events atomically on UPDATE. '
  'Added 2026-05-05 as part of EditRulesView (Plan UI P0 #1).';

-- ───────────────────────────────────────────────────────────────────────
-- 3. Trigger wiring.
-- ───────────────────────────────────────────────────────────────────────
drop trigger if exists rules_mutation_audit on public.rules;
create trigger rules_mutation_audit
after update on public.rules
for each row
execute function public.emit_rule_mutation_events();

-- ───────────────────────────────────────────────────────────────────────
-- 4. Swap UPDATE policy: was is_group_admin, now governance-aware.
--    The previous policy gated UPDATE behind admin role only. The new
--    policy consults whoCanModifyRules so groups configured for
--    'founder' or 'anyMember' get direct edits and groups configured
--    for 'majorityVote' / 'supermajorityVote' must route through votes.
-- ───────────────────────────────────────────────────────────────────────
drop policy if exists "rules_update_admin" on public.rules;
create policy "rules_update_governance" on public.rules for update to authenticated
using (public.can_modify_rules(group_id, auth.uid()))
with check (public.can_modify_rules(group_id, auth.uid()));
```

- [ ] **Step 3: Create `supabase/migrations/00024_rollback.sql`**

```sql
-- Rollback for 00024_rule_mutation_audit.sql
-- Restores the previous rules_update_admin policy and drops the trigger,
-- function, and governance-aware policy added by 00024.

drop policy if exists "rules_update_governance" on public.rules;
create policy "rules_update_admin" on public.rules for update to authenticated
using (public.is_group_admin(group_id, auth.uid())) with check (public.is_group_admin(group_id, auth.uid()));

drop trigger if exists rules_mutation_audit on public.rules;
drop function if exists public.emit_rule_mutation_events();
drop function if exists public.can_modify_rules(uuid, uuid);
```

- [ ] **Step 4: Apply the migration to local supabase (or push to staging)**

Run: `supabase db push` (or use the project's standard apply pipeline — the user's CI applies via Supabase platform). Capture any error output.

If you don't have a local supabase stack, this task ends with the SQL files written; subsequent tests (A3–A6) will apply them via their fixture harness.

- [ ] **Step 5: Commit**

```sh
git add supabase/migrations/00024_rule_mutation_audit.sql supabase/migrations/00024_rollback.sql
git commit -m "$(cat <<'EOF'
feat(db): can_modify_rules + audit trigger + governance-aware RLS

Phase A1 of EditRulesView. Migration 00024 introduces:
- can_modify_rules(group_id, user_id) — single source of truth for
  "can this user UPDATE rules in this group" per governance.whoCanModifyRules
- emit_rule_mutation_events trigger — atomic audit emission for
  rules.enabled / rules.consequences mutations
- rules_update_governance policy replacing rules_update_admin

The previous policy gated UPDATE behind admin role only. The new
policy gates UPDATE on the governance config so 'founder'/'anyMember'
modes allow direct edits while 'majorityVote'/'supermajorityVote'
modes deny direct UPDATE (mutations must route through votes).

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task A2: Migration 00025 — unique index on open votes

**Files:**
- Create: `supabase/migrations/00025_unique_open_vote_per_reference.sql`
- Create: `supabase/migrations/00025_rollback.sql`

- [ ] **Step 1: Create `supabase/migrations/00025_unique_open_vote_per_reference.sql`**

```sql
-- 00025_unique_open_vote_per_reference.sql
-- Prevents two open votes simultaneously for the same (vote_type, reference_id).
-- Protects rule_repeal, fine_appeal, and any other reference-based vote_type
-- from accidental double-opens (race condition in start_vote).
-- General-proposal votes without reference_id are exempt.
--
-- Pre-flight: zero violators in production verified 2026-05-05.

create unique index uniq_open_vote_per_reference
on public.votes (vote_type, reference_id)
where status = 'open' and reference_id is not null;

comment on index public.uniq_open_vote_per_reference is
  'Prevents simultaneous open votes for the same (vote_type, reference_id). '
  'Added 2026-05-05 as part of EditRulesView (Plan UI P0 #1).';
```

- [ ] **Step 2: Create `supabase/migrations/00025_rollback.sql`**

```sql
-- Rollback for 00025_unique_open_vote_per_reference.sql

drop index if exists public.uniq_open_vote_per_reference;
```

- [ ] **Step 3: Apply (same harness as A1 step 4)**

- [ ] **Step 4: Commit**

```sh
git add supabase/migrations/00025_unique_open_vote_per_reference.sql supabase/migrations/00025_rollback.sql
git commit -m "$(cat <<'EOF'
feat(db): unique partial index on open votes by reference

Phase A2 of EditRulesView. Prevents two simultaneous open votes for
the same (vote_type, reference_id). Pre-flight verified zero violators
in production on 2026-05-05.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task A3: `rule_mutation_audit.test.ts`

**Files:**
- Create: `supabase/functions/_tests/db/rule_mutation_audit.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// supabase/functions/_tests/db/rule_mutation_audit.test.ts
//
// Covers migration 00024_rule_mutation_audit.sql:
//   - UPDATE rules.enabled flip → exactly 1 ruleEnabledChanged row.
//   - UPDATE rules.consequences → exactly 1 ruleAmountChanged row.
//   - Combined UPDATE → 2 rows.
//   - UPDATE that touches neither column → 0 rows.

import { assertEquals } from "jsr:@std/assert@1";
import { adminClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "../e2e/_fixtures/seedGroup.ts";
import { cleanupGroup } from "../e2e/_fixtures/cleanup.ts";

const admin = adminClient();

async function countRuleEvents(
  groupId: string,
  ruleId: string,
  eventType: "ruleEnabledChanged" | "ruleAmountChanged",
): Promise<number> {
  const { count, error } = await admin
    .from("system_events")
    .select("id", { count: "exact", head: true })
    .eq("group_id", groupId)
    .eq("resource_id", ruleId)
    .eq("event_type", eventType);
  if (error) throw error;
  return count ?? 0;
}

Deno.test("trigger emits ruleEnabledChanged on enabled flip", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });
    const { data: rules } = await admin.from("rules").select("id,enabled")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;
    const initial = rules![0].enabled as boolean;

    await admin.from("rules").update({ enabled: !initial }).eq("id", ruleId);

    assertEquals(await countRuleEvents(g.groupId, ruleId, "ruleEnabledChanged"), 1);
    assertEquals(await countRuleEvents(g.groupId, ruleId, "ruleAmountChanged"), 0);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("trigger emits ruleAmountChanged on consequences change", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });
    const { data: rules } = await admin.from("rules").select("id,consequences")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;

    const newConsequences = [{ type: "fine", config: { amount: 999 } }];
    await admin.from("rules").update({ consequences: newConsequences }).eq("id", ruleId);

    assertEquals(await countRuleEvents(g.groupId, ruleId, "ruleAmountChanged"), 1);
    assertEquals(await countRuleEvents(g.groupId, ruleId, "ruleEnabledChanged"), 0);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("trigger emits both events on combined UPDATE", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });
    const { data: rules } = await admin.from("rules").select("id,enabled,consequences")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;
    const initial = rules![0].enabled as boolean;

    await admin.from("rules").update({
      enabled: !initial,
      consequences: [{ type: "fine", config: { amount: 555 } }],
    }).eq("id", ruleId);

    assertEquals(await countRuleEvents(g.groupId, ruleId, "ruleEnabledChanged"), 1);
    assertEquals(await countRuleEvents(g.groupId, ruleId, "ruleAmountChanged"), 1);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("trigger emits zero events on UPDATE that touches neither column", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });
    const { data: rules } = await admin.from("rules").select("id,title")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;

    await admin.from("rules").update({ title: "Renamed for test" }).eq("id", ruleId);

    assertEquals(await countRuleEvents(g.groupId, ruleId, "ruleEnabledChanged"), 0);
    assertEquals(await countRuleEvents(g.groupId, ruleId, "ruleAmountChanged"), 0);
  } finally {
    if (g) await cleanupGroup(g);
  }
});
```

- [ ] **Step 2: Run test, expect fail or pass**

Run: `cd supabase/functions/_tests && deno test -A db/rule_mutation_audit.test.ts`

Expected: 4 PASS if migration 00024 is applied. If migration not applied yet (no local supabase), test errors with "function emit_rule_mutation_events does not exist" or similar — that's the "fail" gate of TDD; apply the migration via your supabase pipeline and rerun.

- [ ] **Step 3: Commit**

```sh
git add supabase/functions/_tests/db/rule_mutation_audit.test.ts
git commit -m "$(cat <<'EOF'
test(db): rule_mutation_audit covers trigger emit + non-emit paths

Phase A3 of EditRulesView. 4 tests:
  - enabled flip → 1 ruleEnabledChanged, 0 ruleAmountChanged
  - consequences change → 1 ruleAmountChanged, 0 ruleEnabledChanged
  - combined UPDATE → 1 of each
  - UPDATE that touches neither column → 0 events
    (verifies `is distinct from` works as expected and trigger
    does not spam-emit on metadata edits like title)

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task A4: `vote_unique_open.test.ts`

**Files:**
- Create: `supabase/functions/_tests/db/vote_unique_open.test.ts`

- [ ] **Step 1: Write the test**

```ts
// supabase/functions/_tests/db/vote_unique_open.test.ts
//
// Covers migration 00025_unique_open_vote_per_reference.sql:
//   - Two open votes with same (vote_type, reference_id) → second fails
//     with unique violation.
//   - After closing the first, opening a new one with same key → succeeds.

import { assert, assertRejects } from "jsr:@std/assert@1";
import { adminClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "../e2e/_fixtures/seedGroup.ts";
import { cleanupGroup } from "../e2e/_fixtures/cleanup.ts";

const admin = adminClient();

Deno.test("unique index blocks duplicate open vote on same (vote_type, reference_id)", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });
    const { data: rules } = await admin.from("rules").select("id")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;

    // First open vote — succeeds.
    const { error: firstErr } = await admin.from("votes").insert({
      group_id: g.groupId,
      vote_type: "rule_repeal",
      reference_id: ruleId,
      title: "Archive rule (first)",
      created_by_member_id: g.members[0].memberId,
      opened_at: new Date().toISOString(),
      closes_at: new Date(Date.now() + 72 * 3600 * 1000).toISOString(),
      quorum_percent: 50,
      threshold_percent: 50,
      is_anonymous: true,
      status: "open",
    });
    assert(!firstErr, `first insert failed: ${firstErr?.message}`);

    // Second open vote with same (vote_type, reference_id) — must fail.
    await assertRejects(
      async () => {
        const { error } = await admin.from("votes").insert({
          group_id: g!.groupId,
          vote_type: "rule_repeal",
          reference_id: ruleId,
          title: "Archive rule (second)",
          created_by_member_id: g!.members[0].memberId,
          opened_at: new Date().toISOString(),
          closes_at: new Date(Date.now() + 72 * 3600 * 1000).toISOString(),
          quorum_percent: 50,
          threshold_percent: 50,
          is_anonymous: true,
          status: "open",
        });
        if (error) throw error;
      },
      Error,
      "duplicate key value", // postgres unique violation message
    );

    // Close the first vote — second can now open.
    await admin.from("votes").update({ status: "rejected" })
      .eq("group_id", g.groupId).eq("vote_type", "rule_repeal").eq("reference_id", ruleId);

    const { error: thirdErr } = await admin.from("votes").insert({
      group_id: g.groupId,
      vote_type: "rule_repeal",
      reference_id: ruleId,
      title: "Archive rule (third)",
      created_by_member_id: g.members[0].memberId,
      opened_at: new Date().toISOString(),
      closes_at: new Date(Date.now() + 72 * 3600 * 1000).toISOString(),
      quorum_percent: 50,
      threshold_percent: 50,
      is_anonymous: true,
      status: "open",
    });
    assert(!thirdErr, `third insert failed: ${thirdErr?.message}`);
  } finally {
    if (g) await cleanupGroup(g);
  }
});
```

- [ ] **Step 2: Run test**

Run: `cd supabase/functions/_tests && deno test -A db/vote_unique_open.test.ts`
Expected: 1 PASS once migration 00025 is applied.

- [ ] **Step 3: Commit**

```sh
git add supabase/functions/_tests/db/vote_unique_open.test.ts
git commit -m "$(cat <<'EOF'
test(db): unique-open-vote-per-reference index enforces single open

Phase A4 of EditRulesView. Verifies migration 00025 blocks a second
open rule_repeal vote on the same rule_id while the first is open,
and that closing the first lets a new one open.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task A5: `can_modify_rules.test.ts`

**Files:**
- Create: `supabase/functions/_tests/db/can_modify_rules.test.ts`

- [ ] **Step 1: Write the test**

```ts
// supabase/functions/_tests/db/can_modify_rules.test.ts
//
// Covers public.can_modify_rules(group_id, user_id):
//   - founder + governance.whoCanModifyRules='founder'  → true
//   - founder + governance='majorityVote'                → false
//   - anyMember + governance='anyMember'                 → true
//   - anyMember + governance='founder'                   → false
//   - host (non-founder) + governance='founder'          → false
//   - inactive member + role=founder                     → false
//   - user not in group at all                           → false

import { assertEquals } from "jsr:@std/assert@1";
import { adminClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "../e2e/_fixtures/seedGroup.ts";
import { cleanupGroup } from "../e2e/_fixtures/cleanup.ts";

const admin = adminClient();

async function callCanModify(groupId: string, userId: string): Promise<boolean> {
  const { data, error } = await admin.rpc("can_modify_rules", {
    p_group_id: groupId,
    p_user_id: userId,
  });
  if (error) throw error;
  return data as boolean;
}

async function setGovernance(groupId: string, key: string, value: string) {
  const { data: g } = await admin.from("groups").select("governance").eq("id", groupId).single();
  const merged = { ...((g!.governance as Record<string, unknown>) ?? {}), [key]: value };
  await admin.from("groups").update({ governance: merged }).eq("id", groupId);
}

Deno.test("can_modify_rules — founder + governance=founder → true", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const founder = g.members[0];
    await setGovernance(g.groupId, "whoCanModifyRules", "founder");
    assertEquals(await callCanModify(g.groupId, founder.userId), true);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("can_modify_rules — founder + governance=majorityVote → false", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const founder = g.members[0];
    await setGovernance(g.groupId, "whoCanModifyRules", "majorityVote");
    assertEquals(await callCanModify(g.groupId, founder.userId), false);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("can_modify_rules — anyMember + governance=anyMember → true", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const member = g.members[1]; // bob, non-founder
    await setGovernance(g.groupId, "whoCanModifyRules", "anyMember");
    assertEquals(await callCanModify(g.groupId, member.userId), true);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("can_modify_rules — anyMember + governance=founder → false", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const member = g.members[1];
    await setGovernance(g.groupId, "whoCanModifyRules", "founder");
    assertEquals(await callCanModify(g.groupId, member.userId), false);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("can_modify_rules — inactive member + role=founder → false", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: false,
    });
    const founder = g.members[0];
    await setGovernance(g.groupId, "whoCanModifyRules", "founder");

    // Deactivate the founder's membership.
    await admin.from("group_members").update({ active: false })
      .eq("group_id", g.groupId).eq("user_id", founder.userId);

    assertEquals(await callCanModify(g.groupId, founder.userId), false);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("can_modify_rules — user not in group → false", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: false,
    });
    await setGovernance(g.groupId, "whoCanModifyRules", "anyMember");

    const randomUserId = "00000000-0000-0000-0000-000000000099";
    assertEquals(await callCanModify(g.groupId, randomUserId), false);
  } finally {
    if (g) await cleanupGroup(g);
  }
});
```

- [ ] **Step 2: Run test**

Run: `cd supabase/functions/_tests && deno test -A db/can_modify_rules.test.ts`
Expected: 6 PASS.

- [ ] **Step 3: Commit**

```sh
git add supabase/functions/_tests/db/can_modify_rules.test.ts
git commit -m "$(cat <<'EOF'
test(db): can_modify_rules covers all 6 governance×role permutations

Phase A5 of EditRulesView. Validates the new SQL function returns
correctly for: founder×founder, founder×majorityVote, anyMember×anyMember,
anyMember×founder, inactive-member, and stranger-user. Inactive and
stranger paths protect against ex-member privilege creep.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task A6: `rls_update_rules.test.ts`

**Files:**
- Create: `supabase/functions/_tests/db/rls_update_rules.test.ts`

- [ ] **Step 1: Write the test**

```ts
// supabase/functions/_tests/db/rls_update_rules.test.ts
//
// Covers the swapped UPDATE policy on rules:
//   - Founder of governance=founder group → UPDATE succeeds.
//   - Founder of governance=majorityVote group → UPDATE fails (42501).
//   - anyMember of governance=anyMember → succeeds.
//   - anyMember of governance=founder → fails.
//
// Uses a per-user supabase client with the user's JWT (NOT admin) so RLS
// is enforced.

import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { adminClient, userClient } from "../e2e/_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "../e2e/_fixtures/seedGroup.ts";
import { cleanupGroup } from "../e2e/_fixtures/cleanup.ts";

const admin = adminClient();

async function setGovernance(groupId: string, key: string, value: string) {
  const { data: g } = await admin.from("groups").select("governance").eq("id", groupId).single();
  const merged = { ...((g!.governance as Record<string, unknown>) ?? {}), [key]: value };
  await admin.from("groups").update({ governance: merged }).eq("id", groupId);
}

Deno.test("RLS allows founder UPDATE rules when governance=founder", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });
    await setGovernance(g.groupId, "whoCanModifyRules", "founder");

    const founder = g.members[0];
    const { data: rules } = await admin.from("rules").select("id,enabled")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;
    const initial = rules![0].enabled as boolean;

    const userScoped = await userClient(founder.accessToken!);
    const { error } = await userScoped.from("rules")
      .update({ enabled: !initial }).eq("id", ruleId);

    assertEquals(error, null);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("RLS denies founder UPDATE rules when governance=majorityVote", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      seedDinnerRules: true,
    });
    await setGovernance(g.groupId, "whoCanModifyRules", "majorityVote");

    const founder = g.members[0];
    const { data: rules } = await admin.from("rules").select("id,enabled")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;

    const userScoped = await userClient(founder.accessToken!);
    const { error } = await userScoped.from("rules")
      .update({ enabled: false }).eq("id", ruleId);

    // PostgREST surfaces RLS denial as a "no rows updated" or PGRST204 — match either.
    // Some Supabase versions raise 42501; check error code or row count.
    if (error) {
      // Direct denial — expected.
      assertEquals(error.code === "42501" || error.message.includes("policy"), true);
    } else {
      // No error, but the UPDATE matched zero rows because the policy filtered them out.
      const { data: after } = await admin.from("rules").select("enabled").eq("id", ruleId).single();
      assertEquals(after!.enabled, rules![0].enabled, "rule should remain unchanged");
    }
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("RLS allows non-founder member UPDATE when governance=anyMember", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: true,
    });
    await setGovernance(g.groupId, "whoCanModifyRules", "anyMember");

    const bob = g.members[1];
    const { data: rules } = await admin.from("rules").select("id,enabled")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;
    const initial = rules![0].enabled as boolean;

    const userScoped = await userClient(bob.accessToken!);
    const { error } = await userScoped.from("rules")
      .update({ enabled: !initial }).eq("id", ruleId);

    assertEquals(error, null);
  } finally {
    if (g) await cleanupGroup(g);
  }
});

Deno.test("RLS denies non-founder member UPDATE when governance=founder", async () => {
  let g: SeededGroup | null = null;
  try {
    g = await seedGroup({
      memberSpecs: [{ handle: "alice" }, { handle: "bob" }],
      seedDinnerRules: true,
    });
    await setGovernance(g.groupId, "whoCanModifyRules", "founder");

    const bob = g.members[1];
    const { data: rules } = await admin.from("rules").select("id,enabled")
      .eq("group_id", g.groupId).limit(1);
    const ruleId = rules![0].id as string;

    const userScoped = await userClient(bob.accessToken!);
    const { error } = await userScoped.from("rules")
      .update({ enabled: false }).eq("id", ruleId);

    if (error) {
      assertEquals(error.code === "42501" || error.message.includes("policy"), true);
    } else {
      const { data: after } = await admin.from("rules").select("enabled").eq("id", ruleId).single();
      assertEquals(after!.enabled, rules![0].enabled, "rule should remain unchanged");
    }
  } finally {
    if (g) await cleanupGroup(g);
  }
});
```

If `userClient(jwt)` does not yet exist in `_fixtures/supabaseClients.ts`, add a thin helper:

```ts
// supabase/functions/_tests/e2e/_fixtures/supabaseClients.ts (add export if missing)
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
const url = Deno.env.get("SUPABASE_URL")!;
const anon = Deno.env.get("SUPABASE_ANON_KEY")!;

export async function userClient(accessToken: string): Promise<SupabaseClient> {
  return createClient(url, anon, {
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
```

If `seedGroup`'s returned `members` does not yet expose `accessToken`, add it to the fixture (small change in `seedGroup.ts`: capture the JWT after sign-in and attach to each `Member`).

- [ ] **Step 2: Run test**

Run: `cd supabase/functions/_tests && deno test -A db/rls_update_rules.test.ts`
Expected: 4 PASS once migrations 00024 are applied.

- [ ] **Step 3: Commit**

```sh
git add supabase/functions/_tests/db/rls_update_rules.test.ts \
  supabase/functions/_tests/e2e/_fixtures/supabaseClients.ts \
  supabase/functions/_tests/e2e/_fixtures/seedGroup.ts
git commit -m "$(cat <<'EOF'
test(db): rls_update_rules verifies governance-aware UPDATE gate

Phase A6 of EditRulesView. Per-user supabase client (JWT-scoped, NOT
admin) attempts UPDATE rules.enabled across 4 governance×role configs.
Verifies the rules_update_governance policy actually consults
can_modify_rules and tampered clients cannot bypass governance.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Phase B — iOS Model & Repository (3 commits)

### Task B1: `GroupRule.fineShape` + tests + history-rendering test

**Files:**
- Create: `ios/Tandas/Platform/Models/GroupRule+FineShape.swift`
- Create: `ios/TandasTests/Rules/RuleFineShapeTests.swift`
- Modify: `ios/TandasTests/Platform/CodableEnumsTests.swift` (extend with history-rendering check for the two new SystemEventType cases)

- [ ] **Step 0: Extend `CodableEnumsTests.swift` with rendering check for the two new cases**

Append inside `final class CodableEnumsTests: XCTestCase { ... }` (after the existing test methods):

```swift
    func testRuleEnabledChangedRenders() {
        let event = SystemEvent.mock(type: .ruleEnabledChanged, occurredAt: Date())
        let p = HistoryItemPresentation(event: event, memberName: "Alice")
        XCTAssertEqual(p.icon, "switch.2")
        XCTAssertEqual(p.title, "Alice cambió el estado de una regla")
        XCTAssertEqual(p.tone, .neutral)
    }

    func testRuleAmountChangedRenders() {
        let event = SystemEvent.mock(type: .ruleAmountChanged, occurredAt: Date())
        let p = HistoryItemPresentation(event: event, memberName: "Alice")
        XCTAssertEqual(p.icon, "pencil.line")
        XCTAssertEqual(p.title, "Alice editó la multa de una regla")
        XCTAssertEqual(p.tone, .neutral)
    }
```

If `SystemEvent.mock(type:occurredAt:)` does not exist, add a tiny test fixture in the same file:
```swift
extension SystemEvent {
    static func mock(type: SystemEventType, occurredAt: Date) -> SystemEvent {
        SystemEvent(
            id: UUID(), groupId: UUID(), eventType: type,
            resourceId: nil, memberId: nil,
            payload: [:], occurredAt: occurredAt, processedAt: nil
        )
    }
}
```

(Adapt the initializer to the actual `SystemEvent` model fields — read it before writing if you're unsure.)

Run: `xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -only-testing:TandasTests/CodableEnumsTests 2>&1 | grep -E "Test Suite.*passed|error:" | tail -5`
Expected: all CodableEnumsTests pass (5 existing roundtrip tests + 2 new render tests).

- [ ] **Step 1: Write the failing test**

`ios/TandasTests/Rules/RuleFineShapeTests.swift`:
```swift
import Foundation
import XCTest
@testable import Tandas

final class RuleFineShapeTests: XCTestCase {
    private func rule(consequences: [RuleConsequence]) -> GroupRule {
        GroupRule(
            id: UUID(),
            groupId: UUID(),
            code: nil,
            title: "Test",
            description: nil,
            enabled: true,
            isActive: true,
            action: nil,
            consequences: consequences
        )
    }

    func testFlat() {
        let r = rule(consequences: [
            RuleConsequence(type: .fine, config: ["amount": .int(200)])
        ])
        XCTAssertEqual(r.fineShape, .flat(amount: 200))
    }

    func testEscalating() {
        let r = rule(consequences: [
            RuleConsequence(type: .fine, config: [
                "baseAmount": .int(200),
                "stepAmount": .int(50),
                "stepMinutes": .int(30),
            ])
        ])
        XCTAssertEqual(r.fineShape, .escalating(base: 200, step: 50, stepMinutes: 30))
    }

    func testEmpty() {
        XCTAssertEqual(rule(consequences: []).fineShape, .none)
    }

    func testUnknown() {
        let r = rule(consequences: [
            RuleConsequence(type: .fine, config: ["weirdField": .string("x")])
        ])
        if case .unknown = r.fineShape { /* ok */ } else {
            XCTFail("expected .unknown for non-flat non-escalating fine config")
        }
    }

    func testMultipleConsequencesUsesFirst() {
        let r = rule(consequences: [
            RuleConsequence(type: .fine, config: ["amount": .int(100)]),
            RuleConsequence(type: .sendNotification, config: [:]),
        ])
        XCTAssertEqual(r.fineShape, .flat(amount: 100))
    }

    func testConfigWithExtraFieldsStillFlat() {
        let r = rule(consequences: [
            RuleConsequence(type: .fine, config: [
                "amount": .int(300),
                "extra": .string("ignored"),
            ])
        ])
        XCTAssertEqual(r.fineShape, .flat(amount: 300))
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

Run from `ios/`: `xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -only-testing:TandasTests/RuleFineShapeTests 2>&1 | grep -E "error:" | head -5`
Expected: compile failure on `r.fineShape` (member doesn't exist).

- [ ] **Step 3: Implement `GroupRule+FineShape.swift`**

```swift
// ios/Tandas/Platform/Models/GroupRule+FineShape.swift
import Foundation

extension GroupRule {
    public enum FineShape: Sendable, Equatable {
        case none
        case flat(amount: Int)
        case escalating(base: Int, step: Int, stepMinutes: Int)
        case unknown(rawConfig: [String: JSONConfig])
    }

    /// Parses `consequences[0].config` into a typed shape. UI consumes this
    /// to decide flat-editable vs escalating-readonly. Repository's
    /// `setFlatFineAmount` validates against the same enum.
    public var fineShape: FineShape {
        guard let first = consequences.first, first.type == .fine else {
            return .none
        }
        let cfg = first.config

        if let amount = cfg["amount"]?.intValue {
            return .flat(amount: amount)
        }
        if let base = cfg["baseAmount"]?.intValue,
           let step = cfg["stepAmount"]?.intValue,
           let mins = cfg["stepMinutes"]?.intValue {
            return .escalating(base: base, step: step, stepMinutes: mins)
        }
        return .unknown(rawConfig: cfg)
    }
}
```

If `JSONConfig` does not currently expose `intValue`, add a tiny extension in the same file:
```swift
extension JSONConfig {
    var intValue: Int? {
        if case .int(let i) = self { return i }
        if case .double(let d) = self { return Int(d) }
        return nil
    }
}
```

(Skip the extension if `JSONConfig` already has `intValue`.)

- [ ] **Step 4: Run xcodegen + tests**

Run from repo root:
```sh
cd ios && xcodegen
xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -only-testing:TandasTests/RuleFineShapeTests 2>&1 | grep -E "Test Suite.*passed|Test Suite.*failed|error:" | tail -10
```
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```sh
git add ios/Tandas/Platform/Models/GroupRule+FineShape.swift \
  ios/TandasTests/Rules/RuleFineShapeTests.swift
git commit -m "$(cat <<'EOF'
feat(rules): GroupRule.fineShape typed parser for fine consequence shapes

Phase B1 of EditRulesView. Single source of truth for "is this a flat
or escalating fine?" — UI consumes for editable vs read-only branching;
repository validates against the same enum to refuse setFlatFineAmount
on non-flat shapes. 6 unit tests cover flat/escalating/empty/unknown/
multiple-consequences-first-wins/extra-fields-still-flat.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task B2: `RuleRepository` UPDATE methods + tests

**Files:**
- Modify: `ios/Tandas/Supabase/Repos/RuleRepository.swift`
- Create: `ios/TandasTests/Rules/RulesRepositoryTests.swift`

- [ ] **Step 1: Write the failing test**

`ios/TandasTests/Rules/RulesRepositoryTests.swift`:
```swift
import Foundation
import XCTest
@testable import Tandas

@MainActor
final class RulesRepositoryTests: XCTestCase {
    func testSetFlatFineAmountRejectsEscalatingShape() async throws {
        let escalatingRule = GroupRule(
            id: UUID(),
            groupId: UUID(),
            code: nil,
            title: "Tarde a evento",
            description: nil,
            enabled: true,
            isActive: true,
            action: nil,
            consequences: [
                RuleConsequence(type: .fine, config: [
                    "baseAmount": .int(200),
                    "stepAmount": .int(50),
                    "stepMinutes": .int(30),
                ])
            ]
        )

        let mock = MockRuleRepository()
        do {
            try await mock.setFlatFineAmount(rule: escalatingRule, amount: 999)
            XCTFail("expected RulesRepositoryError.notFlatFine")
        } catch RulesRepositoryError.notFlatFine {
            // success
        } catch {
            XCTFail("expected notFlatFine, got \(error)")
        }
    }

    func testSetEnabledHappyPath() async throws {
        let mock = MockRuleRepository()
        let ruleId = UUID()
        try await mock.setEnabled(ruleId: ruleId, enabled: false)
        let last = await mock.lastSetEnabled
        XCTAssertEqual(last?.ruleId, ruleId)
        XCTAssertEqual(last?.enabled, false)
    }
}
```

- [ ] **Step 2: Run test, expect compile failure**

Run: `xcodebuild test ... -only-testing:TandasTests/RulesRepositoryTests 2>&1 | grep -E "error:" | head -10`
Expected: compile failures (`setFlatFineAmount`, `setEnabled`, `RulesRepositoryError`, `lastSetEnabled` all missing).

- [ ] **Step 3: Extend `RuleRepository.swift`**

In `ios/Tandas/Supabase/Repos/RuleRepository.swift`, append three protocol methods, the error type, and Mock + Live implementations.

After the existing `enum RuleError`, add:
```swift
public enum RulesRepositoryError: Error {
    case notFlatFine
    case rlsDenied
    case other(Error)
}

/// Lightweight Vote projection for the pending-repeal badge.
struct PendingVote: Sendable, Hashable {
    let id: UUID
    let referenceId: UUID
    let closesAt: Date
}
```

In the protocol (after `func list`):
```swift
    /// Toggles enabled/disabled. Postgres trigger emits ruleEnabledChanged.
    func setEnabled(ruleId: UUID, enabled: Bool) async throws

    /// Updates the flat fine amount. Caller must pre-validate via
    /// `rule.fineShape == .flat`. Throws `.notFlatFine` if the rule is
    /// escalating or unknown shape. Postgres trigger emits ruleAmountChanged.
    func setFlatFineAmount(rule: GroupRule, amount: Int) async throws

    /// Returns the open rule_repeal vote for a rule, if any.
    func pendingRepealVote(ruleId: UUID, groupId: UUID) async throws -> PendingVote?
```

In `MockRuleRepository`:
```swift
    private(set) var lastSetEnabled: (ruleId: UUID, enabled: Bool)?
    private(set) var lastSetAmount: (ruleId: UUID, amount: Int)?

    func setEnabled(ruleId: UUID, enabled: Bool) async throws {
        lastSetEnabled = (ruleId, enabled)
    }

    func setFlatFineAmount(rule: GroupRule, amount: Int) async throws {
        guard case .flat = rule.fineShape else { throw RulesRepositoryError.notFlatFine }
        lastSetAmount = (rule.id, amount)
    }

    func pendingRepealVote(ruleId: UUID, groupId: UUID) async throws -> PendingVote? {
        nil
    }
```

In `LiveRuleRepository`:
```swift
    func setEnabled(ruleId: UUID, enabled: Bool) async throws {
        struct Body: Encodable { let enabled: Bool }
        do {
            _ = try await client.from("rules")
                .update(Body(enabled: enabled))
                .eq("id", value: ruleId.uuidString.lowercased())
                .execute()
        } catch {
            throw RulesRepositoryError.other(error)
        }
    }

    func setFlatFineAmount(rule: GroupRule, amount: Int) async throws {
        guard case .flat = rule.fineShape else { throw RulesRepositoryError.notFlatFine }

        struct ConsequenceBody: Encodable {
            let type: String
            let config: ConfigBody
        }
        struct ConfigBody: Encodable { let amount: Int }
        struct Body: Encodable { let consequences: [ConsequenceBody] }

        do {
            _ = try await client.from("rules")
                .update(Body(consequences: [
                    ConsequenceBody(type: "fine", config: ConfigBody(amount: amount))
                ]))
                .eq("id", value: rule.id.uuidString.lowercased())
                .execute()
        } catch {
            throw RulesRepositoryError.other(error)
        }
    }

    func pendingRepealVote(ruleId: UUID, groupId: UUID) async throws -> PendingVote? {
        struct Row: Decodable {
            let id: UUID
            let reference_id: UUID
            let closes_at: Date
        }
        let rows: [Row] = try await client.from("votes")
            .select("id, reference_id, closes_at")
            .eq("group_id", value: groupId.uuidString.lowercased())
            .eq("vote_type", value: "rule_repeal")
            .eq("reference_id", value: ruleId.uuidString.lowercased())
            .eq("status", value: "open")
            .limit(1)
            .execute()
            .value
        guard let row = rows.first else { return nil }
        return PendingVote(id: row.id, referenceId: row.reference_id, closesAt: row.closes_at)
    }
```

- [ ] **Step 4: Run tests + xcodegen**

Run:
```sh
cd ios && xcodegen
xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -only-testing:TandasTests/RulesRepositoryTests 2>&1 | grep -E "Test Suite.*passed|Test Suite.*failed|error:" | tail -10
```
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```sh
git add ios/Tandas/Supabase/Repos/RuleRepository.swift \
  ios/TandasTests/Rules/RulesRepositoryTests.swift
git commit -m "$(cat <<'EOF'
feat(rules): RuleRepository UPDATE + pending-vote methods

Phase B2 of EditRulesView. Adds setEnabled, setFlatFineAmount, and
pendingRepealVote to the protocol with Mock + Live implementations.
setFlatFineAmount refuses .escalating / .unknown shapes via
RulesRepositoryError.notFlatFine — UI must guard with rule.fineShape
before calling.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task B3: `EditRulesCoordinator` + tests

**Files:**
- Modify: `ios/Tandas/Platform/Services/GovernanceService.swift` (extract `GovernanceServiceProtocol`)
- Create: `ios/Tandas/Features/Rules/EditRulesCoordinator.swift`
- Create: `ios/TandasTests/Rules/EditRulesCoordinatorTests.swift`

- [ ] **Step 0: Introduce `GovernanceServiceProtocol`**

Today `GovernanceService` is a concrete `public actor` (no protocol abstraction). Tests can't mock it without a protocol surface. Add a thin protocol next to the actor:

In `ios/Tandas/Platform/Services/GovernanceService.swift`, add at the top (after `import Foundation`):

```swift
public protocol GovernanceServiceProtocol: Sendable {
    func canPerform(
        _ action: GovernanceAction,
        member: Member,
        in group: Group,
        context: GovernanceContext?
    ) async throws -> GovernanceDecision
}
```

Conform `GovernanceService` to it (likely just adding `: GovernanceServiceProtocol` to its declaration; the existing `canPerform` signature should already match).

Build: `cd ios && xcodegen && xcodebuild build -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' 2>&1 | grep -E "error:" | head -5`
Expected: zero errors. If the existing `canPerform` signature differs (e.g., no `context` parameter or different argument order), update the protocol signature to match exactly — do NOT change the actor's signature.

- [ ] **Step 1: Write the failing test**

`ios/TandasTests/Rules/EditRulesCoordinatorTests.swift`:
```swift
import Foundation
import XCTest
@testable import Tandas

@MainActor
final class EditRulesCoordinatorTests: XCTestCase {
    private func makeCoordinator(decision: GovernanceDecision = .allowed) -> EditRulesCoordinator {
        let group = Group.mock(id: UUID())
        let member = Member.mock(role: .founder)
        let governance = MockGovernanceService(nextDecision: decision)
        let repo = MockRuleRepository()
        return EditRulesCoordinator(
            group: group,
            currentMember: member,
            governance: governance,
            ruleRepo: repo
        )
    }

    func testCanEditDefaultsFalse() {
        XCTAssertFalse(makeCoordinator().canEditRules)
    }

    func testRefreshAllowedSetsCanEditTrue() async {
        let c = makeCoordinator(decision: .allowed)
        await c.refresh()
        XCTAssertTrue(c.canEditRules)
    }

    func testRefreshRequiresVoteIsTreatedAsDenied() async {
        let c = makeCoordinator(decision: .requiresVote(quorum: 0.5, threshold: 0.5))
        await c.refresh()
        XCTAssertFalse(c.canEditRules)
    }

    func testRefreshDeniedKeepsCanEditFalse() async {
        let c = makeCoordinator(decision: .denied(reason: "not founder"))
        await c.refresh()
        XCTAssertFalse(c.canEditRules)
    }

    func testRefreshGovernanceThrowFailsClosed() async {
        let group = Group.mock(id: UUID())
        let member = Member.mock(role: .founder)
        let governance = MockGovernanceService(nextDecision: .allowed, throwOnNext: true)
        let repo = MockRuleRepository()
        let c = EditRulesCoordinator(
            group: group, currentMember: member, governance: governance, ruleRepo: repo
        )
        await c.refresh()
        XCTAssertFalse(c.canEditRules)
    }
}
```

If `MockGovernanceService` does not exist yet, add a small one in the test file (private to the test target):
```swift
final class MockGovernanceService: GovernanceServiceProtocol {
    var nextDecision: GovernanceDecision
    var throwOnNext: Bool
    init(nextDecision: GovernanceDecision, throwOnNext: Bool = false) {
        self.nextDecision = nextDecision
        self.throwOnNext = throwOnNext
    }
    func canPerform(_ action: GovernanceAction, member: Member, in group: Group, context: GovernanceContext?) async throws -> GovernanceDecision {
        if throwOnNext { throw NSError(domain: "mock", code: 1) }
        return nextDecision
    }
}
```

If `Member.mock(role:)` and `Group.mock(id:)` factories don't exist, add them in `ios/TandasTests/Rules/_TestFixtures.swift`:
```swift
import Foundation
@testable import Tandas

extension Member {
    static func mock(role: MemberRole) -> Member {
        Member(id: UUID(), userId: UUID(), groupId: UUID(),
               displayName: "Test", role: role, active: true,
               onCommittee: false, joinedAt: Date(), turnPosition: nil)
    }
}

extension Group {
    static func mock(id: UUID) -> Group {
        Group(id: id, name: "Test", description: nil, eventLabel: "evento",
              currency: "MXN", timezone: "America/Mexico_City",
              groupType: "recurring_dinner", governance: [:], createdAt: Date())
    }
}
```

(Adapt field signatures to whatever the actual `Member`/`Group` initializers require — read those files first to align.)

- [ ] **Step 2: Run test, expect compile failure**

Run: `xcodebuild test ... -only-testing:TandasTests/EditRulesCoordinatorTests 2>&1 | grep -E "error:" | head -10`
Expected: compile failures (`EditRulesCoordinator` missing).

- [ ] **Step 3: Implement `EditRulesCoordinator.swift`**

```swift
// ios/Tandas/Features/Rules/EditRulesCoordinator.swift
import Foundation
import OSLog

/// Coordinator for EditRulesView. Owns:
/// - canEditRules flag (governance gate result)
/// - per-rule in-flight set for sync indicators on toggles
/// - pending repeal-vote map for the "Votación pendiente" badge
///
/// Re-evaluates canEditRules on every refresh() call. Does NOT subscribe
/// to live governance changes (V1 trade-off; RLS catches stale-state
/// mutations at the server boundary).
@Observable @MainActor
final class EditRulesCoordinator {
    private(set) var rules: [GroupRule] = []
    private(set) var pendingVotes: [UUID: PendingVote] = [:]
    private(set) var isLoading: Bool = false
    private(set) var error: String?
    private(set) var canEditRules: Bool = false
    private(set) var inFlightToggleIDs: Set<UUID> = []

    let group: Group
    private let currentMember: Member
    private let governance: any GovernanceServiceProtocol
    private let ruleRepo: any RuleRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "rules.edit")

    init(
        group: Group,
        currentMember: Member,
        governance: any GovernanceServiceProtocol,
        ruleRepo: any RuleRepository
    ) {
        self.group = group
        self.currentMember = currentMember
        self.governance = governance
        self.ruleRepo = ruleRepo
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        // Evaluate gate fail-closed.
        do {
            let decision = try await governance.canPerform(
                .modifyRules, member: currentMember, in: group, context: nil
            )
            if case .allowed = decision {
                canEditRules = true
            } else {
                canEditRules = false
            }
        } catch {
            log.warning("governance check failed: \(error.localizedDescription)")
            canEditRules = false
        }

        // Load rules.
        do {
            let all = try await ruleRepo.list(groupId: group.id)
            let platformShape = all.filter { !$0.consequences.isEmpty }
            rules = platformShape.isEmpty ? all : platformShape

            // Load pending repeal votes per rule.
            var pending: [UUID: PendingVote] = [:]
            for r in rules {
                if let v = try? await ruleRepo.pendingRepealVote(ruleId: r.id, groupId: group.id) {
                    pending[r.id] = v
                }
            }
            pendingVotes = pending
        } catch {
            log.warning("rules load failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    func setEnabled(rule: GroupRule, enabled: Bool) async {
        // Optimistic flip + sync indicator.
        inFlightToggleIDs.insert(rule.id)
        let originalIndex = rules.firstIndex(where: { $0.id == rule.id })
        if let i = originalIndex {
            rules[i] = rules[i].withEnabled(enabled)
        }

        do {
            try await ruleRepo.setEnabled(ruleId: rule.id, enabled: enabled)
        } catch {
            log.warning("setEnabled failed: \(error.localizedDescription)")
            // Revert.
            if let i = originalIndex {
                rules[i] = rules[i].withEnabled(!enabled)
            }
            self.error = mapMutationError(error)
        }

        inFlightToggleIDs.remove(rule.id)
    }

    func setFlatFineAmount(rule: GroupRule, amount: Int) async {
        do {
            try await ruleRepo.setFlatFineAmount(rule: rule, amount: amount)
            await refresh()
        } catch RulesRepositoryError.notFlatFine {
            self.error = "Esta regla tiene multa escalonada; se editará en una próxima versión."
        } catch {
            log.warning("setFlatFineAmount failed: \(error.localizedDescription)")
            self.error = mapMutationError(error)
        }
    }

    private func mapMutationError(_ error: Error) -> String {
        let message = error.localizedDescription.lowercased()
        if message.contains("policy") || message.contains("42501") {
            return "La gobernanza del grupo cambió. Tirá pull-to-refresh para ver los permisos actuales."
        }
        return "No se pudo guardar el cambio. Probá de nuevo."
    }
}
```

If `GroupRule.withEnabled(_:)` does not exist, add a small helper extension in `GroupRule+FineShape.swift`:
```swift
extension GroupRule {
    func withEnabled(_ enabled: Bool) -> GroupRule {
        var copy = self
        copy.enabled = enabled
        return copy
    }
}
```

- [ ] **Step 4: Run tests + xcodegen**

Run:
```sh
cd ios && xcodegen
xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -only-testing:TandasTests/EditRulesCoordinatorTests 2>&1 | grep -E "Test Suite.*passed|Test Suite.*failed|error:" | tail -10
```
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```sh
git add ios/Tandas/Features/Rules/EditRulesCoordinator.swift \
  ios/Tandas/Platform/Models/GroupRule+FineShape.swift \
  ios/TandasTests/Rules/EditRulesCoordinatorTests.swift \
  ios/TandasTests/Rules/_TestFixtures.swift
git commit -m "$(cat <<'EOF'
feat(rules): EditRulesCoordinator with governance gate + optimistic toggle

Phase B3 of EditRulesView. @Observable coordinator owns canEditRules
(fail-closed against governance throws + .requiresVote + .denied),
optimistic-toggle with revert + RLS-denial-aware error mapping, and
pendingVotes map for the "Votación pendiente" badge. 5 unit tests
cover the canEditRules state machine.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Phase C — iOS UI (3 commits)

### Task C1: `RuleSummaryFormatter`

**Files:**
- Create: `ios/Tandas/Features/Rules/RuleSummaryFormatter.swift`

- [ ] **Step 1: Implement the formatter**

```swift
// ios/Tandas/Features/Rules/RuleSummaryFormatter.swift
import Foundation

/// Maps a RuleTrigger / RuleCondition list into human-readable Spanish
/// strings for the EditRuleSheet "CÓMO FUNCIONA" section. V1 ships
/// es-MX only; future Fase 5 multi-locale is out of scope.
enum RuleSummaryFormatter {
    static func summarize(trigger: RuleTrigger) -> String {
        switch trigger.eventType {
        case .eventClosed:        return "Cuando se cierra un evento"
        case .checkInRecorded:    return "Cuando alguien hace check-in"
        case .rsvpChangedSameDay: return "Cuando alguien cambia su RSVP el mismo día del evento"
        case .hoursBeforeEvent:
            if let h = trigger.config["hours"]?.intValue {
                return "\(h) horas antes de un evento"
            }
            return "Horas antes de un evento"
        case .rsvpSubmitted:        return "Cuando alguien responde RSVP"
        case .rsvpDeadlinePassed:   return "Cuando cierra la deadline de RSVP"
        case .eventDescriptionMissing: return "Cuando falta la descripción del evento"
        default:                    return trigger.eventType.rawString
        }
    }

    static func summarize(conditions: [RuleCondition]) -> String? {
        let lines = conditions.compactMap(summarize(condition:))
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " · ")
    }

    private static func summarize(condition: RuleCondition) -> String? {
        switch condition.type {
        case .alwaysTrue:
            return nil  // skip — always-true is the absence of a condition
        case .responseStatusIs:
            if let status = condition.config["status"]?.stringValue {
                return "Si la respuesta es \(humanStatus(status))"
            }
            return "Si la respuesta tiene un estado"
        case .checkInExists:
            if condition.config["exists"]?.boolValue == false {
                return "Si no hizo check-in"
            }
            return "Si hizo check-in"
        case .checkInMinutesLate:
            if let n = condition.config["thresholdMinutes"]?.intValue {
                return "Si llegó \(n)+ minutos tarde"
            }
            return "Si llegó tarde"
        case .eventDescriptionMissing:
            return "Si falta la descripción"
        default:
            return condition.type.rawString
        }
    }

    private static func humanStatus(_ raw: String) -> String {
        switch raw {
        case "pending":    return "pendiente"
        case "going":      return "asistirá"
        case "maybe":      return "tal vez"
        case "declined":   return "no asistirá"
        case "waitlisted": return "en lista de espera"
        default:           return raw
        }
    }
}

private extension JSONConfig {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}
```

(If `JSONConfig` already exposes `stringValue`/`boolValue`, omit the private extension.)

- [ ] **Step 2: Verify it compiles**

Run: `cd ios && xcodegen && xcodebuild build -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' 2>&1 | grep -E "error:" | head -5`
Expected: zero compile errors.

- [ ] **Step 3: Commit**

```sh
git add ios/Tandas/Features/Rules/RuleSummaryFormatter.swift
git commit -m "$(cat <<'EOF'
feat(rules): RuleSummaryFormatter for EditRuleSheet "CÓMO FUNCIONA"

Phase C1 of EditRulesView. Maps each RuleTrigger eventType + its
config payload, plus each RuleCondition type + config, to a Spanish
sentence. es-MX only; multi-locale is Fase 5. Falls back to the
enum rawString for unknown / not-yet-implemented types so the UI
stays robust when SystemEventType / ConditionType gain new cases.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task C2: `EditRulesView` (the list)

**Files:**
- Create: `ios/Tandas/Features/Rules/EditRulesView.swift`

- [ ] **Step 1: Implement `EditRulesView.swift`**

```swift
// ios/Tandas/Features/Rules/EditRulesView.swift
import SwiftUI

/// Edit-mode counterpart to RulesView. Reachable via the conditional
/// pencil button in RulesView nav (visible iff governance.canPerform(
/// .modifyRules) == .allowed for the current actor).
struct EditRulesView: View {
    @Bindable var coordinator: EditRulesCoordinator
    @State private var sheetRule: GroupRule?

    var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            content
        }
        .task { await coordinator.refresh() }
        .navigationTitle("Editar reglas")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheetRule) { rule in
            NavigationStack {
                EditRuleSheet(
                    rule: rule,
                    pending: coordinator.pendingVotes[rule.id],
                    coordinator: coordinator,
                    onDismiss: { sheetRule = nil }
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if coordinator.isLoading && coordinator.rules.isEmpty {
            ProgressView().tint(Color.ruulAccentPrimary)
        } else if coordinator.rules.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.s4) {
                header
                VStack(spacing: RuulSpacing.s3) {
                    ForEach(stableOrder(coordinator.rules)) { rule in
                        ruleCard(rule)
                    }
                }
                footer
            }
            .padding(.horizontal, RuulSpacing.s5)
            .padding(.top, RuulSpacing.s4)
            .padding(.bottom, RuulSpacing.s12)
        }
        .scrollIndicators(.hidden)
        .refreshable { await coordinator.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text(coordinator.group.name)
                .ruulTextStyle(RuulTypography.sectionLabelLg)
                .foregroundStyle(Color.ruulTextSecondary)
            Text("Reglas pre-armadas")
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
        }
        .padding(.top, RuulSpacing.s2)
    }

    private var footer: some View {
        Text("Las reglas personalizadas estarán disponibles en una próxima versión.")
            .ruulTextStyle(RuulTypography.caption)
            .foregroundStyle(Color.ruulTextTertiary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, RuulSpacing.s4)
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "list.bullet.clipboard",
            title: "Sin reglas",
            message: "Este grupo no tiene reglas configuradas."
        )
    }

    /// Stable order: by created_at ASC. Toggle does NOT re-sort.
    private func stableOrder(_ rules: [GroupRule]) -> [GroupRule] {
        rules.sorted { lhs, rhs in (lhs.createdAt ?? .distantPast) < (rhs.createdAt ?? .distantPast) }
    }

    private func ruleCard(_ rule: GroupRule) -> some View {
        let pending = coordinator.pendingVotes[rule.id]
        let inFlight = coordinator.inFlightToggleIDs.contains(rule.id)

        return Button {
            sheetRule = rule
        } label: {
            HStack(alignment: .top, spacing: RuulSpacing.s3) {
                VStack(alignment: .leading, spacing: RuulSpacing.s1) {
                    Text(rule.title)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .lineLimit(2)
                    if let desc = rule.description, !desc.isEmpty {
                        Text(desc)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                            .lineLimit(3)
                    }
                    fineDisplay(rule)
                    if let pending {
                        pendingBadge(pending)
                    }
                }
                Spacer()
                toggleColumn(rule, inFlight: inFlight, pending: pending)
            }
            .padding(RuulSpacing.s4)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .fill(Color.ruulBackgroundElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 1)
            )
            .opacity(rule.enabled ? 1.0 : 0.55)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func fineDisplay(_ rule: GroupRule) -> some View {
        switch rule.fineShape {
        case .flat(let amount):
            Text("Multa: \(formatMXN(amount))")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextAccent)
        case .escalating:
            Text("Multa escalonada")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextAccent)
        case .none, .unknown:
            EmptyView()
        }
    }

    private func toggleColumn(_ rule: GroupRule, inFlight: Bool, pending: PendingVote?) -> some View {
        VStack(spacing: RuulSpacing.s1) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { newValue in
                    Task { await coordinator.setEnabled(rule: rule, enabled: newValue) }
                }
            ))
            .labelsHidden()
            .disabled(pending != nil)
            if inFlight {
                ProgressView().scaleEffect(0.6)
            }
        }
    }

    private func pendingBadge(_ vote: PendingVote) -> some View {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = Locale(identifier: "es_MX")
        let relative = formatter.localizedString(for: vote.closesAt, relativeTo: .now)
        return HStack(spacing: RuulSpacing.s1) {
            Image(systemName: "hand.raised.fill")
            Text("Votación pendiente · cierra \(relative)")
        }
        .ruulTextStyle(RuulTypography.footnote)
        .foregroundStyle(Color.ruulTextWarning)
        .padding(.top, RuulSpacing.s1)
    }

    private func formatMXN(_ amount: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: amount)) ?? "$\(amount)"
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd ios && xcodegen && xcodebuild build -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' 2>&1 | grep -E "error:" | head -5`
Expected: zero errors. (If `Color.ruulTextWarning` is missing, swap for `Color.orange` or whatever the existing warning tone token is — read `ios/Tandas/DesignSystem/Tokens/`.)

- [ ] **Step 3: Commit**

```sh
git add ios/Tandas/Features/Rules/EditRulesView.swift
git commit -m "$(cat <<'EOF'
feat(rules): EditRulesView list with optimistic toggle + pending-vote badge

Phase C2 of EditRulesView. Stable order by created_at ASC (toggle does
not reorder). Inline toggle with sync indicator while UPDATE in flight.
Tap card → EditRuleSheet. Pending repeal vote disables toggle and
renders a "Votación pendiente · cierra en 2d 4h" badge. Empty-state
copy "Este grupo no tiene reglas configuradas." for the defensive
zero-rules path. Passive footer below the list explains where Fase 5
custom rules will live.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task C3: `EditRuleSheet` + RulesView pencil + RulesCoordinator wiring

**Files:**
- Create: `ios/Tandas/Features/Rules/EditRuleSheet.swift`
- Modify: `ios/Tandas/Features/Rules/RulesView.swift`
- Modify: `ios/Tandas/Features/Rules/RulesCoordinator.swift`

- [ ] **Step 1: Implement `EditRuleSheet.swift`**

```swift
// ios/Tandas/Features/Rules/EditRuleSheet.swift
import SwiftUI

struct EditRuleSheet: View {
    let rule: GroupRule
    let pending: PendingVote?
    @Bindable var coordinator: EditRulesCoordinator
    let onDismiss: () -> Void

    @State private var draftAmount: String = ""
    @FocusState private var amountFocused: Bool
    @State private var showArchiveConfirm: Bool = false

    var body: some View {
        Form {
            Section { Text(rule.title).font(.title3.weight(.semibold)) }

            Section("CÓMO FUNCIONA") {
                Text(RuleSummaryFormatter.summarize(trigger: rule.trigger))
                if let conds = RuleSummaryFormatter.summarize(conditions: rule.conditions) {
                    Text(conds)
                }
            }

            Section("MULTA") { fineSection }

            if pending != nil {
                Section {
                    Text("Esta regla está siendo votada para archivar.")
                        .foregroundStyle(.orange)
                }
            } else {
                Section {
                    Button(role: .destructive) {
                        showArchiveConfirm = true
                    } label: {
                        HStack { Text("Archivar regla"); Spacer() }
                    }
                    Text("Abre votación del grupo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Editar regla")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancelar") { onDismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await commitAmount() } }
                    .disabled(!isAmountDirty || pending != nil)
            }
        }
        .onAppear(perform: seedDraft)
        .alert("¿Archivar regla?", isPresented: $showArchiveConfirm) {
            Button("Sí, abrir votación", role: .destructive) {
                Task { await openRepealVote() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se abrirá una votación del grupo. Si pasa, '\(rule.title)' deja de aplicarse.")
        }
    }

    @ViewBuilder
    private var fineSection: some View {
        switch rule.fineShape {
        case .flat:
            HStack {
                Text("Monto")
                Spacer()
                TextField("$0", text: $draftAmount)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused($amountFocused)
                    .disabled(pending != nil)
            }
        case .escalating(let base, let step, let stepMinutes):
            VStack(alignment: .leading, spacing: 4) {
                Text("Base: \(formatMXN(base)) · cada \(stepMinutes) min suma \(formatMXN(step))")
                Text("Multas escalonadas se editan en una próxima versión.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .none, .unknown:
            Text("Configuración de multa no editable").foregroundStyle(.secondary)
        }
    }

    private var currentFlatAmount: Int? {
        if case .flat(let a) = rule.fineShape { return a }
        return nil
    }

    private var isAmountDirty: Bool {
        guard let current = currentFlatAmount,
              let drafted = Int(draftAmount.filter(\.isNumber)) else { return false }
        return drafted != current && drafted > 0 && drafted <= 1_000_000
    }

    private func seedDraft() {
        if let current = currentFlatAmount { draftAmount = String(current) }
    }

    private func commitAmount() async {
        guard let drafted = Int(draftAmount.filter(\.isNumber)),
              drafted > 0 && drafted <= 1_000_000 else { return }
        await coordinator.setFlatFineAmount(rule: rule, amount: drafted)
        amountFocused = false
        onDismiss()
    }

    private func openRepealVote() async {
        await coordinator.openRepealVote(rule: rule)
        onDismiss()
    }

    private func formatMXN(_ amount: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: amount)) ?? "$\(amount)"
    }
}

extension GroupRule: Identifiable {}
```

(If `GroupRule` already conforms to `Identifiable`, drop the extension.)

**Wire `openRepealVote` into `EditRulesCoordinator`**: open `ios/Tandas/Features/Rules/EditRulesCoordinator.swift` (created in Task B3) and append this method before the closing brace of the class:

```swift
    /// Opens a rule_repeal vote via VoteRepository. The vote machinery
    /// emits voteOpened immediately; close_vote (cron-driven) handles the
    /// archive step when the vote resolves passed.
    func openRepealVote(rule: GroupRule) async {
        do {
            _ = try await voteRepo.startVote(
                groupId: group.id,
                voteType: .ruleRepeal,
                referenceId: rule.id,
                title: "Archivar: \(rule.title)",
                description: nil,
                payload: [:]
            )
            await refresh()
        } catch {
            log.warning("startVote failed: \(error.localizedDescription)")
            self.error = mapMutationError(error)
        }
    }
```

Add the dependency to the coordinator's init in Task B3:
```swift
private let voteRepo: any VoteRepository
// in init:
//   voteRepo: any VoteRepository,
//   self.voteRepo = voteRepo
```

If `VoteType.ruleRepeal` is not yet a case, add it to the `VoteType` enum source. The `votes.vote_type` column is text and migration 00023 already accepts the literal `'rule_repeal'` (the database side has no constraint to update). If `VoteType` lives under the `@codegen:enum` marker, run `make gen` after editing the source. If it's a hand-maintained enum, add the case directly and update any exhaustive switches surfaced by the compiler.

The call sites that construct `EditRulesCoordinator` (in Task C3 step 3, the `makeEditCoordinator()` helper inside `RulesView`) must now also pass a `VoteRepository` instance — typically pulled from the same `AppShell` that already holds `RuleRepository`.

- [ ] **Step 2: Modify `RulesCoordinator.swift` to expose `canEditRules`**

Replace the existing file with:
```swift
import Foundation
import OSLog

@Observable @MainActor
final class RulesCoordinator {
    private(set) var rules: [GroupRule] = []
    private(set) var isLoading: Bool = false
    private(set) var error: String?
    private(set) var canEditRules: Bool = false

    let group: Group
    private let currentMember: Member
    private let governance: any GovernanceServiceProtocol
    private let ruleRepo: any RuleRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "rules")

    init(
        group: Group,
        currentMember: Member,
        governance: any GovernanceServiceProtocol,
        ruleRepo: any RuleRepository
    ) {
        self.group = group
        self.currentMember = currentMember
        self.governance = governance
        self.ruleRepo = ruleRepo
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let decision = try await governance.canPerform(
                .modifyRules, member: currentMember, in: group, context: nil
            )
            canEditRules = (decision == .allowed)
        } catch {
            log.warning("governance check failed: \(error.localizedDescription)")
            canEditRules = false
        }

        do {
            let all = try await ruleRepo.list(groupId: group.id)
            let platform = all.filter { !$0.consequences.isEmpty }
            rules = platform.isEmpty ? all : platform
        } catch {
            log.warning("rules load failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }
}
```

(If existing call sites pass only `(group, ruleRepo)`, update them to pass `currentMember` and `governance` — these are typically held in `AppShell` or a global state.)

- [ ] **Step 3: Modify `RulesView.swift` to add the pencil button**

Add a `.toolbar` with a conditional pencil button:
```swift
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        if coordinator.canEditRules {
            NavigationLink {
                EditRulesView(coordinator: makeEditCoordinator())
            } label: {
                Image(systemName: "pencil")
            }
            .accessibilityLabel("Editar reglas")
        }
    }
}
```

`makeEditCoordinator()` constructs an `EditRulesCoordinator` reusing the existing `currentMember` / `governance` / `ruleRepo` — the simplest implementation is a private helper on `RulesView` that captures these from the existing init parameters.

- [ ] **Step 4: Build + run all unit tests + manual smoke**

Run:
```sh
cd ios && xcodegen
xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' 2>&1 | grep -E "Test Suite.*passed|Test Suite.*failed|error:" | tail -20
```
Expected: full suite green (modulo the pre-existing `GroupType decodes snake_case` failure).

Then manual smoke on simulator:
- Launch app, go to a group's Reglas tab.
- Verify pencil button appears (assuming logged-in user is founder of governance=founder group).
- Tap pencil → EditRulesView opens with 5 cards.
- Toggle one rule → optimistic flip + sync indicator → settles.
- Tap card → EditRuleSheet opens with the trigger / conditions summary + flat-amount field.
- Edit amount, tap "Save" → sheet dismisses, value updated.
- Tap "Archivar regla" → confirm dialog → cancel → no vote opened (until VotesRepository wiring lands).

- [ ] **Step 5: Commit**

```sh
git add ios/Tandas/Features/Rules/EditRuleSheet.swift \
  ios/Tandas/Features/Rules/RulesView.swift \
  ios/Tandas/Features/Rules/RulesCoordinator.swift
git commit -m "$(cat <<'EOF'
feat(rules): EditRuleSheet + conditional pencil in RulesView

Phase C3 of EditRulesView. EditRuleSheet renders the trigger /
conditions summary read-only, exposes flat-amount editing with explicit
"Save" gating (disabled while clean or while a repeal vote is pending),
and an "Archivar regla" destructive button that opens a rule_repeal
vote via VotesRepository. RulesView gains a conditional pencil button
in the trailing toolbar that pushes EditRulesView. RulesCoordinator
gains a canEditRules @Observable flag, refreshed via
governance.canPerform(.modifyRules) on every refresh().

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

## Phase D — Manual QA + push (1 commit)

### Task D1: Manual QA + final push

**Files:** none (verification + documentation only)

- [ ] **Step 1: Run full test suite (iOS + Postgres)**

iOS:
```sh
cd ios && xcodebuild test -project Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' 2>&1 | grep -E "Test Suite.*(passed|failed)" | tail -10
```

Postgres (assuming local supabase or staging access):
```sh
cd supabase/functions/_tests && deno test -A db/ 2>&1 | tail -5
```

Expected: all green except the pre-existing unrelated `GroupType decodes snake_case` failure.

- [ ] **Step 2: Manual QA checklist (paste results in commit message)**

Run each of the 18 items from the spec §Test plan §D Manual QA. For each, mark pass/fail.

QA items (from the spec):
- 9. Pencil visible only when actor passes `.modifyRules`. Test 4 cases.
- 10. Optimistic toggle: simulator with network throttled. Toggle UI flips immediately, after ~5s reverts + toast.
- 11. Edit amount on flat rule → succeeds; GroupHistoryView shows entry.
- 12. Edit amount on escalating rule → row is read-only with explainer.
- 13. Open repeal vote: tap "Archivar regla" → vote opens → return to EditRulesView → "Votación pendiente" badge visible. Tap card → sheet shows pending banner; amount/toggle disabled; "Ver votación →" works.
- 14. Vote resolves passed via admin-close SQL → rule disappears. Vote rejected → badge disappears, rule editable.
- 15. RLS denial path: alter governance via second client mid-session, retry edit → toast says "La gobernanza del grupo cambió. Tirá pull-to-refresh..."
- 16. Empty-state-equivalent: all 5 enabled → 5 active cards + footer.
- 17. Defensive fallback: 0-rule group → empty state copy, footer suppressed.
- 18. CI: codegen.yml + ios-ci.yml workflows green.

- [ ] **Step 3: Push the full sequence**

```sh
git push origin main 2>&1 | tail -3
```

- [ ] **Step 4: Update Roadmap.md to strike through Fase 0 #5 EditRulesView**

Edit `Plans/Roadmap.md`. In the Fase 0 §3 list, find:
```
   - `EditRulesView` + `EditRuleSheet` (gobernanza-aware)
```
Update to:
```
   - ~~`EditRulesView` + `EditRuleSheet` (gobernanza-aware)~~ ✅ shipped 2026-05-XX
```

- [ ] **Step 5: Final commit**

```sh
git add Plans/Roadmap.md
git commit -m "$(cat <<'EOF'
docs(roadmap): mark EditRulesView shipped (Fase 0 #5)

Closes the Fase 0 §5 P0 UI gap. All 18 manual QA items in the spec
test plan passed. CI green. Production groups can now self-edit
preset rules without engineering involvement (governance permitting).

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)" && git push origin main 2>&1 | tail -3
```

---

## Final verification

- [ ] Spec Success Criterion #1 — Founder of `whoCanModifyRules='founder'` group can toggle and edit flat amount; both emit corresponding system_events visible in GroupHistoryView. **Verified by QA #11 + Phase A3 trigger test.**
- [ ] Spec Success Criterion #2 — Archive opens `rule_repeal` vote; rule remains active until vote resolves; UI surfaces pending state. **Verified by QA #13 + Phase A4 unique-index test.**
- [ ] Spec Success Criterion #3 — Members of `whoCanModifyRules='majorityVote'` see no pencil. **Verified by QA #9 + Phase A5 can_modify_rules test.**
- [ ] Spec Success Criterion #4 — RLS test 8 demonstrates security boundary. **Verified by Phase A6 rls_update_rules test.**
- [ ] Spec Success Criterion #5 — Roadmap §3 Fase 0 #5 marked done. **Closed by Task D1 step 4.**
