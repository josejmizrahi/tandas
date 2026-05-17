-- Rollback for 00237_module_rpc_gated_on_has_permission.sql
--
-- Restores set_group_module body from mig 00074 (is_group_admin
-- gate). Catalog backfill of manageModules in groups.roles +
-- templates.config is left in place — additive and harmless if
-- rolled back.

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
