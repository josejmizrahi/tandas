-- 00063 rollback — Drop has_permission, validation trigger, and
-- groups.roles column. iOS clients that read groups.roles will
-- decode null and fall back to the static MemberRole enum.

drop function if exists public.has_permission(uuid, uuid, text);

drop trigger if exists group_members_role_validation on public.group_members;
drop function if exists public.validate_group_member_role();

alter table public.groups
  drop column if exists roles;
