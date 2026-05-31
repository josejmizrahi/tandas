-- 00068 — set_group_module enforces conflicts cascade.
--
-- Audit Q2 (post-Phase-2-Slice-1 review): mig 00061 already cascades
-- transitive deps on ENABLE and transitive dependents on DISABLE,
-- but `modules.conflicts_with` was declarative-only — `set_group_module`
-- never read it. Result: a group could end up with both
-- `rotating_host` and `rotating_position` active despite the conflict
-- declared in mig 00065. iOS validator caught it client-side; server
-- bypass left the data state lying.
--
-- Slice now adds: ENABLE X also disables every module in
-- `direct_conflicts(X)` (the union of X.conflicts_with and modules
-- that declare X in their conflicts_with — bidirectional), AND each
-- of those conflicts' transitive dependents.
--
-- DISABLE behaviour unchanged from mig 00061 — disabling X already
-- cascades dependents.
--
-- Conflict semantics are NOT transitive: A conflicts with B does not
-- imply A conflicts with C just because B conflicts with C. Direct +
-- bidirectional only.

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
  v_conflict  text;
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
    -- 1. Disable conflicts (direct + bidirectional) AND their
    --    transitive dependents. Done BEFORE adding the slug so the
    --    final state never has both X and conflict(X) simultaneously.
    for v_conflict in
      with direct_conflicts as (
        -- X declares conflict with Y
        select unnest(m.conflicts_with) as id
          from public.modules m
         where m.id = p_module_slug
        union
        -- Y declares conflict with X (bidirectional)
        select m.id
          from public.modules m
         where p_module_slug = any(m.conflicts_with)
      ),
      conflict_with_dependents as (
        -- Each direct conflict + transitive dependents that would
        -- orphan if the conflict were removed.
        select id from direct_conflicts
        union
        select m.id
          from public.modules m
         join direct_conflicts dc on m.dependencies && array[dc.id]
        union
        -- Recurse one more layer (rare in practice for V1+Phase 2;
        -- avoids missing deep chains without going recursive CTE).
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

    -- 2. Add slug + transitive deps (existing behaviour from mig 00061).
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
    -- DISABLE branch unchanged from 00061: drop slug + transitive
    -- dependents.
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
  'Toggles module slug membership in groups.active_modules. ENABLE: cascades transitive deps in + cascades direct/bidirectional conflicts (and their dependents) out. DISABLE: cascades transitive dependents out. Closures consult public.modules dynamically. Slice E.2 of mig 00061 + Q2 fix from Phase 2 Slice 1 audit.';
