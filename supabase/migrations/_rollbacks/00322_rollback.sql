-- Rollback for mig 00322: restore the legacy v_legacy_role branch.
-- WARNING: this restoration only makes sense if group_members.role text
-- column is reintroduced first; without it, has_permission will crash
-- again with ERROR 42703. Use only when reverting mig 00303 too.

create or replace function public.has_permission(p_group_id uuid, p_user_id uuid, p_permission text)
  returns boolean
  language plpgsql
  stable security definer
  set search_path to 'public'
as $function$
declare
  v_member_roles jsonb;
  v_legacy_role  text;
  v_group_roles  jsonb;
  v_role_key     text;
  v_perms        jsonb;
begin
  if p_group_id is null or p_user_id is null or p_permission is null then
    return false;
  end if;

  select gm.roles, gm.role
    into v_member_roles, v_legacy_role
    from public.group_members gm
   where gm.group_id = p_group_id
     and gm.user_id  = p_user_id
     and gm.active
   limit 1;

  if not found then
    return false;
  end if;

  select g.roles into v_group_roles
    from public.groups g
   where g.id = p_group_id;

  if v_group_roles is null then
    return false;
  end if;

  if v_member_roles is not null and jsonb_typeof(v_member_roles) = 'array' then
    for v_role_key in
      select value::text from jsonb_array_elements_text(v_member_roles)
    loop
      if v_role_key = 'admin' then
        v_role_key := 'founder';
      end if;
      v_perms := v_group_roles -> v_role_key -> 'permissions';
      if v_perms is not null
         and jsonb_typeof(v_perms) = 'array'
         and v_perms ? p_permission then
        return true;
      end if;
    end loop;
  end if;

  if v_legacy_role is not null and length(trim(v_legacy_role)) > 0 then
    v_role_key := case v_legacy_role when 'admin' then 'founder' else v_legacy_role end;
    v_perms := v_group_roles -> v_role_key -> 'permissions';
    if v_perms is not null
       and jsonb_typeof(v_perms) = 'array'
       and v_perms ? p_permission then
      return true;
    end if;
  end if;

  return false;
end;
$function$;
