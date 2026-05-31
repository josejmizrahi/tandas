-- 00237 — Member RPCs gated on has_permission (Permission catalog v2).
--
-- Last "easy" slice of item #1 ("two auth models coexisting"). Cleans
-- up the remaining sensitive RPCs that still gate on is_group_admin
-- but have a clear matching V1 permission.
--
-- In scope (2 RPCs)
-- =================
--   - seed_template_roles (mig 00067): admin only
--                                      → has_permission('modifyGovernance')
--   - set_turn_order      (mig 00003): admin only
--                                      → has_permission('modifyMembers')
--
-- Why these perms
-- ===============
-- seed_template_roles rewrites groups.roles entirely from a template's
-- defaultRoles. That's a governance-structure change, fits
-- modifyGovernance squarely (which is also the gate enforced on direct
-- writes to the column by mig 00124).
--
-- set_turn_order reorders members for rotating positions. Member-level
-- mutation, fits modifyMembers.
--
-- Out of scope
-- ============
--   - assign_role / unassign_role / upsert_group_role /
--     delete_group_role (mig 00229/00230): already consult
--     has_permission AND is_group_admin in a transitional pattern.
--     Cleaning up the legacy fallback there deserves its own slice.
--   - resolve_governance() rewire (item 1.G): biggest open piece —
--     making has_permission the primary check in the governance
--     resolver instead of the fallback. Affects create_initial_rule
--     and 5+ resolver-gated RPCs.
--
-- Both permissions ship in the V1 catalog default (mig 00063): every
-- founder has modifyGovernance + modifyMembers. Zero observable
-- change for existing groups.
--
-- Idempotent: CREATE OR REPLACE swaps function bodies atomically.
--
-- Rollback: _rollbacks/00237_rollback.sql restores prior bodies.

-- =========================================================
-- 1. seed_template_roles — has_permission('modifyGovernance')
-- =========================================================
create or replace function public.seed_template_roles(
  p_template_id text,
  p_group_id    uuid
)
returns public.groups
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_default_roles jsonb;
  v_current_roles jsonb;
  v_has_custom_role boolean;
  g public.groups;
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;
  -- mig 00237: swap is_group_admin → has_permission('modifyGovernance').
  -- Seeding rewrites groups.roles wholesale, which mig 00124's
  -- guard_groups_governance_update also gates on modifyGovernance.
  -- Single source of truth.
  if not public.has_permission(p_group_id, uid, 'modifyGovernance') then
    raise exception 'modifyGovernance permission required' using errcode = '42501';
  end if;

  select config -> 'defaultRoles'
    into v_default_roles
    from public.templates
   where id = p_template_id;

  if v_default_roles is null or jsonb_typeof(v_default_roles) <> 'object' then
    select * into g from public.groups where id = p_group_id;
    return g;
  end if;

  select roles into v_current_roles from public.groups where id = p_group_id;
  select exists (
    select 1
    from jsonb_each(coalesce(v_current_roles, '{}'::jsonb)) r(key, value)
    where key not in ('founder', 'member')
  ) into v_has_custom_role;

  if v_has_custom_role then
    select * into g from public.groups where id = p_group_id;
    return g;
  end if;

  update public.groups
     set roles = v_default_roles
   where id = p_group_id
   returning * into g;

  return g;
end;
$$;

comment on function public.seed_template_roles(text, uuid) is
  'v2 (mig 00237): auth gate is has_permission(modifyGovernance) instead of is_group_admin. Matches mig 00124 guard on direct groups.roles writes.';

-- =========================================================
-- 2. set_turn_order — has_permission('modifyMembers')
-- =========================================================
create or replace function public.set_turn_order(p_group_id uuid, p_user_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare i int;
begin
  if not public.has_permission(p_group_id, auth.uid(), 'modifyMembers') then
    raise exception 'modifyMembers permission required' using errcode = '42501';
  end if;
  update public.group_members set turn_order = null
    where group_id = p_group_id and active;
  for i in 1..array_length(p_user_ids, 1) loop
    update public.group_members set turn_order = i
      where group_id = p_group_id and user_id = p_user_ids[i] and active;
  end loop;
end;
$$;

comment on function public.set_turn_order(uuid, uuid[]) is
  'v2 (mig 00237): auth gate is has_permission(modifyMembers) instead of is_group_admin.';
