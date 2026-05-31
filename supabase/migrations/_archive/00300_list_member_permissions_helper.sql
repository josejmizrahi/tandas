-- 00300 — Helper RPC `list_member_permissions(member_id)` returns the
-- UNION of permissions across all roles the member holds.
--
-- Plans/Active/RolesRemediation_2026-05-17.md V7 prerequisite. Powers
-- the rule engine sink's loadMemberPermissions and the new
-- `actorHasPermission` condition. Mirrors `list_members_with_permission`
-- (mig 00298) in the inverse direction — given a member, what permissions
-- do they hold?
--
-- Returns text[] of distinct permission identifiers. Empty array when
-- the member doesn't exist or has no roles. Service-role only —
-- internal helper for edge functions + rule engine consequences.

create or replace function public.list_member_permissions(
  p_member_id uuid
) returns text[]
language sql
stable
security definer
set search_path = public
as $$
  with member_roles as (
    select jsonb_array_elements_text(coalesce(gm.roles, '[]'::jsonb)) as role_id,
           gm.group_id
      from public.group_members gm
     where gm.id = p_member_id
       and gm.active = true
  ),
  permissions as (
    select distinct p.perm
      from member_roles mr
      join public.groups g on g.id = mr.group_id
      cross join lateral jsonb_array_elements_text(
        coalesce(g.roles -> mr.role_id -> 'permissions', '[]'::jsonb)
      ) as p(perm)
  )
  select coalesce(array_agg(perm order by perm), '{}'::text[]) from permissions;
$$;

revoke execute on function public.list_member_permissions(uuid) from public, anon, authenticated;
grant  execute on function public.list_member_permissions(uuid) to service_role;

comment on function public.list_member_permissions(uuid) is
  'Returns the UNION of permission strings across all roles held by p_member_id. Mirrors has_permission UNION semantics. Service-role only — internal helper for rule engine actorHasPermission condition + actor_permissions projection.';
