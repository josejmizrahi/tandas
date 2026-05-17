-- Rollback for 00237_member_rpcs_gated_on_has_permission.sql
--
-- Restores prior bodies (is_group_admin gate). seed_template_roles
-- from mig 00067, set_turn_order from mig 00003.

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
  if not public.is_group_admin(p_group_id, uid) then
    raise exception 'only group admins can seed template roles';
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

create or replace function public.set_turn_order(p_group_id uuid, p_user_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare i int;
begin
  if not public.is_group_admin(p_group_id, auth.uid()) then raise exception 'admin only'; end if;
  update public.group_members set turn_order = null
    where group_id = p_group_id and active;
  for i in 1..array_length(p_user_ids, 1) loop
    update public.group_members set turn_order = i
      where group_id = p_group_id and user_id = p_user_ids[i] and active;
  end loop;
end;
$$;
