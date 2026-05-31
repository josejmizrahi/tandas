-- 00063 — Groups roles jsonb + has_permission helper.
--
-- Closes Gap 3 (foundation slice) from the post-Gap-2 audit. Plan
-- in Plans/Active/RolesV2.md. The full RolesV2 sprint includes
-- founder-managed UI (`GroupRolesSheet`) + assign_role RPC + RLS
-- rewire to consult permissions instead of hardcoded role names —
-- those are deferred to Phase 5. This migration ships the schema +
-- RPC seam so Phase 2 templates (`shared_resource` with
-- `seat_owner` / `co-owner`) can declare custom roles in
-- `templates.config.defaultRoles` and iOS can decode them, even
-- before the RLS rewire lands.
--
-- Shape of `groups.roles`:
-- ```jsonc
-- {
--   "founder":   { "system": true,  "permissions": ["modifyGovernance", "modifyRules", "assignRoles", ...] },
--   "member":    { "system": true,  "permissions": [] },
--   "treasurer": { "system": false, "label": "Tesorero", "permissions": ["fundWithdraw", "fundAudit"], "max_holders": 1 }
-- }
-- ```
--
-- Validation trigger is permissive: a role string in
-- `group_members.role` that doesn't appear in `groups.roles` keys
-- raises a notice but is allowed. Strict enforcement lands in the
-- Phase 5 sprint when assign_role RPC is the only writer; until
-- then existing legacy values ("admin"/"member") need to keep
-- working without backfill flips.

-- =========================================================
-- 1. Add groups.roles jsonb
-- =========================================================
alter table public.groups
  add column if not exists roles jsonb not null default
    jsonb_build_object(
      'founder', jsonb_build_object(
        'system', true,
        'permissions', jsonb_build_array(
          'modifyGovernance',
          'modifyRules',
          'modifyMembers',
          'assignRoles',
          'removeMember',
          'voidFine',
          'closeAppeal',
          'createVotes'
        )
      ),
      'member', jsonb_build_object(
        'system', true,
        'permissions', jsonb_build_array(
          'createVotes',
          'castVote'
        )
      )
    );

comment on column public.groups.roles is
  'jsonb map of role id → { system, label?, permissions[], max_holders? }. Founder + member always present (system: true). Phase 2+ templates declare extra roles via templates.config.defaultRoles. Source of truth for role-based permission resolution; consulted by has_permission().';

-- Backfill any pre-existing rows that came in before the default
-- could apply. Should be a no-op on a default-applied column but
-- safe to be explicit.
update public.groups
   set roles = jsonb_build_object(
     'founder', jsonb_build_object(
       'system', true,
       'permissions', jsonb_build_array(
         'modifyGovernance', 'modifyRules', 'modifyMembers',
         'assignRoles', 'removeMember', 'voidFine',
         'closeAppeal', 'createVotes'
       )
     ),
     'member', jsonb_build_object(
       'system', true,
       'permissions', jsonb_build_array('createVotes', 'castVote')
     )
   )
 where roles is null
    or not (roles ? 'founder')
    or not (roles ? 'member');

-- =========================================================
-- 2. Validation trigger on group_members.role (permissive)
-- =========================================================
-- Logs an INFO when the role isn't in `groups.roles` keys but
-- doesn't block. Phase 5 flips this to an exception after legacy
-- "admin"/"member" callsites are migrated.
create or replace function public.validate_group_member_role()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_roles jsonb;
begin
  if new.role is null or length(trim(new.role)) = 0 then
    return new;
  end if;

  select roles into v_roles from public.groups where id = new.group_id;

  -- Legacy V1 alias: "admin" maps onto the founder permission set
  -- until the role-name rewire ships in Phase 5. Allow without
  -- warning.
  if new.role in ('admin', 'founder', 'member') then
    return new;
  end if;

  if v_roles is null or not (v_roles ? new.role) then
    raise notice 'group_member.role % is not declared in groups.roles for group %; permissive accept until RolesV2 strict mode lands', new.role, new.group_id;
  end if;

  return new;
end;
$$;

comment on function public.validate_group_member_role() is
  'Validates group_members.role against groups.roles keys. Permissive in this slice (raises notice for unknown roles); Phase 5 flips to strict exception after assign_role RPC is the only writer.';

drop trigger if exists group_members_role_validation on public.group_members;
create trigger group_members_role_validation
  before insert or update of role on public.group_members
  for each row
  execute function public.validate_group_member_role();

-- =========================================================
-- 3. has_permission helper RPC
-- =========================================================
-- Returns true iff the user is an active member of the group AND
-- the role declared on their `group_members.role` row has
-- `p_permission` in `groups.roles[role].permissions`. Works for
-- both system roles (founder / member) and custom roles declared
-- by templates or assigned later via Phase 5's assign_role RPC.
create or replace function public.has_permission(
  p_group_id   uuid,
  p_user_id    uuid,
  p_permission text
) returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role        text;
  v_perms       jsonb;
  v_legacy_role text;
begin
  if p_group_id is null or p_user_id is null or p_permission is null then
    return false;
  end if;

  select role into v_role
    from public.group_members
   where group_id = p_group_id
     and user_id  = p_user_id
     and active
   limit 1;

  if v_role is null then
    return false;
  end if;

  -- Legacy V1: "admin" was the founder alias. Treat as founder for
  -- permission lookup so existing groups keep working.
  v_legacy_role := case v_role when 'admin' then 'founder' else v_role end;

  select roles -> v_legacy_role -> 'permissions'
    into v_perms
    from public.groups
   where id = p_group_id;

  if v_perms is null or jsonb_typeof(v_perms) <> 'array' then
    return false;
  end if;

  return v_perms ? p_permission;
end;
$$;

revoke execute on function public.has_permission(uuid, uuid, text) from public, anon;
grant  execute on function public.has_permission(uuid, uuid, text) to authenticated;

comment on function public.has_permission(uuid, uuid, text) is
  'Returns true if the user has p_permission on p_group_id via their role-based permissions in groups.roles. Phase 1 of RolesV2; consulted by GovernanceService.hasPermission. Legacy "admin" role aliased to "founder".';
