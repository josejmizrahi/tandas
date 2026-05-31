-- 00078 — BigBang OpenPlatform Foundation.
--
-- Founder directive 2026-05-10: drop Beta 1, build the Resources × Capability
-- Blocks taxonomy (Plans/Active/Taxonomy_Resources_and_Capabilities.md) as the
-- new default. No coexistence layers; aggressive forward-only.
--
-- Pre-conditions (verified before applying):
--   - Production data wiped (only modules + templates + profiles preserved)
--   - 00077 (on_fine_inserted Phase 2 fix) applied
--   - Rules architecture refactor 00071-00076 applied (Phase A)
--
-- This migration:
--
--   1. DROPS legacy `groups` columns that encoded vertical (recurring_dinner)
--      assumptions: event_label, frequency_type, frequency_config,
--      default_day_of_week, default_start_time, default_location,
--      fund_balance, rotation_mode.
--
--   2. DROPS legacy RPCs: seed_dinner_template_rules wrapper and
--      seed_template_rules_legacy fallback. iOS callers will now go through
--      seed_module_rules / set_group_module / add_resource (Phase 2 RPC).
--
--   3. CREATES four new tables that materialize the taxonomy:
--      - resource_series       — recurrence + pattern (event series, slot
--                                series, contribution series, …)
--      - resource_capabilities — per-resource capability block config
--      - ledger_entries        — money atoms (expense, contribution, payout,
--                                fine_issued, fine_paid, settlement, …)
--      - rsvp_actions          — RSVP atoms (append-only, replaces mutable
--                                event_attendance for RSVP audit trail)
--
--   4. ADDS columns:
--      - modules.provided_capability_blocks text[]
--      - resources.series_id    uuid → resource_series
--      - rules.series_id        uuid → resource_series   (scope precedence)
--      - rules.membership_id    uuid → group_members     (scope precedence)
--      Note: occurrence-scoped rules use rules.resource_id (occurrences ARE
--      resources per taxonomy §1.4).
--
--   5. SEEDS modules.provided_capability_blocks per Taxonomy doc §2 catalog.
--
--   6. Enables RLS on new tables with sensible defaults (group members read,
--      group admins write). Phase 2+ refines per-capability.
--
-- Rollback exists in 00078_rollback.sql but it cannot restore wiped Beta 1
-- data. Roll-forward expected.

-- =========================================================
-- 1. Drop legacy `groups` columns + dependent triggers
-- =========================================================
-- These encoded recurring-dinner assumptions or stored fields that should be
-- projections from atoms. After this migration:
--   - eventVocabulary lives in groups.settings (jsonb)
--   - recurrence/scheduling lives in resource_series
--   - voting params live in groups.governance (jsonb, mig 00019)
--   - fund_* becomes a Fund resource type (Phase 3)
--   - fines_enabled becomes modules.contains('basic_fines')
--   - fines configs (no_show_grace_minutes, etc.) become basic_fines module config
--   - rotation_mode becomes capability config on rotation resource

drop trigger if exists groups_sync_rotation on public.groups;
drop trigger if exists groups_sync_basic_fines_module on public.groups;
drop function if exists public.sync_rotation_fields() cascade;
drop function if exists public.groups_sync_basic_fines_module() cascade;
drop view if exists public.invite_preview;

alter table public.groups
  -- recurring-dinner scheduling
  drop column if exists event_label,
  drop column if exists frequency_type,
  drop column if exists frequency_config,
  drop column if exists default_day_of_week,
  drop column if exists default_start_time,
  drop column if exists default_location,
  drop column if exists auto_generate_events,
  -- rotation legacy
  drop column if exists rotation_mode,
  drop column if exists rotation_enabled,
  -- fund legacy (replaced by Fund resource type Phase 3)
  drop column if exists fund_enabled,
  drop column if exists fund_balance,
  drop column if exists fund_target,
  drop column if exists fund_target_label,
  drop column if exists fund_min_participants,
  drop column if exists fund_admin,
  -- fines legacy (replaced by modules + basic_fines config)
  drop column if exists fines_enabled,
  drop column if exists block_unpaid_attendance,
  drop column if exists no_show_grace_minutes,
  drop column if exists grace_period_events,
  drop column if exists monthly_fine_cap_mxn,
  -- governance shadows (canonical lives in groups.governance jsonb)
  drop column if exists voting_threshold,
  drop column if exists voting_quorum,
  drop column if exists vote_duration_hours,
  drop column if exists committee_required_for_appeals;

drop index if exists public.idx_groups_frequency_type;
drop index if exists public.idx_groups_rotation_enabled;
drop index if exists public.idx_groups_fund_admin;
drop index if exists public.idx_groups_fines_enabled;

-- Recreate invite_preview with capability-agnostic shape. iOS Invite preview
-- will derive event-specific fields (vocabulary, recurrence) from the new
-- ResourceSeries / Resource model rather than group-level scheduling.
create or replace view public.invite_preview as
  select g.id              as group_id,
         g.name             as group_name,
         g.cover_image_name,
         g.invite_code,
         g.created_at       as group_created_at,
         (select count(*)
            from public.group_members gm
           where gm.group_id = g.id and gm.active) as member_count,
         (select array_agg(p.display_name order by gm.joined_at)
            from public.group_members gm
            join public.profiles p on p.id = gm.user_id
           where gm.group_id = g.id and gm.active
           limit 5) as recent_member_names
    from public.groups g;

comment on view public.invite_preview is
  'Group invite preview. Capability-agnostic: only identity + membership. Phase 2 will add a sibling view that joins active ResourceSeries for richer previews.';

-- =========================================================
-- 2. Drop legacy RPCs
-- =========================================================
drop function if exists public.seed_dinner_template_rules(uuid);
drop function if exists public.seed_template_rules_legacy(text, uuid);

-- =========================================================
-- 3. New tables
-- =========================================================

-- 3a. resource_series — recurrence container
create table public.resource_series (
  id            uuid primary key default gen_random_uuid(),
  group_id      uuid not null references public.groups(id) on delete cascade,
  resource_type text not null,
  pattern       jsonb not null default '{}',
  metadata      jsonb not null default '{}',
  active        boolean not null default true,
  created_by    uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index idx_resource_series_group on public.resource_series(group_id);
create index idx_resource_series_type  on public.resource_series(resource_type);
create index idx_resource_series_active on public.resource_series(group_id) where active = true;

create trigger resource_series_set_updated_at
  before update on public.resource_series
  for each row execute function public.set_updated_at();

comment on table public.resource_series is
  'Recurrence container per Taxonomy §1.3. Holds pattern (frequency, dayOfWeek, startTime, …) and generates occurrences (each one a row in public.resources with series_id set). Replaces group-level scheduling that lived on groups.frequency_* before BigBang.';

-- 3b. resource_capabilities — per-resource capability block config
create table public.resource_capabilities (
  resource_id         uuid not null references public.resources(id) on delete cascade,
  capability_block_id text not null,
  config              jsonb not null default '{}',
  enabled             boolean not null default true,
  enabled_at          timestamptz not null default now(),
  enabled_by          uuid references auth.users(id) on delete set null,
  primary key (resource_id, capability_block_id)
);
create index idx_resource_capabilities_block on public.resource_capabilities(capability_block_id);
create index idx_resource_capabilities_enabled on public.resource_capabilities(resource_id) where enabled = true;

comment on table public.resource_capabilities is
  'Per-resource capability block configuration per Taxonomy §2. Each row = (resource, capability) pair with its config jsonb. Enables progressive opt-in: a resource starts bare, capabilities get added explicitly.';

-- 3c. ledger_entries — money atoms
create table public.ledger_entries (
  id              uuid primary key default gen_random_uuid(),
  group_id        uuid not null references public.groups(id) on delete cascade,
  resource_id     uuid null references public.resources(id) on delete cascade,
  type            text not null,
  amount_cents    bigint not null,
  currency        text not null default 'MXN',
  from_member_id  uuid null references public.group_members(id) on delete set null,
  to_member_id    uuid null references public.group_members(id) on delete set null,
  metadata        jsonb not null default '{}',
  occurred_at     timestamptz not null default now(),
  recorded_at     timestamptz not null default now(),
  recorded_by     uuid references auth.users(id) on delete set null
);
create index idx_ledger_group_time on public.ledger_entries(group_id, occurred_at);
create index idx_ledger_resource on public.ledger_entries(resource_id) where resource_id is not null;
create index idx_ledger_type on public.ledger_entries(type);

comment on table public.ledger_entries is
  'Money atoms per Taxonomy §2.E. Append-only ledger for expense, contribution, payout, fine_issued, fine_paid, settlement, etc. Balance projections derive from this table — never store balances elsewhere.';

-- 3d. rsvp_actions — RSVP atoms
create table public.rsvp_actions (
  id           uuid primary key default gen_random_uuid(),
  resource_id  uuid not null references public.resources(id) on delete cascade,
  member_id    uuid not null references public.group_members(id) on delete cascade,
  status       text not null,
  recorded_at  timestamptz not null default now(),
  metadata     jsonb not null default '{}'
);
create index idx_rsvp_actions_resource_time on public.rsvp_actions(resource_id, recorded_at desc);
create index idx_rsvp_actions_member on public.rsvp_actions(member_id);

comment on table public.rsvp_actions is
  'RSVP atoms per Taxonomy §2.C. Append-only. Replaces mutable event_attendance.rsvp_status as the audit trail. Latest-per-(resource,member) becomes the projection.';

-- =========================================================
-- 4. Add columns to existing tables
-- =========================================================

-- 4a. modules.provided_capability_blocks
alter table public.modules
  add column if not exists provided_capability_blocks text[] not null default '{}';

comment on column public.modules.provided_capability_blocks is
  'Capability block ids this module provides. Per Taxonomy §2 catalog. iOS CapabilityResolver consults this to determine which blocks become available when a module is in groups.active_modules.';

-- 4b. resources.series_id (occurrences link to their series)
alter table public.resources
  add column if not exists series_id uuid null
    references public.resource_series(id) on delete set null;

create index if not exists idx_resources_series on public.resources(series_id) where series_id is not null;

comment on column public.resources.series_id is
  'When this resource is an occurrence of a ResourceSeries, points to the series row. Per Taxonomy §1.4. Null for one-off resources.';

-- 4c. rules.series_id and rules.membership_id (scope precedence per Taxonomy §29)
alter table public.rules
  add column if not exists series_id     uuid null
    references public.resource_series(id) on delete cascade,
  add column if not exists membership_id uuid null
    references public.group_members(id) on delete cascade;

create index if not exists idx_rules_series on public.rules(series_id) where series_id is not null;
create index if not exists idx_rules_membership on public.rules(membership_id) where membership_id is not null;

comment on column public.rules.series_id is
  'Rule scope: when set, applies to a ResourceSeries (and all its occurrences unless overridden at occurrence level via resource_id). Per Taxonomy §29.';
comment on column public.rules.membership_id is
  'Rule scope: when set, applies to a specific member only. Per-member deviations.';

-- =========================================================
-- 5. Seed modules.provided_capability_blocks per Taxonomy
-- =========================================================
update public.modules set provided_capability_blocks = array[
  'rules', 'consequence', 'ledger'
]::text[] where id = 'basic_fines';

update public.modules set provided_capability_blocks = array[
  'rotation', 'assignment'
]::text[] where id = 'rotating_host';

update public.modules set provided_capability_blocks = array[
  'rsvp', 'attendance', 'deadline'
]::text[] where id = 'rsvp';

update public.modules set provided_capability_blocks = array[
  'check_in', 'attendance'
]::text[] where id = 'check_in';

update public.modules set provided_capability_blocks = array[
  'appeal', 'voting', 'consequence'
]::text[] where id = 'appeal_voting';

update public.modules set provided_capability_blocks = array[
  'rotation', 'assignment', 'participants'
]::text[] where id = 'rotating_position';

update public.modules set provided_capability_blocks = array[
  'schedule', 'capacity', 'assignment', 'booking', 'expiration'
]::text[] where id = 'slot_assignment';

update public.modules set provided_capability_blocks = array[
  'swap', 'approval'
]::text[] where id = 'slot_swap_request';

-- =========================================================
-- 6. RLS for new tables
-- =========================================================
-- Default policy: group members can SELECT; group admins can INSERT/UPDATE/
-- DELETE. Phase 2 may refine per-capability. Mirror of the existing
-- resources/rules policy pattern.

-- 6a. resource_series
alter table public.resource_series enable row level security;

create policy "resource_series_read_member" on public.resource_series
  for select to authenticated
  using (public.is_group_member(group_id, auth.uid()));

create policy "resource_series_write_admin" on public.resource_series
  for all to authenticated
  using (public.is_group_admin(group_id, auth.uid()))
  with check (public.is_group_admin(group_id, auth.uid()));

-- 6b. resource_capabilities — gate via resource → group membership
alter table public.resource_capabilities enable row level security;

create policy "resource_capabilities_read_member" on public.resource_capabilities
  for select to authenticated
  using (
    exists (
      select 1 from public.resources r
       where r.id = resource_capabilities.resource_id
         and public.is_group_member(r.group_id, auth.uid())
    )
  );

create policy "resource_capabilities_write_admin" on public.resource_capabilities
  for all to authenticated
  using (
    exists (
      select 1 from public.resources r
       where r.id = resource_capabilities.resource_id
         and public.is_group_admin(r.group_id, auth.uid())
    )
  )
  with check (
    exists (
      select 1 from public.resources r
       where r.id = resource_capabilities.resource_id
         and public.is_group_admin(r.group_id, auth.uid())
    )
  );

-- 6c. ledger_entries
alter table public.ledger_entries enable row level security;

create policy "ledger_entries_read_member" on public.ledger_entries
  for select to authenticated
  using (public.is_group_member(group_id, auth.uid()));

-- Writes via SECURITY DEFINER RPCs (record_expense, record_contribution, …
-- — Phase 3). Block direct INSERT for now; admins can correct via RPC.
create policy "ledger_entries_write_admin" on public.ledger_entries
  for insert to authenticated
  with check (public.is_group_admin(group_id, auth.uid()));

-- 6d. rsvp_actions
alter table public.rsvp_actions enable row level security;

create policy "rsvp_actions_read_member" on public.rsvp_actions
  for select to authenticated
  using (
    exists (
      select 1 from public.resources r
       where r.id = rsvp_actions.resource_id
         and public.is_group_member(r.group_id, auth.uid())
    )
  );

-- Each member writes their own RSVPs.
create policy "rsvp_actions_write_self" on public.rsvp_actions
  for insert to authenticated
  with check (
    exists (
      select 1 from public.group_members gm
       where gm.id = rsvp_actions.member_id
         and gm.user_id = auth.uid()
    )
  );

-- =========================================================
-- 7. Helper RPC: list capability blocks (catalog accessor)
-- =========================================================
-- For Phase 1 the catalog lives in iOS code (RuulCore/Capabilities/Catalog).
-- This RPC returns the modules' provided blocks so iOS can validate. A
-- future capability_blocks table would replace this by providing real rows.

create or replace function public.list_module_capability_blocks()
returns table (module_id text, capability_block_id text)
language sql security definer set search_path = public stable as $$
  select m.id, unnest(m.provided_capability_blocks)
    from public.modules m
   order by m.id;
$$;

revoke execute on function public.list_module_capability_blocks() from public, anon;
grant  execute on function public.list_module_capability_blocks() to authenticated;

comment on function public.list_module_capability_blocks() is
  'Flattens modules.provided_capability_blocks for iOS CapabilityResolver lookup. Phase 1 catalog accessor; replaced by a real public.capability_blocks table if the registry needs DB rows.';
