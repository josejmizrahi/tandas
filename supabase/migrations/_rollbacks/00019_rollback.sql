-- Rollback for 00019_platform_v2_groups_members_governance.sql
-- NOT applied automatically. Loses all governance + roles backfill data.

drop function if exists public.group_governance_level(uuid, text);
drop function if exists public.group_setting(uuid, text);

drop index if exists public.group_members_roles_gin;
drop index if exists public.groups_settings_gin;
drop index if exists public.groups_active_modules_gin;
drop index if exists public.groups_base_template_idx;

alter table public.group_members
  drop column if exists roles;

alter table public.groups
  drop column if exists settings,
  drop column if exists active_modules,
  drop column if exists base_template,
  drop column if exists governance;
