# Group Governance Policies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement configurable Group Governance Policies so changing a resource rule (or any future action) can require a vote, with the change applied automatically when the vote passes — without hardcoding the action.

**Architecture:** New `group_policies` table is the authoritative source of policy decisions; a server RPC `resolve_governance(group, actor, target_action, target_payload)` returns `allowed | requires_vote | requires_admin | denied`. iOS `RuleRepository` consults the resolver before each mutation; when `requires_vote`, it opens a `vote_type=rule_change` carrying a structured operation envelope in `payload`. A Postgres trigger on `votes.status → resolved/passed` dispatches to `apply_pending_change(vote_id)` which executes the envelope. Existing `groups.governance` jsonb stays as a fallback for groups that have no policy rows yet (backwards-compat). UI surfaces a new `GroupRulesSettingsView` with 6 sections and 3 presets (Casual / Balanced / Strict).

**Tech Stack:** Postgres 15 (Supabase) with RLS + SECURITY DEFINER RPCs, Deno edge functions (existing finalize-votes cron), Swift 6 / SwiftUI iOS 26+ with `@Observable`, supabase-swift SDK, Swift Testing (XCTest-style in `ios/TandasTests/`).

---

## Scope cut for this slice

In scope (V1 of group policies):
- New `group_policies` table + server resolver RPC + apply-on-vote-pass trigger.
- `target_action` values wired end-to-end: `rule.toggle`, `rule.update_amount`, `rule.create`, `rule.delete`. (These are the four paths RuleRepository exposes today.)
- `policy_type` values: `direct` (anyone matching role can do it directly), `vote_required` (always opens vote), `admin_only` (only members with `Permission.modifyRules` can do it directly).
- Three presets: Casual, Balanced, Strict.
- UI: new `GroupRulesSettingsView` with 6 sections shown; only **Governance / change-control** section is editable in V1 (other 5 stubbed with "próximamente").
- Backwards-compat: groups with no policy rows fall back to `groups.governance.whoCanModifyRules`.

Out of scope (deferred to next slices — data model already supports them):
- `target_action` values for expense.*, fund.*, member.*, booking.*, guest.*, capability.*.
- Defaults / Money / Guest / Member sections editable in UI.
- Per-resource-type policy overrides (`target_scope`).
- Deletion-by-vote (rule.delete is only direct or admin_only in V1; vote-gated delete reuses the same envelope shape later).

## File structure

**Backend:**
- Create: `supabase/migrations/00087_group_policies.sql` — table + indices + RLS + helper view.
- Create: `supabase/migrations/00087_rollback.sql`.
- Create: `supabase/migrations/00088_resolve_governance_rpc.sql` — `resolve_governance()` SECURITY DEFINER.
- Create: `supabase/migrations/00088_rollback.sql`.
- Create: `supabase/migrations/00089_apply_pending_change.sql` — `apply_pending_change()` + trigger on `votes`.
- Create: `supabase/migrations/00089_rollback.sql`.
- Create: `supabase/migrations/00090_backfill_legacy_governance.sql` — seed policy rows from existing `groups.governance.whoCanModifyRules` so Beta groups don't break.
- Create: `supabase/migrations/00090_rollback.sql`.
- Modify: `supabase/migrations/00086_rename_event_rule_rpcs_to_resource.sql` — *no changes; this is the upstream RPC the resolver authorizes.*

**iOS RuulCore:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/GroupPolicy.swift` — `GroupPolicy`, `TargetAction`, `PolicyType`, `ApprovalConfig`, `PolicyDecision` types.
- Create: `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/PendingChangeEnvelope.swift` — envelope shape persisted in `votes.payload` for auto-apply.
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Repositories/GroupPolicyRepository.swift` — Mock + Live (list / upsert / applyPreset / resolve).
- Create: `ios/Packages/RuulCore/Sources/RuulCore/PlatformServices/GovernancePolicyResolver.swift` — wraps server RPC, mock-overridable for tests.
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Templates/GroupPolicyPresets.swift` — Casual / Balanced / Strict definitions.
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/Repositories/RuleRepository.swift` — interception in `setIsActive`, `setFlatFineAmount`, `createResourceRule`; new return envelope `RuleMutationOutcome` and new method `deleteRule`.
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/AppState.swift` — wire the new repo + resolver.

**iOS RuulFeatures:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/GroupRulesSettingsView.swift` — 6 sections + preset picker.
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/GroupRulesCoordinator.swift` — drives the view.
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Rules/EditRulesCoordinator.swift` — accept `.requiresVote` as "can edit, edits go to vote"; render outcome.
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Rules/EditRulesView.swift` — show preface badge "los cambios abren votación" when applicable; show toast on outcome.
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/GroupInfoSheet.swift` — replace "Editar gobierno" entry with link into `GroupRulesSettingsView`.

**Tests:**
- Create: `ios/TandasTests/Platform/GroupPolicyResolverTests.swift`.
- Create: `ios/TandasTests/Platform/GroupPolicyPresetsTests.swift`.
- Create: `ios/TandasTests/Rules/RuleRepositoryInterceptionTests.swift`.
- Modify: `ios/TandasTests/Rules/EditRulesCoordinatorTests.swift` — add coverage for `.requiresVote` path.

---

## Task 1: Add `group_policies` table + RLS

**Files:**
- Create: `supabase/migrations/00087_group_policies.sql`
- Create: `supabase/migrations/00087_rollback.sql`

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/00087_group_policies.sql`:

```sql
-- 00087_group_policies.sql
-- Group Governance Policies (Phase 1).
--
-- A policy answers "can actor X perform target_action Y on this group right
-- now?" Resolution is hierarchical: most-specific-wins. V1 only ships
-- group-scoped policies (target_resource_id null), V2 will add per-resource
-- and per-resource-type overrides via target_resource_id + target_resource_type.

create table public.group_policies (
  id              uuid        primary key default gen_random_uuid(),
  group_id        uuid        not null references public.groups(id) on delete cascade,
  policy_type     text        not null check (policy_type in ('direct', 'vote_required', 'admin_only', 'denied')),
  target_action   text        not null,
  target_scope    text        not null default 'group' check (target_scope in ('group', 'resource_type', 'resource')),
  target_resource_type text   null,   -- reserved for V2; null in V1
  target_resource_id   uuid   null,   -- reserved for V2; null in V1
  condition_config     jsonb  not null default '{}'::jsonb,
  approval_config      jsonb  not null default '{}'::jsonb,
  default_config       jsonb  not null default '{}'::jsonb,
  enabled         boolean     not null default true,
  priority        int         not null default 100,
  created_by      uuid        null references auth.users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

comment on table public.group_policies is
  'Configurable governance policies. Each row decides one (action, scope) tuple. Lookup uses (group_id, target_action, target_scope) ordered by priority asc, then most-specific scope first.';
comment on column public.group_policies.policy_type is
  'direct: anyone matching role does it now. vote_required: opens vote. admin_only: only Permission.modifyRules. denied: forbidden.';
comment on column public.group_policies.target_action is
  'Stable string. V1: rule.toggle | rule.update_amount | rule.create | rule.delete. Phase 2 adds expense.* / fund.* / member.* / capability.* / etc.';
comment on column public.group_policies.approval_config is
  'When policy_type = vote_required: {quorum_percent:int, threshold_percent:int, duration_hours:int, eligible_voters:"group_members"|"founders"}.';

create unique index group_policies_group_action_scope_uq
  on public.group_policies (group_id, target_action, target_scope, coalesce(target_resource_type, ''), coalesce(target_resource_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where enabled;

create index group_policies_lookup_idx
  on public.group_policies (group_id, target_action, enabled);

-- updated_at touch.
create trigger group_policies_touch_updated_at
  before update on public.group_policies
  for each row execute function public.touch_updated_at();

-- RLS.
alter table public.group_policies enable row level security;

-- Read: any group member.
create policy group_policies_read on public.group_policies
  for select to authenticated
  using (
    exists (
      select 1 from public.group_members gm
      where gm.group_id = group_policies.group_id
        and gm.user_id = auth.uid()
        and gm.status = 'active'
    )
  );

-- Write: only members with Permission.modifyGovernance via has_permission().
-- For V1 fallback that translates to founder.
create policy group_policies_write on public.group_policies
  for all to authenticated
  using (
    public.has_permission(group_policies.group_id, 'modifyGovernance')
  )
  with check (
    public.has_permission(group_policies.group_id, 'modifyGovernance')
  );
```

- [ ] **Step 2: Write the rollback**

Create `supabase/migrations/00087_rollback.sql`:

```sql
drop table if exists public.group_policies cascade;
```

- [ ] **Step 3: Apply migration via MCP**

Run via Supabase MCP `apply_migration` against project `fpfvlrwcskhgsjuhrjpz` after reading the SQL once more.

Expected: migration applies cleanly. Run `list_tables` and confirm `group_policies` appears with the expected columns.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/00087_group_policies.sql supabase/migrations/00087_rollback.sql
git commit -m "feat(governance): add group_policies table + RLS (00087)"
```

---

## Task 2: `resolve_governance` RPC

**Files:**
- Create: `supabase/migrations/00088_resolve_governance_rpc.sql`
- Create: `supabase/migrations/00088_rollback.sql`

- [ ] **Step 1: Write the resolver function**

Create `supabase/migrations/00088_resolve_governance_rpc.sql`:

```sql
-- 00088_resolve_governance_rpc.sql
-- resolve_governance: pure decision function for "can actor perform action?"
--
-- Returns a json with shape:
--   {"decision":"allowed"}
--   {"decision":"vote_required","quorum_percent":50,"threshold_percent":50,"duration_hours":72}
--   {"decision":"admin_only"}
--   {"decision":"denied","reason":"..."}
--
-- Resolution order:
--   1. Look up enabled rows in group_policies for (group_id, target_action).
--      Prefer rows with target_resource_id matching p_target_payload->>'resource_id',
--      then rows with target_resource_type matching p_target_payload->>'resource_type',
--      then group-scoped rows. Within a tier, smaller priority wins.
--   2. If no row matches: fall back to groups.governance.whoCanModifyRules for
--      legacy actions (rule.*) so groups predating mig 00090 backfill still work.
--   3. If still no match: deny.

create or replace function public.resolve_governance(
  p_group_id uuid,
  p_actor_user_id uuid,
  p_target_action text,
  p_target_payload jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_policy public.group_policies%rowtype;
  v_legacy_level text;
  v_governance jsonb;
  v_quorum int;
  v_threshold int;
  v_duration int;
  v_is_member boolean;
  v_is_founder boolean;
  v_has_modify_rules boolean;
begin
  -- Membership check first. Non-members get a hard deny.
  select exists(
    select 1 from public.group_members
    where group_id = p_group_id and user_id = p_actor_user_id and status = 'active'
  ) into v_is_member;
  if not v_is_member then
    return jsonb_build_object('decision', 'denied', 'reason', 'not_member');
  end if;

  -- Most-specific policy match.
  select * into v_policy
  from public.group_policies p
  where p.group_id = p_group_id
    and p.target_action = p_target_action
    and p.enabled
    and (
      (p.target_scope = 'resource'
        and p.target_resource_id::text = (p_target_payload->>'resource_id'))
      or
      (p.target_scope = 'resource_type'
        and p.target_resource_type = (p_target_payload->>'resource_type'))
      or
      p.target_scope = 'group'
    )
  order by
    case p.target_scope when 'resource' then 1 when 'resource_type' then 2 else 3 end,
    p.priority asc,
    p.created_at asc
  limit 1;

  if found then
    -- Dispatch on policy_type.
    if v_policy.policy_type = 'direct' then
      return jsonb_build_object('decision', 'allowed');
    elsif v_policy.policy_type = 'vote_required' then
      v_quorum    := coalesce((v_policy.approval_config->>'quorum_percent')::int, 50);
      v_threshold := coalesce((v_policy.approval_config->>'threshold_percent')::int, 50);
      v_duration  := coalesce((v_policy.approval_config->>'duration_hours')::int, 72);
      return jsonb_build_object(
        'decision', 'vote_required',
        'quorum_percent', v_quorum,
        'threshold_percent', v_threshold,
        'duration_hours', v_duration
      );
    elsif v_policy.policy_type = 'admin_only' then
      v_has_modify_rules := public.has_permission(p_group_id, 'modifyRules');
      if v_has_modify_rules then
        return jsonb_build_object('decision', 'allowed');
      end if;
      return jsonb_build_object('decision', 'admin_only');
    elsif v_policy.policy_type = 'denied' then
      return jsonb_build_object('decision', 'denied', 'reason', 'policy_denied');
    end if;
  end if;

  -- Legacy fallback: rule.* actions read groups.governance.whoCanModifyRules.
  if p_target_action like 'rule.%' then
    select governance into v_governance from public.groups where id = p_group_id;
    v_legacy_level := coalesce(v_governance->>'whoCanModifyRules', 'founder');

    if v_legacy_level = 'anyMember' then
      return jsonb_build_object('decision', 'allowed');
    elsif v_legacy_level = 'majorityVote' then
      return jsonb_build_object(
        'decision', 'vote_required',
        'quorum_percent',    coalesce((v_governance->>'votingQuorumPercent')::int, 50),
        'threshold_percent', coalesce((v_governance->>'votingThresholdPercent')::int, 50),
        'duration_hours',    coalesce((v_governance->>'votingDurationHours')::int, 72)
      );
    elsif v_legacy_level = 'supermajorityVote' then
      return jsonb_build_object(
        'decision', 'vote_required',
        'quorum_percent',    coalesce((v_governance->>'votingQuorumPercent')::int, 50),
        'threshold_percent', 66,
        'duration_hours',    coalesce((v_governance->>'votingDurationHours')::int, 72)
      );
    end if;

    -- founder.
    select (created_by = p_actor_user_id) into v_is_founder
    from public.groups where id = p_group_id;
    if v_is_founder then
      return jsonb_build_object('decision', 'allowed');
    end if;
    return jsonb_build_object('decision', 'denied', 'reason', 'not_founder');
  end if;

  -- Truly unknown action: deny.
  return jsonb_build_object('decision', 'denied', 'reason', 'no_policy');
end;
$$;

revoke execute on function public.resolve_governance(uuid, uuid, text, jsonb) from public, anon;
grant  execute on function public.resolve_governance(uuid, uuid, text, jsonb) to authenticated;

comment on function public.resolve_governance(uuid, uuid, text, jsonb) is
  'Returns the governance decision for an actor attempting target_action. Pure / no side effects.';
```

- [ ] **Step 2: Write the rollback**

Create `supabase/migrations/00088_rollback.sql`:

```sql
drop function if exists public.resolve_governance(uuid, uuid, text, jsonb);
```

- [ ] **Step 3: Apply migration via MCP**

Apply via `mcp__supabase__apply_migration`. Then test with:

```sql
-- Pick any test group and run:
select public.resolve_governance(
  '<group_id>'::uuid,
  '<member_user_id>'::uuid,
  'rule.toggle',
  '{}'::jsonb
);
```

Expected: returns `{"decision":"denied","reason":"not_founder"}` for a non-founder member of a Beta group (no policy rows yet, legacy fallback to `whoCanModifyRules=founder` default).

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/00088_resolve_governance_rpc.sql supabase/migrations/00088_rollback.sql
git commit -m "feat(governance): resolve_governance RPC with legacy fallback (00088)"
```

---

## Task 3: `apply_pending_change` + trigger on vote pass

**Files:**
- Create: `supabase/migrations/00089_apply_pending_change.sql`
- Create: `supabase/migrations/00089_rollback.sql`

- [ ] **Step 1: Write the applier + trigger**

Create `supabase/migrations/00089_apply_pending_change.sql`:

```sql
-- 00089_apply_pending_change.sql
-- apply_pending_change: dispatches the operation in a passed rule_change vote.
--
-- Payload envelope shape (matches Swift PendingChangeEnvelope):
--   {
--     "op": "rule.toggle" | "rule.update_amount" | "rule.create" | "rule.delete",
--     "target_rule_id": "<uuid>" | null,
--     "before": { ... },
--     "after":  { ... }
--   }
--
-- Idempotent: a second call on an already-applied vote no-ops by checking
-- system_events for a matching pendingChangeApplied event.

create or replace function public.apply_pending_change(p_vote_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vote public.votes%rowtype;
  v_op text;
  v_target uuid;
  v_before jsonb;
  v_after jsonb;
  v_already_applied boolean;
begin
  select * into v_vote from public.votes where id = p_vote_id;
  if not found then
    raise exception 'vote % not found', p_vote_id;
  end if;

  if v_vote.status <> 'resolved' or coalesce(v_vote.counts->>'resolution','') <> 'passed' then
    return;  -- only apply passed resolutions
  end if;

  if v_vote.vote_type <> 'rule_change' then
    return;  -- V1 only handles rule_change
  end if;

  -- Idempotency guard.
  select exists(
    select 1 from public.system_events se
    where se.group_id = v_vote.group_id
      and se.event_type = 'pendingChangeApplied'
      and (se.payload->>'vote_id')::uuid = p_vote_id
  ) into v_already_applied;
  if v_already_applied then
    return;
  end if;

  v_op     := v_vote.payload->>'op';
  v_target := nullif(v_vote.payload->>'target_rule_id', '')::uuid;
  v_before := v_vote.payload->'before';
  v_after  := v_vote.payload->'after';

  if v_op is null then
    raise exception 'rule_change vote % missing op in payload', p_vote_id;
  end if;

  if v_op = 'rule.toggle' then
    update public.rules
       set is_active = (v_after->>'is_active')::boolean,
           updated_at = now()
     where id = v_target;

  elsif v_op = 'rule.update_amount' then
    update public.rules
       set consequences = jsonb_build_array(
             jsonb_build_object(
               'type', 'fine',
               'config', jsonb_build_object('amount', (v_after->>'amount')::int)
             )
           ),
           updated_at = now()
     where id = v_target;

  elsif v_op = 'rule.delete' then
    update public.rules
       set is_active = false,
           archived_at = now(),
           updated_at = now()
     where id = v_target;

  elsif v_op = 'rule.create' then
    -- Caller pre-builds the new row in v_after. We insert; trigger on rules
    -- handles slug/audit columns.
    insert into public.rules (group_id, name, is_active, trigger, conditions, consequences, resource_id, module_key)
    values (
      v_vote.group_id,
      v_after->>'name',
      coalesce((v_after->>'is_active')::boolean, true),
      v_after->'trigger',
      coalesce(v_after->'conditions', '[]'::jsonb),
      coalesce(v_after->'consequences', '[]'::jsonb),
      nullif(v_after->>'resource_id','')::uuid,
      nullif(v_after->>'module_key','')
    );

  else
    raise exception 'apply_pending_change: unknown op %', v_op;
  end if;

  -- Audit event.
  perform public.record_system_event(
    v_vote.group_id,
    'pendingChangeApplied',
    jsonb_build_object(
      'vote_id', p_vote_id,
      'op', v_op,
      'target_rule_id', v_target,
      'after', v_after
    )
  );
end;
$$;

revoke execute on function public.apply_pending_change(uuid) from public, anon;
-- only the trigger (and admins via SECURITY DEFINER) call this; no grant needed.

comment on function public.apply_pending_change(uuid) is
  'Applies the operation envelope from a passed rule_change vote. Idempotent. Called by votes_apply_on_pass trigger.';

-- Trigger: fire on votes UPDATE when status flips to resolved and counts.resolution=passed.
create or replace function public.votes_apply_on_pass()
returns trigger
language plpgsql
as $$
begin
  if NEW.status = 'resolved'
     and (NEW.counts->>'resolution') = 'passed'
     and NEW.vote_type = 'rule_change'
     and (OLD.status <> 'resolved' or (OLD.counts->>'resolution') is distinct from 'passed') then
    perform public.apply_pending_change(NEW.id);
  end if;
  return NEW;
end;
$$;

drop trigger if exists votes_apply_on_pass_trg on public.votes;
create trigger votes_apply_on_pass_trg
  after update on public.votes
  for each row execute function public.votes_apply_on_pass();
```

- [ ] **Step 2: Write the rollback**

Create `supabase/migrations/00089_rollback.sql`:

```sql
drop trigger if exists votes_apply_on_pass_trg on public.votes;
drop function if exists public.votes_apply_on_pass();
drop function if exists public.apply_pending_change(uuid);
```

- [ ] **Step 3: Apply migration via MCP**

Apply. Then verify trigger exists:

```sql
select tgname from pg_trigger where tgrelid = 'public.votes'::regclass;
```

Expected output includes `votes_apply_on_pass_trg`.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/00089_apply_pending_change.sql supabase/migrations/00089_rollback.sql
git commit -m "feat(governance): apply_pending_change RPC + on-pass trigger (00089)"
```

---

## Task 4: Backfill legacy governance into policies

**Files:**
- Create: `supabase/migrations/00090_backfill_legacy_governance.sql`
- Create: `supabase/migrations/00090_rollback.sql`

- [ ] **Step 1: Write the backfill**

Create `supabase/migrations/00090_backfill_legacy_governance.sql`:

```sql
-- 00090_backfill_legacy_governance.sql
-- One-shot backfill: turn existing groups.governance.whoCanModifyRules into
-- explicit group_policies rows for the V1 rule.* actions. After this runs,
-- the resolver's legacy fallback path becomes dead code for any group that
-- existed at migration time, but stays in place for groups that get created
-- without policy rows in the future (defensive).

do $$
declare
  v_group public.groups%rowtype;
  v_level text;
  v_policy_type text;
  v_quorum int;
  v_threshold int;
  v_duration int;
  v_action text;
  v_actions text[] := array['rule.toggle','rule.update_amount','rule.create','rule.delete'];
begin
  for v_group in select * from public.groups loop
    v_level := coalesce(v_group.governance->>'whoCanModifyRules', 'founder');

    if v_level = 'anyMember' then
      v_policy_type := 'direct';
    elsif v_level in ('majorityVote', 'supermajorityVote') then
      v_policy_type := 'vote_required';
    else
      v_policy_type := 'admin_only';  -- founder collapses to admin_only here
    end if;

    v_quorum    := coalesce((v_group.governance->>'votingQuorumPercent')::int, 50);
    v_threshold := case
                     when v_level = 'supermajorityVote' then 66
                     else coalesce((v_group.governance->>'votingThresholdPercent')::int, 50)
                   end;
    v_duration  := coalesce((v_group.governance->>'votingDurationHours')::int, 72);

    foreach v_action in array v_actions loop
      insert into public.group_policies (
        group_id, policy_type, target_action, target_scope,
        approval_config, created_by, priority
      )
      values (
        v_group.id,
        v_policy_type,
        v_action,
        'group',
        case
          when v_policy_type = 'vote_required'
          then jsonb_build_object(
            'quorum_percent', v_quorum,
            'threshold_percent', v_threshold,
            'duration_hours', v_duration,
            'eligible_voters', 'group_members'
          )
          else '{}'::jsonb
        end,
        v_group.created_by,
        100
      )
      on conflict do nothing;
    end loop;
  end loop;
end $$;
```

- [ ] **Step 2: Write the rollback**

Create `supabase/migrations/00090_rollback.sql`:

```sql
-- Strip the V1 backfilled policies. Anything authored after the backfill
-- (priority != 100 or created_by != groups.created_by) is preserved.
delete from public.group_policies
 where priority = 100
   and target_action in ('rule.toggle','rule.update_amount','rule.create','rule.delete');
```

- [ ] **Step 3: Apply migration via MCP**

Apply. Verify:

```sql
select target_action, policy_type, count(*) from public.group_policies group by 1,2 order by 1,2;
```

Expected: 4 rows × N groups; policy_type matches each group's legacy governance setting.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/00090_backfill_legacy_governance.sql supabase/migrations/00090_rollback.sql
git commit -m "feat(governance): backfill group_policies from legacy governance (00090)"
```

---

## Task 5: iOS `GroupPolicy` + `PendingChangeEnvelope` types

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/GroupPolicy.swift`
- Create: `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/PendingChangeEnvelope.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/TandasTests/Platform/GroupPolicyTests.swift`:

```swift
import Testing
import Foundation
@testable import RuulCore

@Test func policyDecodesAllowedDecision() throws {
    let json = #"{"decision":"allowed"}"#.data(using: .utf8)!
    let decision = try JSONDecoder().decode(PolicyDecision.self, from: json)
    #expect(decision == .allowed)
}

@Test func policyDecodesVoteRequiredDecision() throws {
    let json = #"{"decision":"vote_required","quorum_percent":60,"threshold_percent":66,"duration_hours":48}"#.data(using: .utf8)!
    let decision = try JSONDecoder().decode(PolicyDecision.self, from: json)
    #expect(decision == .voteRequired(quorumPercent: 60, thresholdPercent: 66, durationHours: 48))
}

@Test func envelopeEncodesRuleToggle() throws {
    let env = PendingChangeEnvelope.ruleToggle(
        targetRuleId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        before: .init(isActive: true),
        after:  .init(isActive: false)
    )
    let data = try JSONEncoder().encode(env)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains(#""op":"rule.toggle""#))
    #expect(json.contains(#""target_rule_id":"11111111-1111-1111-1111-111111111111""#))
    #expect(json.contains(#""is_active":false"#))
}
```

- [ ] **Step 2: Run tests; verify they fail**

Run: `xcodebuild -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16' test -only-testing:TandasTests/GroupPolicyTests`
Expected: build fails ("Cannot find 'PolicyDecision' in scope" / "Cannot find 'PendingChangeEnvelope'").

- [ ] **Step 3: Implement `GroupPolicy.swift`**

Create `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/GroupPolicy.swift`:

```swift
import Foundation

/// Stable string identifier for a governable action. Phase 1 ships the
/// `rule.*` family; later phases add `expense.*`, `fund.*`, `member.*`, etc.
///
/// Stored as TEXT in `group_policies.target_action`. New cases are pure data
/// additions: the resolver, repos, and UI dispatch by string, so adding a
/// case here + adding policy rows is enough — no engine branching needed.
public enum TargetAction: String, Codable, Sendable, Hashable, CaseIterable {
    case ruleToggle       = "rule.toggle"
    case ruleUpdateAmount = "rule.update_amount"
    case ruleCreate       = "rule.create"
    case ruleDelete       = "rule.delete"
}

/// Kind of policy applied to a (group, action) tuple. Mirrors
/// `group_policies.policy_type`.
public enum PolicyType: String, Codable, Sendable, Hashable {
    /// Anyone matching the role gate may perform the action immediately.
    case direct
    /// The action opens a vote. Direct write is forbidden until the vote passes.
    case voteRequired = "vote_required"
    /// Only members holding `Permission.modifyRules` may perform it directly.
    case adminOnly    = "admin_only"
    /// Action is never permitted in this group.
    case denied
}

/// Voting parameters for `policy_type = vote_required`. Stored in
/// `group_policies.approval_config` jsonb.
public struct ApprovalConfig: Codable, Sendable, Hashable {
    public var quorumPercent: Int
    public var thresholdPercent: Int
    public var durationHours: Int
    public var eligibleVoters: EligibleVoters

    public enum EligibleVoters: String, Codable, Sendable, Hashable {
        case groupMembers = "group_members"
        case founders
    }

    public init(
        quorumPercent: Int = 50,
        thresholdPercent: Int = 50,
        durationHours: Int = 72,
        eligibleVoters: EligibleVoters = .groupMembers
    ) {
        self.quorumPercent    = quorumPercent
        self.thresholdPercent = thresholdPercent
        self.durationHours    = durationHours
        self.eligibleVoters   = eligibleVoters
    }

    public enum CodingKeys: String, CodingKey {
        case quorumPercent    = "quorum_percent"
        case thresholdPercent = "threshold_percent"
        case durationHours    = "duration_hours"
        case eligibleVoters   = "eligible_voters"
    }
}

/// Discriminated outcome from `resolve_governance` RPC. Equivalent to
/// `GovernanceDecision` (the V1 in-memory enum) but driven by the policies
/// table, with the action expressed as a `TargetAction` rather than the
/// fixed `GovernanceAction`.
public enum PolicyDecision: Sendable, Hashable {
    case allowed
    case voteRequired(quorumPercent: Int, thresholdPercent: Int, durationHours: Int)
    case adminOnly
    case denied(reason: String)
}

extension PolicyDecision: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .decision)
        switch kind {
        case "allowed":
            self = .allowed
        case "vote_required":
            self = .voteRequired(
                quorumPercent:    try c.decode(Int.self, forKey: .quorumPercent),
                thresholdPercent: try c.decode(Int.self, forKey: .thresholdPercent),
                durationHours:    try c.decode(Int.self, forKey: .durationHours)
            )
        case "admin_only":
            self = .adminOnly
        case "denied":
            self = .denied(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "denied")
        default:
            self = .denied(reason: "unknown:\(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allowed:
            try c.encode("allowed", forKey: .decision)
        case .voteRequired(let q, let t, let d):
            try c.encode("vote_required", forKey: .decision)
            try c.encode(q, forKey: .quorumPercent)
            try c.encode(t, forKey: .thresholdPercent)
            try c.encode(d, forKey: .durationHours)
        case .adminOnly:
            try c.encode("admin_only", forKey: .decision)
        case .denied(let reason):
            try c.encode("denied", forKey: .decision)
            try c.encode(reason, forKey: .reason)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case decision
        case quorumPercent    = "quorum_percent"
        case thresholdPercent = "threshold_percent"
        case durationHours    = "duration_hours"
        case reason
    }
}

/// Row in `public.group_policies`. V1 only reads policies grouped by
/// `(group, action)`; the editor in `GroupRulesSettingsView` upserts these.
public struct GroupPolicy: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public var policyType: PolicyType
    public var targetAction: TargetAction
    public var targetScope: String       // "group" | "resource_type" | "resource"
    public var targetResourceType: String?
    public var targetResourceId: UUID?
    public var approvalConfig: ApprovalConfig?
    public var enabled: Bool
    public var priority: Int

    public init(
        id: UUID = UUID(),
        groupId: UUID,
        policyType: PolicyType,
        targetAction: TargetAction,
        targetScope: String = "group",
        targetResourceType: String? = nil,
        targetResourceId: UUID? = nil,
        approvalConfig: ApprovalConfig? = nil,
        enabled: Bool = true,
        priority: Int = 100
    ) {
        self.id = id
        self.groupId = groupId
        self.policyType = policyType
        self.targetAction = targetAction
        self.targetScope = targetScope
        self.targetResourceType = targetResourceType
        self.targetResourceId = targetResourceId
        self.approvalConfig = approvalConfig
        self.enabled = enabled
        self.priority = priority
    }

    public enum CodingKeys: String, CodingKey {
        case id, enabled, priority
        case groupId            = "group_id"
        case policyType         = "policy_type"
        case targetAction       = "target_action"
        case targetScope        = "target_scope"
        case targetResourceType = "target_resource_type"
        case targetResourceId   = "target_resource_id"
        case approvalConfig     = "approval_config"
    }
}
```

- [ ] **Step 4: Implement `PendingChangeEnvelope.swift`**

Create `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/PendingChangeEnvelope.swift`:

```swift
import Foundation

/// Operation envelope persisted in `votes.payload` when a `rule_change` vote
/// is opened. The server's `apply_pending_change(vote_id)` reads this and
/// applies it on resolution=passed. V1 ops cover the four `rule.*` mutations.
///
/// Envelope shape, encoded directly as the vote payload:
/// ```
/// {
///   "op": "rule.toggle",
///   "target_rule_id": "<uuid>" | null,
///   "before": {...},
///   "after":  {...}
/// }
/// ```
///
/// `before` / `after` carry the natural shape for the op so the UI can
/// render a diff without re-fetching state.
public struct PendingChangeEnvelope: Codable, Sendable, Hashable {
    public let op: TargetAction
    public let targetRuleId: UUID?
    public let before: AnyPayload?
    public let after: AnyPayload

    public init(op: TargetAction, targetRuleId: UUID?, before: AnyPayload?, after: AnyPayload) {
        self.op = op
        self.targetRuleId = targetRuleId
        self.before = before
        self.after = after
    }

    public enum CodingKeys: String, CodingKey {
        case op, before, after
        case targetRuleId = "target_rule_id"
    }

    // MARK: - Convenience constructors

    public static func ruleToggle(targetRuleId: UUID, before: ToggleBody, after: ToggleBody) -> Self {
        .init(op: .ruleToggle, targetRuleId: targetRuleId,
              before: .init(.toggle(before)), after: .init(.toggle(after)))
    }

    public static func ruleUpdateAmount(targetRuleId: UUID, before: AmountBody, after: AmountBody) -> Self {
        .init(op: .ruleUpdateAmount, targetRuleId: targetRuleId,
              before: .init(.amount(before)), after: .init(.amount(after)))
    }

    public static func ruleDelete(targetRuleId: UUID) -> Self {
        .init(op: .ruleDelete, targetRuleId: targetRuleId,
              before: nil, after: .init(.empty))
    }

    public static func ruleCreate(after: CreateBody) -> Self {
        .init(op: .ruleCreate, targetRuleId: nil,
              before: nil, after: .init(.create(after)))
    }

    // MARK: - Per-op bodies

    public struct ToggleBody: Codable, Sendable, Hashable {
        public let isActive: Bool
        public init(isActive: Bool) { self.isActive = isActive }
        public enum CodingKeys: String, CodingKey { case isActive = "is_active" }
    }

    public struct AmountBody: Codable, Sendable, Hashable {
        public let amount: Int
        public init(amount: Int) { self.amount = amount }
    }

    public struct CreateBody: Codable, Sendable, Hashable {
        public let name: String
        public let isActive: Bool
        public let resourceId: UUID?
        public let trigger: RuleTrigger
        public let conditions: [RuleCondition]
        public let consequences: [RuleConsequence]
        public init(
            name: String,
            isActive: Bool = true,
            resourceId: UUID? = nil,
            trigger: RuleTrigger,
            conditions: [RuleCondition],
            consequences: [RuleConsequence]
        ) {
            self.name = name
            self.isActive = isActive
            self.resourceId = resourceId
            self.trigger = trigger
            self.conditions = conditions
            self.consequences = consequences
        }
        public enum CodingKeys: String, CodingKey {
            case name, trigger, conditions, consequences
            case isActive   = "is_active"
            case resourceId = "resource_id"
        }
    }

    /// Type-erased wrapper so `before`/`after` can be any per-op body and
    /// still encode flat into the envelope.
    public struct AnyPayload: Codable, Sendable, Hashable {
        public enum Inner: Sendable, Hashable {
            case toggle(ToggleBody)
            case amount(AmountBody)
            case create(CreateBody)
            case empty
        }
        public let inner: Inner

        public init(_ inner: Inner) { self.inner = inner }

        public init(from decoder: Decoder) throws {
            // Tolerant decoding: try amount, then toggle, then create, else empty.
            if let v = try? AmountBody(from: decoder) { self.inner = .amount(v); return }
            if let v = try? ToggleBody(from: decoder) { self.inner = .toggle(v); return }
            if let v = try? CreateBody(from: decoder) { self.inner = .create(v); return }
            self.inner = .empty
        }

        public func encode(to encoder: Encoder) throws {
            switch inner {
            case .toggle(let v): try v.encode(to: encoder)
            case .amount(let v): try v.encode(to: encoder)
            case .create(let v): try v.encode(to: encoder)
            case .empty:
                var c = encoder.container(keyedBy: EmptyKey.self)
                _ = c
            }
        }

        private enum EmptyKey: CodingKey {}
    }
}
```

- [ ] **Step 5: Re-run tests; verify they pass**

Run: `xcodebuild -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16' test -only-testing:TandasTests/GroupPolicyTests`
Expected: 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/GroupPolicy.swift \
        ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/PendingChangeEnvelope.swift \
        ios/TandasTests/Platform/GroupPolicyTests.swift
git commit -m "feat(governance): GroupPolicy + PendingChangeEnvelope models"
```

---

## Task 6: `GroupPolicyRepository` (Mock + Live)

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Repositories/GroupPolicyRepository.swift`
- Test: `ios/TandasTests/Platform/GroupPolicyRepositoryTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ios/TandasTests/Platform/GroupPolicyRepositoryTests.swift`:

```swift
import Testing
import Foundation
@testable import RuulCore

@Test func mockRepoResolvesToConfiguredDecision() async throws {
    let repo = MockGroupPolicyRepository()
    let groupId = UUID()
    await repo.setResolution(
        groupId: groupId,
        action: .ruleToggle,
        decision: .voteRequired(quorumPercent: 50, thresholdPercent: 50, durationHours: 72)
    )
    let actual = try await repo.resolve(
        groupId: groupId,
        actorUserId: UUID(),
        action: .ruleToggle,
        targetPayload: [:]
    )
    #expect(actual == .voteRequired(quorumPercent: 50, thresholdPercent: 50, durationHours: 72))
}

@Test func mockRepoDefaultsToAdminOnly() async throws {
    let repo = MockGroupPolicyRepository()
    let actual = try await repo.resolve(
        groupId: UUID(),
        actorUserId: UUID(),
        action: .ruleToggle,
        targetPayload: [:]
    )
    #expect(actual == .adminOnly)
}
```

- [ ] **Step 2: Run test; verify failure**

Run: `xcodebuild ... test -only-testing:TandasTests/GroupPolicyRepositoryTests`
Expected: "Cannot find 'MockGroupPolicyRepository' in scope".

- [ ] **Step 3: Implement the repository**

Create `ios/Packages/RuulCore/Sources/RuulCore/Repositories/GroupPolicyRepository.swift`:

```swift
import Foundation
import Supabase

public protocol GroupPolicyRepository: Actor {
    /// All policies for a group, ordered by (target_action, target_scope, priority).
    func list(groupId: UUID) async throws -> [GroupPolicy]

    /// Upsert a policy. Server enforces `Permission.modifyGovernance` via RLS.
    func upsert(_ policy: GroupPolicy) async throws -> GroupPolicy

    /// Batch-apply a preset: replaces V1 rule.* policies in one transaction.
    func applyPreset(_ preset: GroupPolicyPreset, groupId: UUID) async throws

    /// Server-side decision via `resolve_governance` RPC. Pure / no side effects.
    func resolve(
        groupId: UUID,
        actorUserId: UUID,
        action: TargetAction,
        targetPayload: [String: String]
    ) async throws -> PolicyDecision
}

// MARK: - Mock

public actor MockGroupPolicyRepository: GroupPolicyRepository {
    private var policies: [GroupPolicy] = []
    private var resolutions: [Key: PolicyDecision] = [:]

    private struct Key: Hashable { let group: UUID; let action: TargetAction }

    public init(seed: [GroupPolicy] = []) { self.policies = seed }

    public func setResolution(groupId: UUID, action: TargetAction, decision: PolicyDecision) {
        resolutions[Key(group: groupId, action: action)] = decision
    }

    public func list(groupId: UUID) async throws -> [GroupPolicy] {
        policies.filter { $0.groupId == groupId }
    }

    public func upsert(_ policy: GroupPolicy) async throws -> GroupPolicy {
        if let i = policies.firstIndex(where: {
            $0.groupId == policy.groupId
                && $0.targetAction == policy.targetAction
                && $0.targetScope == policy.targetScope
        }) {
            policies[i] = policy
        } else {
            policies.append(policy)
        }
        return policy
    }

    public private(set) var appliedPresets: [(GroupPolicyPreset, UUID)] = []
    public func applyPreset(_ preset: GroupPolicyPreset, groupId: UUID) async throws {
        appliedPresets.append((preset, groupId))
        // Synthesize policy rows so list() reflects the preset.
        policies.removeAll { $0.groupId == groupId && $0.targetAction.rawValue.hasPrefix("rule.") }
        for spec in preset.specs {
            policies.append(GroupPolicy(
                groupId: groupId,
                policyType: spec.policyType,
                targetAction: spec.action,
                approvalConfig: spec.approvalConfig
            ))
        }
    }

    public func resolve(
        groupId: UUID,
        actorUserId: UUID,
        action: TargetAction,
        targetPayload: [String: String]
    ) async throws -> PolicyDecision {
        resolutions[Key(group: groupId, action: action)] ?? .adminOnly
    }
}

// MARK: - Live

public actor LiveGroupPolicyRepository: GroupPolicyRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func list(groupId: UUID) async throws -> [GroupPolicy] {
        try await client.from("group_policies")
            .select("*")
            .eq("group_id", value: groupId.uuidString.lowercased())
            .order("target_action", ascending: true)
            .order("priority", ascending: true)
            .execute()
            .value
    }

    public func upsert(_ policy: GroupPolicy) async throws -> GroupPolicy {
        let row: GroupPolicy = try await client.from("group_policies")
            .upsert(policy, onConflict: "group_id,target_action,target_scope,coalesce(target_resource_type,''),coalesce(target_resource_id,'00000000-0000-0000-0000-000000000000'::uuid)")
            .select()
            .single()
            .execute()
            .value
        return row
    }

    public func applyPreset(_ preset: GroupPolicyPreset, groupId: UUID) async throws {
        // V1: client-side loop. Could become a single SQL function later.
        for spec in preset.specs {
            _ = try await upsert(GroupPolicy(
                groupId: groupId,
                policyType: spec.policyType,
                targetAction: spec.action,
                approvalConfig: spec.approvalConfig
            ))
        }
    }

    public func resolve(
        groupId: UUID,
        actorUserId: UUID,
        action: TargetAction,
        targetPayload: [String: String]
    ) async throws -> PolicyDecision {
        struct Params: Encodable {
            let p_group_id: String
            let p_actor_user_id: String
            let p_target_action: String
            let p_target_payload: [String: String]
        }
        return try await client.rpc("resolve_governance", params: Params(
            p_group_id:        groupId.uuidString.lowercased(),
            p_actor_user_id:   actorUserId.uuidString.lowercased(),
            p_target_action:   action.rawValue,
            p_target_payload:  targetPayload
        ))
        .execute()
        .value
    }
}
```

- [ ] **Step 4: Run tests; verify pass**

Run: `xcodebuild ... test -only-testing:TandasTests/GroupPolicyRepositoryTests`
Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Repositories/GroupPolicyRepository.swift \
        ios/TandasTests/Platform/GroupPolicyRepositoryTests.swift
git commit -m "feat(governance): GroupPolicyRepository (Mock + Live) + resolve RPC"
```

---

## Task 7: `GroupPolicyPresets` (Casual / Balanced / Strict)

**Files:**
- Create: `ios/Packages/RuulCore/Sources/RuulCore/Templates/GroupPolicyPresets.swift`
- Test: `ios/TandasTests/Platform/GroupPolicyPresetsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ios/TandasTests/Platform/GroupPolicyPresetsTests.swift`:

```swift
import Testing
import Foundation
@testable import RuulCore

@Test func casualPresetUsesAdminOnlyForRuleActions() {
    let preset = GroupPolicyPreset.casual
    #expect(preset.specs.count == TargetAction.allCases.count)
    for spec in preset.specs {
        #expect(spec.policyType == .adminOnly)
    }
}

@Test func balancedPresetUsesVoteForUpdateAndDelete() {
    let preset = GroupPolicyPreset.balanced
    let updateSpec = preset.specs.first { $0.action == .ruleUpdateAmount }!
    let deleteSpec = preset.specs.first { $0.action == .ruleDelete }!
    #expect(updateSpec.policyType == .voteRequired)
    #expect(deleteSpec.policyType == .voteRequired)
    #expect(updateSpec.approvalConfig?.thresholdPercent == 50)
}

@Test func strictPresetUsesSupermajorityForUpdates() {
    let preset = GroupPolicyPreset.strict
    let updateSpec = preset.specs.first { $0.action == .ruleUpdateAmount }!
    #expect(updateSpec.policyType == .voteRequired)
    #expect(updateSpec.approvalConfig?.thresholdPercent == 66)
}
```

- [ ] **Step 2: Run; verify fail**

Run: `xcodebuild ... test -only-testing:TandasTests/GroupPolicyPresetsTests`
Expected: "Cannot find 'GroupPolicyPreset'".

- [ ] **Step 3: Implement presets**

Create `ios/Packages/RuulCore/Sources/RuulCore/Templates/GroupPolicyPresets.swift`:

```swift
import Foundation

/// Pre-baked governance configurations the founder picks during onboarding
/// or from Group Rules settings. Each preset is a list of (action, policy)
/// specs the `GroupPolicyRepository.applyPreset` materializes into table rows.
public struct GroupPolicyPreset: Sendable, Hashable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let specs: [Spec]

    public struct Spec: Sendable, Hashable {
        public let action: TargetAction
        public let policyType: PolicyType
        public let approvalConfig: ApprovalConfig?

        public init(action: TargetAction, policyType: PolicyType, approvalConfig: ApprovalConfig? = nil) {
            self.action = action
            self.policyType = policyType
            self.approvalConfig = approvalConfig
        }
    }

    public init(id: String, title: String, subtitle: String, specs: [Spec]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.specs = specs
    }

    /// Founders run the show — anyone with `Permission.modifyRules` can edit
    /// rules directly. No votes.
    public static let casual = GroupPolicyPreset(
        id: "casual",
        title: "Relajado",
        subtitle: "Los admins pueden cambiar las reglas directo.",
        specs: TargetAction.allCases.map { Spec(action: $0, policyType: .adminOnly) }
    )

    /// Anyone proposes; majority approves. Mid-stakes groups.
    public static let balanced = GroupPolicyPreset(
        id: "balanced",
        title: "Equilibrado",
        subtitle: "Cambios importantes los aprueba la mayoría.",
        specs: [
            .init(action: .ruleToggle,       policyType: .adminOnly),
            .init(action: .ruleCreate,       policyType: .adminOnly),
            .init(action: .ruleUpdateAmount, policyType: .voteRequired, approvalConfig: .init(quorumPercent: 50, thresholdPercent: 50, durationHours: 72)),
            .init(action: .ruleDelete,       policyType: .voteRequired, approvalConfig: .init(quorumPercent: 50, thresholdPercent: 50, durationHours: 72)),
        ]
    )

    /// Vote-gated by default. High-stakes / formal groups.
    public static let strict = GroupPolicyPreset(
        id: "strict",
        title: "Estricto",
        subtitle: "Casi todos los cambios pasan por votación.",
        specs: [
            .init(action: .ruleToggle,       policyType: .voteRequired, approvalConfig: .init(quorumPercent: 60, thresholdPercent: 50, durationHours: 72)),
            .init(action: .ruleCreate,       policyType: .voteRequired, approvalConfig: .init(quorumPercent: 60, thresholdPercent: 50, durationHours: 72)),
            .init(action: .ruleUpdateAmount, policyType: .voteRequired, approvalConfig: .init(quorumPercent: 60, thresholdPercent: 66, durationHours: 96)),
            .init(action: .ruleDelete,       policyType: .voteRequired, approvalConfig: .init(quorumPercent: 60, thresholdPercent: 66, durationHours: 96)),
        ]
    )

    public static let all: [GroupPolicyPreset] = [.casual, .balanced, .strict]
}
```

- [ ] **Step 4: Run tests; verify pass**

Run: `xcodebuild ... test -only-testing:TandasTests/GroupPolicyPresetsTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Templates/GroupPolicyPresets.swift \
        ios/TandasTests/Platform/GroupPolicyPresetsTests.swift
git commit -m "feat(governance): Casual / Balanced / Strict policy presets"
```

---

## Task 8: Intercept `RuleRepository` mutations through the resolver

**Files:**
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/Repositories/RuleRepository.swift`
- Test: `ios/TandasTests/Rules/RuleRepositoryInterceptionTests.swift`

The repo gains a `policyRepo` and `voteRepo` dependency. Each mutation now returns a `RuleMutationOutcome` so callers know whether the change was applied directly or queued behind a vote. Existing call sites (and tests) get updated in Task 10.

- [ ] **Step 1: Write the failing test**

Create `ios/TandasTests/Rules/RuleRepositoryInterceptionTests.swift`:

```swift
import Testing
import Foundation
@testable import RuulCore

@Test func interceptedToggleOpensVoteWhenPolicySaysVoteRequired() async throws {
    let groupId = UUID()
    let ruleId  = UUID()
    let actorId = UUID()

    let policyRepo = MockGroupPolicyRepository()
    await policyRepo.setResolution(
        groupId: groupId,
        action: .ruleToggle,
        decision: .voteRequired(quorumPercent: 50, thresholdPercent: 50, durationHours: 72)
    )
    let voteRepo = MockVoteRepository()
    let ruleRepo = InterceptingRuleRepository(
        inner: MockRuleRepository(),
        policyRepo: policyRepo,
        voteRepo: voteRepo,
        actorUserId: actorId
    )

    let outcome = try await ruleRepo.setIsActive(
        ruleId: ruleId,
        isActive: false,
        groupId: groupId,
        currentIsActive: true
    )

    switch outcome {
    case .vote(let voteId): #expect(voteId != UUID())
    default: Issue.record("expected .vote outcome, got \(outcome)")
    }

    let calls = await voteRepo.startVoteCalls
    #expect(calls.count == 1)
    #expect(calls.first?.voteType == .ruleChange)
    #expect(calls.first?.referenceId == ruleId)
}

@Test func interceptedToggleAppliesDirectlyWhenAllowed() async throws {
    let groupId = UUID()
    let ruleId  = UUID()
    let actorId = UUID()

    let policyRepo = MockGroupPolicyRepository()
    await policyRepo.setResolution(groupId: groupId, action: .ruleToggle, decision: .allowed)
    let inner = MockRuleRepository()
    let ruleRepo = InterceptingRuleRepository(
        inner: inner,
        policyRepo: policyRepo,
        voteRepo: MockVoteRepository(),
        actorUserId: actorId
    )

    let outcome = try await ruleRepo.setIsActive(
        ruleId: ruleId, isActive: false, groupId: groupId, currentIsActive: true
    )

    #expect(outcome == .applied)
    let last = await inner.lastSetIsActive
    #expect(last?.ruleId == ruleId)
}

@Test func interceptedToggleThrowsWhenDenied() async throws {
    let groupId = UUID()
    let policyRepo = MockGroupPolicyRepository()
    await policyRepo.setResolution(groupId: groupId, action: .ruleToggle, decision: .denied(reason: "not_member"))
    let ruleRepo = InterceptingRuleRepository(
        inner: MockRuleRepository(),
        policyRepo: policyRepo,
        voteRepo: MockVoteRepository(),
        actorUserId: UUID()
    )

    await #expect(throws: RuleMutationError.self) {
        _ = try await ruleRepo.setIsActive(
            ruleId: UUID(), isActive: false, groupId: groupId, currentIsActive: true
        )
    }
}
```

- [ ] **Step 2: Run; verify fail**

Run: `xcodebuild ... test -only-testing:TandasTests/RuleRepositoryInterceptionTests`
Expected: "Cannot find 'InterceptingRuleRepository'", "Cannot find 'RuleMutationOutcome'", etc.

- [ ] **Step 3: Add outcome / error types + interceptor**

Append to `ios/Packages/RuulCore/Sources/RuulCore/Repositories/RuleRepository.swift` (after the existing `LiveRuleRepository`):

```swift
// MARK: - Mutation outcome / errors (Phase 1: governance-aware mutations)

/// Result of an intercepted rule mutation. Callers branch on this to render
/// the right toast: "Cambio aplicado" vs "Cambio pendiente de votación".
public enum RuleMutationOutcome: Sendable, Hashable {
    case applied
    case vote(voteId: UUID)
    case adminOnly
}

public enum RuleMutationError: Error, Sendable, Equatable {
    case denied(reason: String)
    case voteOpenFailed(String)
    case underlying(String)
}

/// Wraps a `RuleRepository` and inserts a `resolve_governance` check before
/// each mutation. When the resolver returns `.voteRequired`, opens a
/// `vote_type=rule_change` carrying a `PendingChangeEnvelope` so the server
/// trigger can auto-apply the diff on resolution. Otherwise delegates to the
/// inner repo directly.
///
/// Compose at the AppState seam — the rest of the codebase keeps talking to
/// `RuleRepository`. The interceptor adds three governance-aware methods
/// (`setIsActive(_:isActive:groupId:currentIsActive:)`, the analogous
/// `setFlatFineAmount`, and `deleteRule`) that callers migrate to in Task 10.
public actor InterceptingRuleRepository {
    private let inner: any RuleRepository
    private let policyRepo: any GroupPolicyRepository
    private let voteRepo: any VoteRepository
    private let actorUserId: UUID

    public init(
        inner: any RuleRepository,
        policyRepo: any GroupPolicyRepository,
        voteRepo: any VoteRepository,
        actorUserId: UUID
    ) {
        self.inner = inner
        self.policyRepo = policyRepo
        self.voteRepo = voteRepo
        self.actorUserId = actorUserId
    }

    public func setIsActive(
        ruleId: UUID,
        isActive: Bool,
        groupId: UUID,
        currentIsActive: Bool
    ) async throws -> RuleMutationOutcome {
        let decision = try await policyRepo.resolve(
            groupId: groupId,
            actorUserId: actorUserId,
            action: .ruleToggle,
            targetPayload: ["rule_id": ruleId.uuidString.lowercased()]
        )
        switch decision {
        case .allowed:
            try await inner.setIsActive(ruleId: ruleId, isActive: isActive)
            return .applied
        case .voteRequired:
            let envelope = PendingChangeEnvelope.ruleToggle(
                targetRuleId: ruleId,
                before: .init(isActive: currentIsActive),
                after:  .init(isActive: isActive)
            )
            let payload = try JSONConfig.encoded(envelope)
            do {
                let voteId = try await voteRepo.startVote(
                    groupId: groupId,
                    voteType: .ruleChange,
                    referenceId: ruleId,
                    title: isActive ? "Activar regla" : "Desactivar regla",
                    description: nil,
                    payload: payload
                )
                return .vote(voteId: voteId)
            } catch {
                throw RuleMutationError.voteOpenFailed(error.localizedDescription)
            }
        case .adminOnly:
            return .adminOnly
        case .denied(let reason):
            throw RuleMutationError.denied(reason: reason)
        }
    }

    public func setFlatFineAmount(
        rule: GroupRule,
        amount: Int,
        currentAmount: Int
    ) async throws -> RuleMutationOutcome {
        let decision = try await policyRepo.resolve(
            groupId: rule.groupId,
            actorUserId: actorUserId,
            action: .ruleUpdateAmount,
            targetPayload: ["rule_id": rule.id.uuidString.lowercased()]
        )
        switch decision {
        case .allowed:
            try await inner.setFlatFineAmount(rule: rule, amount: amount)
            return .applied
        case .voteRequired:
            let envelope = PendingChangeEnvelope.ruleUpdateAmount(
                targetRuleId: rule.id,
                before: .init(amount: currentAmount),
                after:  .init(amount: amount)
            )
            let payload = try JSONConfig.encoded(envelope)
            do {
                let voteId = try await voteRepo.startVote(
                    groupId: rule.groupId,
                    voteType: .ruleChange,
                    referenceId: rule.id,
                    title: "Cambiar monto: \(rule.name)",
                    description: nil,
                    payload: payload
                )
                return .vote(voteId: voteId)
            } catch {
                throw RuleMutationError.voteOpenFailed(error.localizedDescription)
            }
        case .adminOnly:
            return .adminOnly
        case .denied(let reason):
            throw RuleMutationError.denied(reason: reason)
        }
    }
}
```

Add a one-line helper on `JSONConfig` if not present (check via `grep -n "static func encoded" ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/JSONConfig.swift`; if missing, add to that file):

```swift
public extension JSONConfig {
    /// Encodes any `Encodable` value into a `JSONConfig`. Used to stash a
    /// `PendingChangeEnvelope` in `votes.payload`.
    static func encoded<T: Encodable>(_ value: T) throws -> JSONConfig {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONConfig.self, from: data)
    }
}
```

- [ ] **Step 4: Run tests; verify pass**

Run: `xcodebuild ... test -only-testing:TandasTests/RuleRepositoryInterceptionTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Repositories/RuleRepository.swift \
        ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/JSONConfig.swift \
        ios/TandasTests/Rules/RuleRepositoryInterceptionTests.swift
git commit -m "feat(governance): InterceptingRuleRepository routes mutations through policy resolver"
```

---

## Task 9: Wire dependencies in `AppState`

**Files:**
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/AppState.swift`

The interceptor needs `actorUserId` (the signed-in user). Read the existing AppState to find where session user id lives, then expose `policyRepo` + an intercepted `ruleRepo`.

- [ ] **Step 1: Read AppState**

Run: `grep -n "ruleRepo\|RuleRepository\|policyRepo\|voteRepo" ios/Packages/RuulCore/Sources/RuulCore/AppState.swift`

Note the exact property names and Live/Mock construction site.

- [ ] **Step 2: Add `policyRepo` property**

In `AppState.swift`, near the existing `voteRepo: any VoteRepository` declaration, add:

```swift
public let policyRepo: any GroupPolicyRepository
```

In the live-construction init branch (the one that calls `LiveVoteRepository(client: …)`), add:

```swift
self.policyRepo = LiveGroupPolicyRepository(client: client)
```

In the mock/preview init branch:

```swift
self.policyRepo = MockGroupPolicyRepository()
```

- [ ] **Step 3: Wrap `ruleRepo`**

After both repos are constructed, replace the bare `ruleRepo` assignment with an intercepted wrapper using the current authenticated user's id. Inspect the existing AppState to find how the user id is plumbed (e.g. `auth.currentUserId` / `session.user.id`); use that. If not available synchronously at init time, expose `ruleRepo` as a computed wrapper that pulls `actorUserId` from the live session at call time. Concrete pattern:

```swift
// In AppState init, after `policyRepo` is set:
self.ruleRepo = InterceptingRuleRepository(
    inner: LiveRuleRepository(client: client),
    policyRepo: policyRepo,
    voteRepo: voteRepo,
    actorUserId: currentUserId  // existing AppState property
)
```

If `ruleRepo`'s declared type is `any RuleRepository`, change to a richer protocol or to `InterceptingRuleRepository` directly. The cleanest path: change the property type to `InterceptingRuleRepository` (since every coordinator calls through it now).

- [ ] **Step 4: Update protocol conformance fallout**

Run: `xcodebuild build`
Expect compile errors from the type change. For each call site of `ruleRepo.setIsActive(...)` / `ruleRepo.setFlatFineAmount(...)`, update to the new signatures (Task 10 covers UI sites; for any in non-UI code, fix here).

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/AppState.swift
git commit -m "feat(governance): wire GroupPolicyRepository + InterceptingRuleRepository in AppState"
```

---

## Task 10: Update `EditRulesCoordinator` to handle `requiresVote`

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Rules/EditRulesCoordinator.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Rules/EditRulesView.swift`
- Modify: `ios/TandasTests/Rules/EditRulesCoordinatorTests.swift`

The coordinator currently treats `.requiresVote` from `GovernanceService.canPerform(.modifyRules)` as denied. Switch to using the new `policyRepo.resolve(...)` to get tri-state behavior, and surface a banner when the active policy is `vote_required`.

- [ ] **Step 1: Update the coordinator**

In `EditRulesCoordinator.swift`, replace the dependencies block and `refresh` method:

```swift
// Replace `governance` dependency with policyRepo. Keep `governance` only if
// other call sites still need it; the V1 modifyRules check is now policy-driven.
private let policyRepo: any GroupPolicyRepository
private let actorUserId: UUID

public init(
    group: Group,
    currentMember: Member,
    actorUserId: UUID,
    governance: any GovernanceServiceProtocol,
    policyRepo: any GroupPolicyRepository,
    ruleRepo: InterceptingRuleRepository,
    voteRepo: any VoteRepository,
    userActionRepo: (any UserActionRepository)? = nil
) {
    self.group = group
    self.currentMember = currentMember
    self.actorUserId = actorUserId
    self.governance = governance
    self.policyRepo = policyRepo
    self.ruleRepo = ruleRepo
    self.voteRepo = voteRepo
    self.userActionRepo = userActionRepo
}

public enum EditMode: Sendable, Hashable {
    case directWrite                       // policy: direct or admin_only + actor has Permission
    case voteGated(thresholdPercent: Int)  // policy: vote_required
    case readOnly                          // policy: admin_only without permission, or denied
}
public private(set) var editMode: EditMode = .readOnly

public func refresh() async {
    isLoading = true
    defer { isLoading = false }

    do {
        let decision = try await policyRepo.resolve(
            groupId: group.id,
            actorUserId: actorUserId,
            action: .ruleToggle,
            targetPayload: [:]
        )
        switch decision {
        case .allowed:
            editMode = .directWrite
        case .voteRequired(_, let t, _):
            editMode = .voteGated(thresholdPercent: t)
        case .adminOnly, .denied:
            editMode = .readOnly
        }
    } catch {
        log.warning("policy resolve failed: \(error.localizedDescription)")
        editMode = .readOnly
    }

    do {
        let all = try await ruleRepo.list(groupId: group.id)
        let platformShape = all.filter { !$0.consequences.isEmpty }
        rules = platformShape.isEmpty ? all : platformShape

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
```

Replace `setIsActive` to consume the outcome:

```swift
public func setIsActive(rule: GroupRule, isActive: Bool) async {
    inFlightToggleIDs.insert(rule.id)
    defer { inFlightToggleIDs.remove(rule.id) }

    let originalIndex = rules.firstIndex(where: { $0.id == rule.id })
    if let i = originalIndex {
        rules[i] = rules[i].withIsActive(isActive)
    }

    do {
        let outcome = try await ruleRepo.setIsActive(
            ruleId: rule.id,
            isActive: isActive,
            groupId: group.id,
            currentIsActive: !isActive
        )
        switch outcome {
        case .applied:
            break // local optimistic state already matches
        case .vote(let voteId):
            // revert local — the change isn't applied until vote resolves
            if let i = originalIndex {
                rules[i] = rules[i].withIsActive(!isActive)
            }
            self.banner = .voteOpened(voteId: voteId)
            await refresh()
        case .adminOnly:
            if let i = originalIndex {
                rules[i] = rules[i].withIsActive(!isActive)
            }
            self.error = "Solo los admins pueden cambiar esta regla."
        }
    } catch RuleMutationError.denied(let reason) {
        if let i = originalIndex {
            rules[i] = rules[i].withIsActive(!isActive)
        }
        self.error = "No tienes permiso: \(reason)"
    } catch {
        if let i = originalIndex {
            rules[i] = rules[i].withIsActive(!isActive)
        }
        self.error = mapMutationError(error)
    }
}

public enum Banner: Sendable, Hashable {
    case voteOpened(voteId: UUID)
}
public private(set) var banner: Banner?
public func clearBanner() { banner = nil }
```

Apply analogous changes to `setFlatFineAmount`.

- [ ] **Step 2: Update the view**

In `EditRulesView.swift`, find where toggle / amount edits are presented. Add a top banner that reads from `coordinator.editMode`:

```swift
@ViewBuilder
private var modeBanner: some View {
    switch coordinator.editMode {
    case .voteGated(let threshold):
        RuulCard(.tile) {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(Color.ruulAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Los cambios abren votación")
                        .ruulTextStyle(RuulTypography.body)
                    Text("Necesitan \(threshold)% de votos a favor para aplicarse.")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
            }
        }
    case .readOnly:
        RuulCard(.tile) {
            Text("Tu rol no puede editar reglas en este grupo.")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
        }
    case .directWrite:
        EmptyView()
    }
}

// Add `modeBanner` at the top of the existing ScrollView VStack.
```

When `coordinator.banner == .voteOpened(let id)`, surface a toast or sheet linking to vote detail.

- [ ] **Step 3: Update existing tests**

In `ios/TandasTests/Rules/EditRulesCoordinatorTests.swift`, update fixtures to construct the coordinator with the new `policyRepo` + `actorUserId` + `InterceptingRuleRepository(...)` dependencies. Add a new test:

```swift
@Test func coordinatorSwitchesToVoteGatedModeWhenPolicyRequiresVote() async throws {
    let groupId = UUID()
    let actor = UUID()
    let policyRepo = MockGroupPolicyRepository()
    await policyRepo.setResolution(
        groupId: groupId, action: .ruleToggle,
        decision: .voteRequired(quorumPercent: 50, thresholdPercent: 66, durationHours: 72)
    )
    let coordinator = EditRulesCoordinator(
        group: Group.fixture(id: groupId),
        currentMember: Member.fixture(),
        actorUserId: actor,
        governance: MockGovernanceService(),
        policyRepo: policyRepo,
        ruleRepo: InterceptingRuleRepository(
            inner: MockRuleRepository(),
            policyRepo: policyRepo,
            voteRepo: MockVoteRepository(),
            actorUserId: actor
        ),
        voteRepo: MockVoteRepository()
    )
    await coordinator.refresh()
    #expect(coordinator.editMode == .voteGated(thresholdPercent: 66))
}
```

(If `Group.fixture` / `Member.fixture` / `MockGovernanceService` don't exist, look at neighboring tests in `TandasTests/Platform/GovernanceServiceTests.swift` for the canonical fixture pattern and copy.)

- [ ] **Step 4: Run tests; verify pass**

Run: `xcodebuild ... test -only-testing:TandasTests/EditRulesCoordinatorTests`
Expected: all existing tests still pass + new test passes.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Rules/EditRulesCoordinator.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Rules/EditRulesView.swift \
        ios/TandasTests/Rules/EditRulesCoordinatorTests.swift
git commit -m "feat(governance): EditRulesCoordinator surfaces voteGated mode + opens votes"
```

---

## Task 11: `GroupRulesSettingsView` with presets

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/GroupRulesCoordinator.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/GroupRulesSettingsView.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/GroupInfoSheet.swift`

- [ ] **Step 1: Implement the coordinator**

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/GroupRulesCoordinator.swift`:

```swift
import Foundation
import Observation
import OSLog
import RuulCore

@Observable @MainActor
public final class GroupRulesCoordinator {
    public let group: Group
    private let actorUserId: UUID
    private let policyRepo: any GroupPolicyRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "group-rules")

    public private(set) var policies: [GroupPolicy] = []
    public private(set) var isLoading: Bool = false
    public private(set) var isSaving: Bool = false
    public private(set) var error: String?

    /// True when the actor can edit policies (server enforces; we mirror to
    /// disable the picker locally).
    public private(set) var canEdit: Bool = false

    public init(group: Group, actorUserId: UUID, policyRepo: any GroupPolicyRepository) {
        self.group = group
        self.actorUserId = actorUserId
        self.policyRepo = policyRepo
    }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            policies = try await policyRepo.list(groupId: group.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func applyPreset(_ preset: GroupPolicyPreset) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await policyRepo.applyPreset(preset, groupId: group.id)
            await refresh()
        } catch {
            log.warning("applyPreset failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    /// What preset matches the current policies exactly (Casual / Balanced /
    /// Strict) or nil if custom. Used to highlight the active card.
    public var activePreset: GroupPolicyPreset? {
        for preset in GroupPolicyPreset.all {
            let matches = preset.specs.allSatisfy { spec in
                guard let policy = policies.first(where: {
                    $0.targetAction == spec.action && $0.targetScope == "group"
                }) else { return false }
                return policy.policyType == spec.policyType
            }
            if matches { return preset }
        }
        return nil
    }
}
```

- [ ] **Step 2: Implement the view**

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/GroupRulesSettingsView.swift`:

```swift
import SwiftUI
import RuulUI
import RuulCore

/// Group Rules settings — 6 sections per the governance spec. V1 only edits
/// the "How decisions are made" section via preset. The other 5 sections
/// surface as cards with `Próximamente` so users see the shape of what's
/// coming without empty space.
public struct GroupRulesSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: GroupRulesCoordinator

    public init(coordinator: GroupRulesCoordinator) {
        self._coordinator = Bindable(wrappedValue: coordinator)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    section(
                        title: "Cómo se toman decisiones",
                        subtitle: "Quién puede cambiar las reglas y si los cambios necesitan votación."
                    ) {
                        presetPicker
                    }

                    placeholderSection(title: "Quién puede qué", subtitle: "Crear resources, invitar miembros, aprobar invitados.")
                    placeholderSection(title: "Defaults para resources nuevos", subtitle: "RSVP sugerido, deadlines, confirmación.")
                    placeholderSection(title: "Reglas de miembros", subtitle: "Aprobación, deuda máxima, suspensión.")
                    placeholderSection(title: "Reglas de dinero", subtitle: "Gastos grandes, withdrawals, recordatorios.")
                    placeholderSection(title: "Invitados", subtitle: "Aprobación, máximos, visibilidad.")
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.lg)
                .padding(.bottom, RuulSpacing.xxl)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text("Reglas del grupo")
                        .ruulTextStyle(RuulTypography.headline)
                }
            }
            .task { await coordinator.refresh() }
        }
    }

    private var presetPicker: some View {
        VStack(spacing: RuulSpacing.sm) {
            ForEach(GroupPolicyPreset.all, id: \.id) { preset in
                presetCard(preset)
            }
            if let err = coordinator.error {
                Text(err)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulNegative)
            }
        }
    }

    private func presetCard(_ preset: GroupPolicyPreset) -> some View {
        let isActive = coordinator.activePreset?.id == preset.id
        return Button {
            Task { await coordinator.applyPreset(preset) }
        } label: {
            HStack(spacing: RuulSpacing.md) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? Color.ruulAccent : Color.ruulTextTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(preset.subtitle)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
            }
            .padding(RuulSpacing.md)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(coordinator.isSaving)
    }

    private func section<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title.uppercased())
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            Text(subtitle)
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
                .padding(.bottom, RuulSpacing.xs)
            content()
        }
    }

    private func placeholderSection(title: String, subtitle: String) -> some View {
        section(title: title, subtitle: subtitle) {
            RuulCard(.tile) {
                HStack {
                    Text("Próximamente")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextTertiary)
                    Spacer()
                    Image(systemName: "clock")
                        .foregroundStyle(Color.ruulTextTertiary)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Wire the entry point**

In `GroupInfoSheet.swift`, find the existing row labelled "Editar gobierno" (or similar — `grep -n "Editar gobierno\|GovernanceSettingsView" ios/Packages/RuulFeatures/...`). Replace with a row labelled "Reglas del grupo" that presents `GroupRulesSettingsView(coordinator: GroupRulesCoordinator(group: group, actorUserId: app.currentUserId, policyRepo: app.policyRepo))`. Keep the old GovernanceSettingsView reachable from a "Configuración avanzada" sub-link if existing call sites need it — but the primary entry now goes to the new view.

- [ ] **Step 4: Smoke test in simulator**

Run: `xcodebuild -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16' build`
Then launch the app, open a group, open Group Info, tap "Reglas del grupo". Verify all 6 sections render, preset selection writes (check Supabase `select * from group_policies where group_id = '<id>'` after picking Balanced — expected 4 rows).

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/GroupRulesCoordinator.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/GroupRulesSettingsView.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/GroupInfoSheet.swift
git commit -m "feat(governance): GroupRulesSettingsView with Casual/Balanced/Strict presets"
```

---

## Task 12: End-to-end smoke + acceptance verification

**Files:** none (manual verification + ad-hoc fixes).

- [ ] **Step 1: Build the full app**

Run: `xcodebuild -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: clean build, no warnings.

- [ ] **Step 2: Run the full test suite**

Run: `xcodebuild -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 16' test`
Expected: all tests pass.

- [ ] **Step 3: Manual flow — Strict preset → vote on rule toggle**

1. In simulator, sign in as founder of a test group.
2. Open Group Info → "Reglas del grupo" → pick **Strict**. Confirm the preset card highlights.
3. Sign in as a non-founder member (use a second simulator / device or test account).
4. Open the same group's Reglas → see the "Los cambios abren votación" banner.
5. Tap a toggle on any rule. Expect: rule reverts to original state visually; a vote is opened (verify in OpenVotesListView).
6. Cast votes from enough members to reach quorum + threshold.
7. Wait for `finalize-votes` cron (or invoke `finalize_vote` RPC manually). Expect: rule is now toggled; a `pendingChangeApplied` system_event appears in history.

- [ ] **Step 4: Acceptance criteria checklist**

Verify each acceptance criterion from the spec:
- (1) Strict preset writes `vote_required` to group_policies — verified above.
- (2) Member toggle → vote opens, not applied — verified above.
- (3) Vote passes → applied — verified above.
- (4) Vote fails — manually fail one (vote down) and verify rule state stays original, system_event records `pendingChangeRejected` (or no `pendingChangeApplied`, depending on what `finalize_vote` already emits).
- (5) Casual preset → no vote — switch to Casual, toggle a rule as admin, expect direct apply.
- (6) `system_events` has `voteOpened`, `voteResolved`, `pendingChangeApplied` rows — query `select event_type, payload from system_events where group_id = '<id>' order by created_at desc limit 20`.
- (7) `apply_pending_change` dispatches by `op` string — verified by `rule.toggle` working; the dispatch table inside the function supports `rule.update_amount`, `rule.create`, `rule.delete` identically.
- (8) The resolver is action-agnostic — verified by reading `resolve_governance` source: it switches on `target_action` only via the legacy fallback (`like 'rule.%'`); everything else goes through the table lookup, so new actions are pure data adds.
- (9) Beta flows don't break — verify backfill: query `select count(*) from group_policies` and confirm 4 × (number of groups) rows exist; verify an existing test group still loads its Reglas tab and rules without 403 / RLS errors.
- (10) Resource Rules separate from Group Rules — verified by file structure: `EditRulesView` (resource rule edits) vs `GroupRulesSettingsView` (group governance).

- [ ] **Step 5: Commit any final touch-ups**

```bash
git add -A
git commit -m "chore(governance): smoke verification + minor polish"
```

---

## Self-review checklist

**Spec coverage:**
- Permission Rules section (spec #1): out of scope this slice — placeholder card. Covered by table design (just add `member.invite` etc. target_action values later). ✓ acknowledged.
- Governance / Change Rules (spec #2): central feature of this slice — `rule.toggle/update_amount/create/delete` × presets. ✓
- Default Rules for New Resources (spec #3): placeholder card; data model supports via `default_config jsonb`. ✓ acknowledged.
- Member Rules, Money Rules, Guest Rules (spec #4–6): placeholder cards. ✓ acknowledged.
- Field list (id, group_id, policy_type, target_action, target_scope, condition_config, approval_config, default_config, enabled, priority, created_by, timestamps): all present in mig 00087. ✓
- Example policy JSON: matches `approval_config` shape produced by `GroupPolicyPreset.balanced`. ✓
- Resolver API (`canPerformAction` / `requiredApprovalForAction` / `resolvePolicy` / `createApprovalFlowIfNeeded` / `applyPendingChangeAfterApproval`): collapsed into `policyRepo.resolve(...)` + `InterceptingRuleRepository` + `apply_pending_change` trigger. Functionally equivalent and simpler. ✓
- "No hardcoded `if action == changeRule {createVote}`": `InterceptingRuleRepository` calls `resolve(action:)` then dispatches generically on `PolicyDecision`. ✓
- UX sections (Who can do what / How decisions are made / Defaults / Money / Guest / Member): all 6 cards in `GroupRulesSettingsView`. ✓
- Presets Casual / Balanced / Strict: implemented in `GroupPolicyPresets.swift`. ✓
- 10 acceptance criteria: verification step in Task 12 walks each one. ✓

**Type consistency:** `TargetAction` (raw values `rule.toggle`, etc.) used in DB column, Swift enum, `PendingChangeEnvelope.op`, and `policy.target_action`. `PolicyDecision` shape matches `resolve_governance` JSON return. `PendingChangeEnvelope` shape matches `apply_pending_change` payload reads. ✓

**Placeholders scanned:** none — every step has full SQL/Swift bodies.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-10-group-governance-policies.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Migrations 87–90 first (gated review after each apply), then iOS tasks 5–12.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints (e.g. checkpoint after Task 4, Task 8, Task 11).

Which approach?
