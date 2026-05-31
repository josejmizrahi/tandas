-- 00236 — set_group_module gated on has_permission (Permission catalog v2).
--
-- Sibling of 00232 (fines), 00233 (votes), 00234 (rules), 00235
-- (events). Item #1 ("two auth models coexisting"), modules slice.
--
-- Catalog gap (fixed in Permission.swift sibling commit):
--   - manageModules (V1, .governance category): authority to toggle
--     group modules on/off (basic_fines, appeal_voting,
--     slot_assignment, etc.). Cascades to dependencies and emits the
--     capabilityToggled atom.
--
-- In scope (1 RPC)
-- ================
--   - set_group_module (mig 00068 + 00074): is_group_admin only
--                                           → has_permission('manageModules')
--
-- Idempotent: CREATE OR REPLACE swaps function body atomically.
-- Backfill is set-union, safe to re-run.
--
-- Rollback: _rollbacks/00236_rollback.sql restores prior body.

-- =========================================================
-- 1. Extend column default on public.groups.roles
-- =========================================================
alter table public.groups
  alter column roles set default
    jsonb_build_object(
      'founder', jsonb_build_object(
        'system', true,
        'permissions', jsonb_build_array(
          'modifyGovernance',
          'modifyRules',
          'modifyMembers',
          'assignRoles',
          'removeMember',
          'issueFine',
          'voidFine',
          'markFinePaid',
          'closeAppeal',
          'createVotes',
          'manageEvents',
          'manageModules'
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

-- =========================================================
-- 2. Backfill existing groups
-- =========================================================
update public.groups
   set roles = jsonb_set(
     roles,
     '{founder,permissions}',
     (
       select coalesce(jsonb_agg(distinct p), '[]'::jsonb)
       from (
         select jsonb_array_elements_text(
           coalesce(roles -> 'founder' -> 'permissions', '[]'::jsonb)
         ) as p
         union
         select unnest(array['manageModules']) as p
       ) merged
     )
   )
 where roles ? 'founder';

-- =========================================================
-- 3. Backfill templates.config.defaultRoles.founder.permissions
-- =========================================================
update public.templates
   set config = jsonb_set(
     config,
     '{defaultRoles,founder,permissions}',
     (
       select coalesce(jsonb_agg(distinct p), '[]'::jsonb)
       from (
         select jsonb_array_elements_text(
           coalesce(config -> 'defaultRoles' -> 'founder' -> 'permissions', '[]'::jsonb)
         ) as p
         union
         select unnest(array['manageModules']) as p
       ) merged
     )
   )
 where config -> 'defaultRoles' -> 'founder' is not null;

-- =========================================================
-- 4. set_group_module — has_permission('manageModules')
-- =========================================================
create or replace function public.set_group_module(
  p_group_id    uuid,
  p_module_slug text,
  p_enabled     boolean
)
returns public.groups
language plpgsql
security definer
set search_path = public
as $$
declare
  g            public.groups;
  v_modules    jsonb;
  v_before     jsonb;
  v_to_apply   text;
  v_conflict   text;
  v_to_seed    jsonb := '[]'::jsonb;
  v_to_archive jsonb := '[]'::jsonb;
  v_slug       text;
begin
  if p_module_slug is null or length(trim(p_module_slug)) = 0 then
    raise exception 'set_group_module: p_module_slug is required';
  end if;

  if p_enabled is null then
    raise exception 'set_group_module: p_enabled is required';
  end if;

  -- mig 00236: swap is_group_admin → has_permission('manageModules').
  if not public.has_permission(p_group_id, auth.uid(), 'manageModules') then
    raise exception 'manageModules permission required' using errcode = '42501';
  end if;

  select active_modules into v_modules
    from public.groups
   where id = p_group_id
   for update;

  if not found then
    raise exception 'group not found: %', p_group_id;
  end if;

  v_before := v_modules;

  if p_enabled then
    for v_conflict in
      with direct_conflicts as (
        select unnest(m.conflicts_with) as id
          from public.modules m
         where m.id = p_module_slug
        union
        select m.id
          from public.modules m
         where p_module_slug = any(m.conflicts_with)
      ),
      conflict_with_dependents as (
        select id from direct_conflicts
        union
        select m.id
          from public.modules m
         join direct_conflicts dc on m.dependencies && array[dc.id]
        union
        select m2.id
          from public.modules m2
         join public.modules m1 on m2.dependencies && array[m1.id]
         join direct_conflicts dc on m1.dependencies && array[dc.id]
      )
      select id from conflict_with_dependents
       where id <> p_module_slug
    loop
      if v_modules ? v_conflict then
        v_modules := v_modules - v_conflict;
        raise notice 'set_group_module: cascade-disabled % (conflicts with %)', v_conflict, p_module_slug;
      end if;
    end loop;

    if not (v_modules ? p_module_slug) then
      v_modules := v_modules || jsonb_build_array(p_module_slug);
    end if;

    for v_to_apply in
      with recursive deps_closure as (
        select unnest(m.dependencies) as id
          from public.modules m
         where m.id = p_module_slug
        union
        select unnest(m2.dependencies)
          from public.modules m2
          join deps_closure dc on dc.id = m2.id
      )
      select id from deps_closure
    loop
      if not (v_modules ? v_to_apply) then
        v_modules := v_modules || jsonb_build_array(v_to_apply);
      end if;
    end loop;
  else
    v_modules := v_modules - p_module_slug;

    for v_to_apply in
      with recursive dependents_closure as (
        select m.id
          from public.modules m
         where p_module_slug = any(m.dependencies)
        union
        select m2.id
          from public.modules m2
          join dependents_closure dc on dc.id = any(m2.dependencies)
      )
      select id from dependents_closure
    loop
      v_modules := v_modules - v_to_apply;
    end loop;
  end if;

  for v_slug in
    select jsonb_array_elements_text(v_modules)
    except
    select jsonb_array_elements_text(v_before)
  loop
    v_to_seed := v_to_seed || jsonb_build_array(v_slug);
  end loop;

  for v_slug in
    select jsonb_array_elements_text(v_before)
    except
    select jsonb_array_elements_text(v_modules)
  loop
    v_to_archive := v_to_archive || jsonb_build_array(v_slug);
  end loop;

  update public.groups
     set active_modules = v_modules,
         updated_at = now()
   where id = p_group_id
   returning * into g;

  for v_slug in select jsonb_array_elements_text(v_to_seed) loop
    perform public.seed_module_rules(p_group_id, v_slug);
  end loop;

  for v_slug in select jsonb_array_elements_text(v_to_archive) loop
    perform public.archive_module_rules(p_group_id, v_slug);
  end loop;

  return g;
end;
$$;

comment on function public.set_group_module(uuid, text, boolean) is
  'v3 (mig 00236): auth gate is has_permission(manageModules) instead of is_group_admin. Body otherwise identical to mig 00074. Enables custom roles to control module activation without admin promotion.';
