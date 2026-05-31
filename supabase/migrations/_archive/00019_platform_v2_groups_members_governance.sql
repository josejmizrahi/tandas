-- 00019 — Platform V2: groups.governance, members.roles, settings consolidation
--
-- Phase1 Bloque 1 (Plans/Phase1.md). Adds the platform fields the prompt
-- requires on `groups` (governance, base_template, active_modules, settings)
-- and on `members` (roles[]). Backfills from existing flat columns.
--
-- LEGACY COLUMNS NOT DROPPED. They remain readable for 2-week paridad
-- before a posterior migration removes them. App code reads from new
-- fields; legacy stays as fallback during transition.
--
-- Idempotent (uses `if not exists` + `coalesce`). Safe to re-run.

-- =============================================================================
-- 1. Groups: add governance / base_template / active_modules / settings
-- =============================================================================

alter table public.groups
  add column if not exists governance     jsonb not null default '{}'::jsonb,
  add column if not exists base_template  text  not null default 'recurring_dinner',
  add column if not exists active_modules jsonb not null default '[]'::jsonb,
  add column if not exists settings       jsonb not null default '{}'::jsonb;

comment on column public.groups.governance is
  'GovernanceRules — who can do what. Replaces hardcoded "founder edits" logic. Defaults set by template at group creation.';
comment on column public.groups.base_template is
  'Template id (e.g. recurring_dinner). Defines tabs, vocabulary, default modules.';
comment on column public.groups.active_modules is
  'Array of module ids active for this group (e.g. ["basic_fines","rotating_host"]). Composes resources/rules/views.';
comment on column public.groups.settings is
  'Template-specific settings consolidated as jsonb. Replaces flat columns (event_label, frequency_*, rotation_mode, etc.) over time.';

-- =============================================================================
-- 2. Backfill base_template + active_modules from group_type
-- =============================================================================

-- Map existing group_type → base_template. Today only 'recurring_dinner' is
-- in production but the migration is template-aware for future types.
update public.groups
set base_template = coalesce(group_type, 'recurring_dinner')
where base_template is null
   or base_template = ''
   or base_template = 'recurring_dinner';  -- harmless re-write to current default

-- Default 5 modules for recurring_dinner template per Plans/Phase1.md.
-- Other templates will have their own sets when they ship.
update public.groups
set active_modules = '["basic_fines","rotating_host","rsvp","check_in","appeal_voting"]'::jsonb
where (active_modules is null or active_modules = '[]'::jsonb)
  and base_template = 'recurring_dinner';

-- =============================================================================
-- 3. Backfill governance — preserves existing voting_threshold / voting_quorum
--    / vote_duration_hours columns; defaults for the rest.
-- =============================================================================
--
-- Existing legacy columns (voting_threshold, voting_quorum stored as 0..1
-- decimals; vote_duration_hours stored as int) are read in. Multiplied by 100
-- to convert to percent. Defaults (50, 50, 72) only apply when legacy is null.

update public.groups
set governance = jsonb_build_object(
  'whoCanModifyRules',       'founder',
  'whoCanInviteMembers',     'founder',
  'whoCanRemoveMembers',     'majorityVote',
  'whoCanCloseEvents',       'host',
  'whoCanCreateVotes',       'anyMember',
  'whoCanModifyGovernance',  'founder',
  'votingQuorumPercent',     coalesce(round(voting_quorum    * 100)::int, 50),
  'votingThresholdPercent',  coalesce(round(voting_threshold * 100)::int, 50),
  'votingDurationHours',     coalesce(vote_duration_hours, 72),
  'votesAreAnonymous',       true
)
where governance is null
   or governance = '{}'::jsonb;

-- =============================================================================
-- 4. Backfill settings from existing flat columns
-- =============================================================================
--
-- Pulls all template-specific configuration into a single jsonb. App code
-- reads from `settings` going forward; flat columns stay 2 weeks for
-- paridad. The keys mirror the Swift `GroupSettings` struct.

update public.groups
set settings = jsonb_strip_nulls(jsonb_build_object(
  -- Vocabulary + scheduling
  'eventVocabulary',         coalesce(event_label, 'cena'),
  'currency',                coalesce(currency, 'MXN'),
  'timezone',                coalesce(timezone, 'America/Mexico_City'),
  'defaultDayOfWeek',        default_day_of_week,
  'defaultStartTime',        default_start_time::text,
  'defaultLocation',         default_location,
  'frequencyType',           frequency_type,
  'frequencyConfig',         case
                                when frequency_config is not null and frequency_config <> '{}'::jsonb
                                then frequency_config
                                else null
                              end,
  -- Rotation
  'rotationEnabled',         coalesce(rotation_enabled, true),
  'rotationMode',            coalesce(rotation_mode, 'manual'),
  -- Fines
  'finesEnabled',            coalesce(fines_enabled, true),
  'gracePeriodEvents',       coalesce(grace_period_events, 3),
  'monthlyFineCapMxn',       monthly_fine_cap_mxn,
  'noShowGraceMinutes',      coalesce(no_show_grace_minutes, 60),
  'autoGenerateEvents',      coalesce(auto_generate_events, false),
  'blockUnpaidAttendance',   coalesce(block_unpaid_attendance, false),
  -- Voting
  'committeeRequiredForAppeals', coalesce(committee_required_for_appeals, false),
  -- Fund
  'fundEnabled',             coalesce(fund_enabled, true),
  'fundBalance',             coalesce(fund_balance, 0),
  'fundTarget',              fund_target,
  'fundTargetLabel',         fund_target_label,
  'fundMinParticipants',     fund_min_participants,
  'fundAdmin',               fund_admin
))
where settings is null
   or settings = '{}'::jsonb;

-- =============================================================================
-- 5. Members: add roles[] + backfill from role text
-- =============================================================================

alter table public.group_members
  add column if not exists roles jsonb not null default '["member"]'::jsonb;

comment on column public.group_members.roles is
  'Array of role strings. Replaces single role text. V1 values: founder, member, host (contextual). V2: treasurer, arbiter, observer.';

-- Backfill: every admin gets ["founder","member"], every regular user gets ["member"].
-- This preserves existing access while populating the new field.
update public.group_members
set roles = case
              when role = 'admin' then '["founder","member"]'::jsonb
              else '["member"]'::jsonb
            end
where roles is null
   or roles = '[]'::jsonb
   or roles = '["member"]'::jsonb;  -- safe re-write for default case

-- =============================================================================
-- 6. Indexes
-- =============================================================================

create index if not exists groups_base_template_idx on public.groups(base_template);
create index if not exists groups_active_modules_gin on public.groups using gin (active_modules);
create index if not exists groups_settings_gin on public.groups using gin (settings);
create index if not exists group_members_roles_gin on public.group_members using gin (roles);

-- =============================================================================
-- 7. Helper function: read setting with default fallback
-- =============================================================================
--
-- Convenience for app + edge functions that need a single setting value.
-- Reads `settings -> key`, falls back to flat column if jsonb missing.

create or replace function public.group_setting(p_group_id uuid, p_key text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(settings -> p_key, 'null'::jsonb)
  from public.groups
  where id = p_group_id;
$$;

comment on function public.group_setting is
  'Helper: reads groups.settings ->> key with jsonb null fallback. Use from app/edge fns.';

-- =============================================================================
-- 8. Permission helper: governance check
-- =============================================================================
--
-- Reads governance.{key} for the group, returns the PermissionLevel string.
-- App-level GovernanceService does the actual evaluation; this is a SQL helper
-- for RLS policies that need governance-aware checks.

create or replace function public.group_governance_level(p_group_id uuid, p_action text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(governance ->> p_action, 'founder')
  from public.groups
  where id = p_group_id;
$$;

comment on function public.group_governance_level is
  'Reads governance permission level for an action. e.g. group_governance_level(uuid, ''whoCanModifyRules'') → ''founder''.';
