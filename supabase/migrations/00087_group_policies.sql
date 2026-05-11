-- 00087_group_policies.sql
-- Group Governance Policies (Phase 1).
--
-- A policy answers "can actor X perform target_action Y on this group right
-- now?" Resolution is hierarchical: most-specific-wins. V1 only ships
-- group-scoped policies (target_resource_id null), V2 will add per-resource
-- and per-resource-type overrides via target_resource_id + target_resource_type.
--
-- Project conventions adopted (verified pre-flight, deviations from plan doc):
--   * `set_updated_at()` is the project-wide touch function (defined in 00001),
--     not `touch_updated_at()` as the plan text suggested.
--   * `has_permission(group_id, user_id, permission)` takes three args
--     (defined in 00063), not two. RLS passes `auth.uid()` explicitly.
--   * `group_members` uses a boolean `active` column (defined in 00001),
--     not `status = 'active'`. We reuse the existing `is_group_member`
--     helper for the read policy to stay consistent with mig 00002.

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

-- updated_at touch (project convention: public.set_updated_at()).
create trigger group_policies_set_updated_at
  before update on public.group_policies
  for each row execute function public.set_updated_at();

-- RLS.
alter table public.group_policies enable row level security;

-- Read: any active group member (mirrors mig 00002 conventions).
create policy group_policies_read on public.group_policies
  for select to authenticated
  using (public.is_group_member(group_policies.group_id, auth.uid()));

-- Write: only members with Permission.modifyGovernance via has_permission().
-- For V1 fallback that translates to founder (see mig 00063 role defaults).
create policy group_policies_write on public.group_policies
  for all to authenticated
  using (
    public.has_permission(group_policies.group_id, auth.uid(), 'modifyGovernance')
  )
  with check (
    public.has_permission(group_policies.group_id, auth.uid(), 'modifyGovernance')
  );
