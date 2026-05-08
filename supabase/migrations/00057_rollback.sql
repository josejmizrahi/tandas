-- Rollback for 00057_set_group_module_dep_cascade.sql
--
-- Restores the slice 3 (mig 00055) behaviour: single-module flip with
-- no transitive cascade. Data state at rollback time is preserved —
-- any cascades already applied via the cascading version stay.

create or replace function public.set_group_module(
  p_group_id    uuid,
  p_module_slug text,
  p_enabled     boolean
) returns public.groups
language plpgsql security definer set search_path = public as $$
declare
  g public.groups;
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

  if p_enabled then
    update public.groups
       set active_modules = case
             when active_modules ? p_module_slug then active_modules
             else active_modules || jsonb_build_array(p_module_slug)
           end,
           updated_at = now()
     where id = p_group_id
     returning * into g;
  else
    update public.groups
       set active_modules = case
             when active_modules ? p_module_slug then active_modules - p_module_slug
             else active_modules
           end,
           updated_at = now()
     where id = p_group_id
     returning * into g;
  end if;

  if not found then
    raise exception 'group not found: %', p_group_id;
  end if;

  return g;
end;
$$;
