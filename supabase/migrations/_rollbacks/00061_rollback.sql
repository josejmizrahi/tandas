-- 00061 rollback — Restore the hardcoded-closure version of
-- set_group_module from 00057.
--
-- Note: 00060_rollback drops public.modules. If you roll back 00060
-- without first rolling back 00061, set_group_module will fail at
-- runtime because its CTE references the missing table. Run rollbacks
-- in this order: 00061 → 00060.

create or replace function public.set_group_module(
  p_group_id    uuid,
  p_module_slug text,
  p_enabled     boolean
) returns public.groups
language plpgsql security definer set search_path = public as $$
declare
  g public.groups;
  v_modules jsonb;
  v_deps_closure constant jsonb := jsonb_build_object(
    'basic_fines',   jsonb_build_array('rsvp', 'check_in'),
    'check_in',      jsonb_build_array('rsvp'),
    'appeal_voting', jsonb_build_array('basic_fines', 'check_in', 'rsvp'),
    'rotating_host', jsonb_build_array(),
    'rsvp',          jsonb_build_array()
  );
  v_dependents_closure constant jsonb := jsonb_build_object(
    'rsvp',          jsonb_build_array('check_in', 'basic_fines', 'appeal_voting'),
    'check_in',      jsonb_build_array('basic_fines', 'appeal_voting'),
    'basic_fines',   jsonb_build_array('appeal_voting'),
    'rotating_host', jsonb_build_array(),
    'appeal_voting', jsonb_build_array()
  );
  v_to_apply text;
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
    if not (v_modules ? p_module_slug) then
      v_modules := v_modules || jsonb_build_array(p_module_slug);
    end if;
    for v_to_apply in
      select jsonb_array_elements_text(coalesce(v_deps_closure -> p_module_slug, '[]'::jsonb))
    loop
      if not (v_modules ? v_to_apply) then
        v_modules := v_modules || jsonb_build_array(v_to_apply);
      end if;
    end loop;
  else
    v_modules := v_modules - p_module_slug;
    for v_to_apply in
      select jsonb_array_elements_text(coalesce(v_dependents_closure -> p_module_slug, '[]'::jsonb))
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
