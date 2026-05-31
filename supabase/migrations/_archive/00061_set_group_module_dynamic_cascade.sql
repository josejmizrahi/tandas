-- 00061 — Rewrite set_group_module to compute cascades dynamically
-- from the new public.modules catalog (seeded by 00060).
--
-- Replaces the hardcoded jsonb closures from 00057. Same signature
-- (uuid, text, boolean), same semantics (ENABLE adds slug + transitive
-- deps; DISABLE removes slug + transitive dependents), same idempotency
-- and admin guard. The difference is no more lockstep migration when
-- a module is added — the table is the source of truth.
--
-- Unknown slug behaviour preserved: if `p_module_slug` is not in
-- `public.modules`, the function still toggles the slug itself with
-- no cascade. This keeps forward-compat for any iOS-side declaration
-- that hasn't been seeded yet (boot-time sync isn't atomic with
-- deploy).
--
-- Conflicts (`modules.conflicts_with`) are NOT enforced server-side
-- here — V1 has no conflicts and the iOS validator already gates
-- enable-conflict pairs at the toggle UI. Phase 2's `slot_assignment`
-- vs `rotating_host` will need a follow-up that adds conflict
-- enforcement at this layer.

create or replace function public.set_group_module(
  p_group_id    uuid,
  p_module_slug text,
  p_enabled     boolean
) returns public.groups
language plpgsql security definer set search_path = public as $$
declare
  g           public.groups;
  v_modules   jsonb;
  v_to_apply  text;
begin
  if p_module_slug is null or length(trim(p_module_slug)) = 0 then
    raise exception 'set_group_module: p_module_slug is required';
  end if;

  if p_enabled is null then
    raise exception 'set_group_module: p_enabled is required';
  end if;

  if not public.is_group_admin(p_group_id, auth.uid()) then
    raise exception 'only admins can change group modules';
  end if;

  select active_modules into v_modules
    from public.groups
   where id = p_group_id
   for update;

  if not found then
    raise exception 'group not found: %', p_group_id;
  end if;

  if p_enabled then
    -- Add slug + every transitive dep. Skip duplicates so the array
    -- stays unique. Unknown slug → no cascade (CTE returns empty).
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
    -- Remove slug + every transitive dependent.
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

  update public.groups
     set active_modules = v_modules,
         updated_at = now()
   where id = p_group_id
   returning * into g;

  return g;
end;
$$;

comment on function public.set_group_module(uuid, text, boolean) is
  'Toggles module slug membership in groups.active_modules with transitive dep/dependent cascades computed dynamically from public.modules (00060). Admin-only. Trigger from mig 00049 derives groups.fines_enabled when slug=basic_fines. Replaces 00057 hardcoded jsonb closures.';
