-- 00074 — set_group_module cascades rule lifecycle on toggle.
--
-- Phase A step 4 of L1 rules-architecture refactor (audit doc:
-- Plans/Active/L1_Audit_2026-05-10.md, Hallazgo 1).
--
-- Today (post-00068), set_group_module togglea `groups.active_modules`
-- correctly with dep + conflict cascades. But it does NOT touch the
-- `rules` table. Consequences:
--
--   1. Enabling `slot_assignment` post-onboarding leaves the group
--      without that module's rules. The engine never fires them.
--   2. Disabling `basic_fines` leaves its 5 dinner_* rules zombi.
--      Engine keeps firing them on checkInRecorded / eventClosed.
--
-- This migration extends the function so every slug that flips from
-- absent → present triggers `seed_module_rules`, and every slug that
-- flips from present → absent triggers `archive_module_rules` (which
-- sets is_active = false but preserves the rows for audit).
--
-- Implementation: two jsonb arrays (`v_to_seed`, `v_to_archive`)
-- accumulate transitions during the existing cascade. At the end of
-- the function we iterate them and call the per-module RPCs.
--
-- Idempotency: seed_module_rules upserts (00073) so re-enabling an
-- already-active module is harmless. archive_module_rules only updates
-- rows where is_active = true so re-disabling is also harmless.
--
-- The function still preserves the unknown-slug forward-compat from
-- 00061 (slug not in modules table → no cascade), and the conflict
-- bidirectional semantics from 00068.

create or replace function public.set_group_module(
  p_group_id    uuid,
  p_module_slug text,
  p_enabled     boolean
) returns public.groups
language plpgsql security definer set search_path = public as $$
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

  v_before := v_modules;

  if p_enabled then
    -- 1. Disable conflicts (direct + bidirectional) AND their
    --    transitive dependents.
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

    -- 2. Add slug + transitive deps.
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
    -- DISABLE: drop slug + transitive dependents.
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

  -- =========================================================
  -- Compute per-module rule transitions.
  -- =========================================================
  -- v_to_seed:    in v_modules but NOT in v_before → newly enabled
  -- v_to_archive: in v_before  but NOT in v_modules → newly disabled
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

  -- =========================================================
  -- Persist groups.active_modules first (so RLS / triggers see new state).
  -- =========================================================
  update public.groups
     set active_modules = v_modules,
         updated_at = now()
   where id = p_group_id
   returning * into g;

  -- =========================================================
  -- Apply rule cascades.
  -- =========================================================
  -- Each call respects the admin guard (already passed for the caller).
  -- seed_module_rules is idempotent (upserts); archive_module_rules
  -- only touches is_active=true rows, so both are safe even if called
  -- on a slug whose rules were already in the desired state.
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
  'Toggles module membership in groups.active_modules with full cascades. ENABLE: cascades transitive deps in + direct/bidirectional conflicts (and their dependents) out. DISABLE: cascades transitive dependents out. Per-module rule lifecycle: every newly-enabled slug fires seed_module_rules; every newly-disabled slug fires archive_module_rules. Mig 00074 = Phase A step 4 of L1 rules refactor.';
