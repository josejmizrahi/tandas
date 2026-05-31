-- 00287 — Guard direct REST writes to group_members.roles.
-- (Originally numbered 00280; renumbered to 00287 — parallel work claimed
-- 00278..00284. Live applied under timestamp 20260518 / name
-- guard_group_members_roles_write.)
--
-- Sprint B of the RolesRemediation plan (Plans/Active/RolesRemediation_2026-05-17.md).
-- Closes V1 of RolesAudit_2026-05-17.md.
--
-- Background
-- ==========
-- group_members.roles jsonb (the per-member assignment array) is mutated
-- by assign_role / unassign_role (mig 00229) and by the delete_group_role
-- cascade (now in mig 00286). RLS members_update_admin (mig 00002:42)
-- ALSO allows any admin to UPDATE group_members.* including .roles
-- directly via /rest/v1/group_members — bypassing the RPCs and skipping
-- atom emit.
--
-- Same shape as mig 00286 (guard_groups_roles_write) with a different
-- session-flag name to keep the two trigger surfaces independent and
-- prevent cross-bleed (e.g. setting one shouldn't grant a bypass for
-- the other).

-- =============================================================================
-- 1. Trigger function + attach
-- =============================================================================
create or replace function public.guard_group_members_roles_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_flag text;
begin
  if new.roles is not distinct from old.roles then
    return new;
  end if;

  if auth.uid() is null then
    return new;
  end if;

  v_flag := current_setting('app.member_roles_write_via_rpc', true);
  if v_flag = '1' then
    perform set_config('app.member_roles_write_via_rpc', '', true);
    return new;
  end if;

  raise exception
    'direct write to group_members.roles is forbidden — use assign_role/unassign_role RPCs (caller %)', auth.uid()
    using errcode = '42501',
          hint = 'public.assign_role(p_group_id, p_user_id, p_role) / public.unassign_role(p_group_id, p_user_id, p_role)';
end;
$$;

revoke execute on function public.guard_group_members_roles_write() from public, anon, authenticated;

comment on function public.guard_group_members_roles_write() is
  'BEFORE UPDATE OF roles trigger on group_members: blocks direct REST writes; trusts SECURITY DEFINER RPC callers via session flag app.member_roles_write_via_rpc. Closes V1 from RolesAudit 2026-05-17.';

drop trigger if exists group_members_roles_guard on public.group_members;
create trigger group_members_roles_guard
  before update of roles on public.group_members
  for each row
  execute function public.guard_group_members_roles_write();

comment on trigger group_members_roles_guard on public.group_members is
  'Sprint B (mig 00287): blocks direct UPDATE of group_members.roles outside RPC funnel.';

-- =============================================================================
-- 2. assign_role v2 — preserves mig 00229 body, adds bypass flag before UPDATE.
-- =============================================================================
create or replace function public.assign_role(
  p_group_id uuid,
  p_user_id  uuid,
  p_role     text
) returns public.group_members
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid              uuid := auth.uid();
  v_member           public.group_members;
  v_group            public.groups;
  v_role_def         jsonb;
  v_max_holders_raw  text;
  v_max_holders      int;
  v_current_holders  int;
  v_role             text;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;
  if p_role is null or length(trim(p_role)) = 0 then
    raise exception 'role required';
  end if;
  v_role := trim(p_role);

  if not (public.has_permission(p_group_id, v_uid, 'assignRoles')
          or public.is_group_admin(p_group_id, v_uid)) then
    raise exception 'permission denied: assignRoles';
  end if;

  select * into v_group from public.groups where id = p_group_id;
  if not found then
    raise exception 'group not found: %', p_group_id;
  end if;

  v_role_def := v_group.roles -> v_role;
  if v_role_def is null then
    raise exception 'role % is not declared in groups.roles for group %', v_role, p_group_id;
  end if;

  v_max_holders_raw := v_role_def ->> 'max_holders';
  if v_max_holders_raw is not null and length(trim(v_max_holders_raw)) > 0 then
    begin
      v_max_holders := v_max_holders_raw::int;
    exception when others then
      v_max_holders := null;
    end;
    if v_max_holders is not null and v_max_holders >= 1 then
      select count(*) into v_current_holders
        from public.group_members
       where group_id = p_group_id
         and active   = true
         and user_id <> p_user_id
         and coalesce(roles, '[]'::jsonb) ? v_role;
      if v_current_holders >= v_max_holders then
        raise exception 'role % reached max_holders=% in group %',
          v_role, v_max_holders, p_group_id;
      end if;
    end if;
  end if;

  select * into v_member
    from public.group_members
   where group_id = p_group_id
     and user_id  = p_user_id
     and active   = true
   limit 1;
  if not found then
    raise exception 'target user % is not an active member of group %', p_user_id, p_group_id;
  end if;

  if coalesce(v_member.roles, '[]'::jsonb) ? v_role then
    return v_member;
  end if;

  -- Sprint B (mig 00287): authorize trigger before UPDATE.
  perform set_config('app.member_roles_write_via_rpc', '1', true);

  update public.group_members
     set roles      = coalesce(roles, '[]'::jsonb) || jsonb_build_array(v_role),
         updated_at = now()
   where id = v_member.id
   returning * into v_member;

  perform public.record_system_event(
    p_group_id,
    'roleAssigned',
    null,
    v_member.id,
    jsonb_build_object(
      'role',         v_role,
      'user_id',      p_user_id,
      'assigned_by',  v_uid
    )
  );

  return v_member;
end;
$$;

revoke execute on function public.assign_role(uuid, uuid, text) from public, anon;
grant  execute on function public.assign_role(uuid, uuid, text) to authenticated;

comment on function public.assign_role(uuid, uuid, text) is
  'v2 (mig 00287): sets app.member_roles_write_via_rpc bypass flag before UPDATE so the new guard trigger allows the RPC path. Otherwise identical to mig 00229. Closes V1 (RolesAudit 2026-05-17).';

-- =============================================================================
-- 3. unassign_role v2 — preserves mig 00229 body, adds bypass flag before UPDATE.
-- =============================================================================
create or replace function public.unassign_role(
  p_group_id uuid,
  p_user_id  uuid,
  p_role     text
) returns public.group_members
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid                  uuid := auth.uid();
  v_member               public.group_members;
  v_remaining_founders   int;
  v_new_roles            jsonb;
  v_role                 text;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;
  if p_role is null or length(trim(p_role)) = 0 then
    raise exception 'role required';
  end if;
  v_role := trim(p_role);

  if not (public.has_permission(p_group_id, v_uid, 'assignRoles')
          or public.is_group_admin(p_group_id, v_uid)) then
    raise exception 'permission denied: assignRoles';
  end if;

  if v_role = 'member' then
    raise exception 'cannot remove system role "member" (implicit baseline)';
  end if;

  select * into v_member
    from public.group_members
   where group_id = p_group_id
     and user_id  = p_user_id
     and active   = true
   limit 1;
  if not found then
    raise exception 'target user % is not an active member of group %', p_user_id, p_group_id;
  end if;

  if v_role = 'founder' then
    select count(*) into v_remaining_founders
      from public.group_members
     where group_id = p_group_id
       and active   = true
       and user_id <> p_user_id
       and coalesce(roles, '[]'::jsonb) ? 'founder';
    if v_remaining_founders = 0 then
      raise exception 'cannot remove last founder of group % — assign founder to another active member first', p_group_id;
    end if;
  end if;

  if not (coalesce(v_member.roles, '[]'::jsonb) ? v_role) then
    return v_member;
  end if;

  select coalesce(jsonb_agg(elem), '[]'::jsonb)
    into v_new_roles
    from jsonb_array_elements_text(v_member.roles) as t(elem)
   where elem <> v_role;

  -- Sprint B (mig 00287): authorize trigger before UPDATE.
  perform set_config('app.member_roles_write_via_rpc', '1', true);

  update public.group_members
     set roles      = v_new_roles,
         updated_at = now()
   where id = v_member.id
   returning * into v_member;

  perform public.record_system_event(
    p_group_id,
    'roleUnassigned',
    null,
    v_member.id,
    jsonb_build_object(
      'role',           v_role,
      'user_id',        p_user_id,
      'unassigned_by',  v_uid
    )
  );

  return v_member;
end;
$$;

revoke execute on function public.unassign_role(uuid, uuid, text) from public, anon;
grant  execute on function public.unassign_role(uuid, uuid, text) to authenticated;

comment on function public.unassign_role(uuid, uuid, text) is
  'v2 (mig 00287): sets app.member_roles_write_via_rpc bypass flag before UPDATE so the new guard trigger allows the RPC path. Otherwise identical to mig 00229. Closes V1 (RolesAudit 2026-05-17).';
