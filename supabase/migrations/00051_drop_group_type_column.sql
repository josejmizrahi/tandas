-- 00051 — Drop legacy `groups.group_type` column + RPC param.
-- (Originally 00045; renamed in repo. Prod migration name remains
-- "00045_drop_group_type_column" — applied 2026-05-08 22:25 UTC.)
--
-- Audit § 5.3 item 7c residual + Plans/Active/GroupTypeRemoval.md DoD.
--
-- Prerequisites met (verified pre-migration 2026-05-08):
--   1. Swift `GroupType` enum removed (commit aa99ac7, SPM split sprint 2.1a).
--   2. `Group.groupType` Swift property removed (same commit).
--   3. Migration 00042 made `groups.group_type` NULLABLE + DEPRECATED, and
--      taught `create_group_with_admin` to resolve template from
--      `templates.config` rather than from `group_type`.
--   4. iOS `GroupsRepository` callers pass `p_group_type: nil` exclusively.
--   5. e2e fixture `seedGroup.ts` migrated to `p_base_template`.
--
-- This migration drops the column + the RPC parameter. New iOS clients pass
-- only `p_base_template` (cohabitation window closed).
--
-- Drop order:
--   a. Constraint `groups_group_type_check` (added in 00009).
--   b. Column `groups.group_type`.
--   c. Function `create_group_with_admin` (the 7-param 00042 version).
--   d. Recreate without `p_group_type`.
--
-- Rollback: 00045_rollback.sql restores 00042 surface area.

-- =========================================================
-- a. Drop the check constraint that gates legal group_type values
-- =========================================================
alter table public.groups
  drop constraint if exists groups_group_type_check;

-- =========================================================
-- b. Drop the column
-- =========================================================
alter table public.groups
  drop column if exists group_type;

-- =========================================================
-- c. Drop the 7-param create_group_with_admin
-- =========================================================
drop function if exists public.create_group_with_admin(text, text, text, text, text, text, text);

-- =========================================================
-- d. Recreate without p_group_type
-- =========================================================
create or replace function public.create_group_with_admin(
  p_name text,
  p_event_label text default null,
  p_currency text default 'MXN',
  p_timezone text default 'America/Mexico_City',
  p_base_template text default 'recurring_dinner',
  p_cover_image_name text default null
) returns public.groups
language plpgsql security definer set search_path = public as $$
declare
  g public.groups;
  uid uuid := auth.uid();
  resolved_template text := coalesce(nullif(p_base_template, ''), 'recurring_dinner');
  template_config jsonb;
  resolved_event_label text;
  resolved_active_modules jsonb;
  resolved_governance jsonb;
  resolved_settings jsonb;
  resolved_category text;
  resolved_initials text;
begin
  if uid is null then raise exception 'not authenticated'; end if;

  select t.config
  into template_config
  from public.templates t
  where t.id = resolved_template
  limit 1;

  resolved_event_label := coalesce(
    nullif(p_event_label, ''),
    template_config #>> '{presentation,defaultEventLabel}',
    template_config #>> '{defaultSettings,eventVocabulary}',
    'evento'
  );

  resolved_active_modules := coalesce(
    template_config -> 'defaultModules',
    case
      when resolved_template = 'recurring_dinner' then
        '["basic_fines","rotating_host","rsvp","check_in","appeal_voting"]'::jsonb
      else
        '[]'::jsonb
    end
  );

  resolved_governance := coalesce(template_config -> 'defaultGovernance', '{}'::jsonb);
  resolved_settings := coalesce(template_config -> 'defaultSettings', '{}'::jsonb)
    || jsonb_build_object('eventVocabulary', resolved_event_label);
  resolved_category := coalesce(template_config ->> 'defaultCategory', 'socialRecurring');

  resolved_initials := upper(
    case
      when array_length(string_to_array(trim(p_name), ' '), 1) >= 2 then
        substring(trim(split_part(p_name, ' ', 1)) from 1 for 1) ||
        substring(trim(split_part(p_name, ' ', 2)) from 1 for 1)
      else
        substring(trim(p_name) from 1 for 2)
    end
  );

  insert into public.groups (
    name,
    event_label,
    currency,
    timezone,
    base_template,
    active_modules,
    governance,
    settings,
    category,
    initials,
    cover_image_name,
    created_by
  ) values (
    p_name,
    resolved_event_label,
    coalesce(p_currency, 'MXN'),
    coalesce(p_timezone, 'America/Mexico_City'),
    resolved_template,
    resolved_active_modules,
    resolved_governance,
    resolved_settings,
    resolved_category,
    resolved_initials,
    p_cover_image_name,
    uid
  ) returning * into g;

  insert into public.group_members (group_id, user_id, role, active)
    values (g.id, uid, 'admin', true);

  return g;
end;
$$;

revoke execute on function public.create_group_with_admin(text, text, text, text, text, text) from public, anon;
grant  execute on function public.create_group_with_admin(text, text, text, text, text, text) to authenticated;

comment on function public.create_group_with_admin(text, text, text, text, text, text) is
  'Creates a group with the caller as admin. Resolves modules/governance/settings/category/initials from templates.config.';
