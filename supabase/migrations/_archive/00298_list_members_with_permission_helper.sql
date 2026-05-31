-- 00298 — Helper RPC `list_members_with_permission` for permission-based
-- recipient resolution in edge functions.
--
-- Plans/Active/RolesRemediation_2026-05-17.md Sprint D follow-up
-- (closes V6 — "process-system-events hardcodes 'founder' as the V1
-- approver pool"). Lets the rule engine consequence sink and any
-- future edge function resolve "all active members who can perform
-- action X in group Y" without reading role strings directly.
--
-- Implementation: walks group_members.roles[] cross-referenced against
-- groups.roles catalog, returning members whose any role grants the
-- requested permission. Mirrors has_permission semantics. Read-only.
--
-- Returns (user_id, member_id) so callers can use either key.
-- Service-role only — internal sink helper, not user-facing.

create or replace function public.list_members_with_permission(
  p_group_id  uuid,
  p_permission text
) returns table (user_id uuid, member_id uuid)
language sql
stable
security definer
set search_path = public
as $$
  select gm.user_id, gm.id as member_id
    from public.group_members gm
    join public.groups g on g.id = gm.group_id
   where gm.group_id = p_group_id
     and gm.active = true
     and exists (
       select 1
         from jsonb_array_elements_text(coalesce(gm.roles, '[]'::jsonb)) as t(role_id)
        where exists (
          select 1
            from jsonb_array_elements_text(
              coalesce(g.roles -> t.role_id -> 'permissions', '[]'::jsonb)
            ) as p(perm)
           where p.perm = p_permission
        )
     )
   order by gm.joined_at asc;
$$;

revoke execute on function public.list_members_with_permission(uuid, text) from public, anon, authenticated;
grant  execute on function public.list_members_with_permission(uuid, text) to service_role;

comment on function public.list_members_with_permission(uuid, text) is
  'Returns (user_id, member_id) for every active member of p_group_id whose roles[] aggregates a role granting p_permission per groups.roles catalog. Mirrors has_permission UNION semantics. Service-role only — internal recipient resolution helper for edge fns + rule engine consequences. Stable + ordered by joined_at asc.';
