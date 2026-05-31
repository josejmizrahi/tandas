-- 00289 — Fix latent bug: role RPCs reference group_members.updated_at
-- which does not exist.
--
-- Background
-- ==========
-- Mig 00229 (assign_role / unassign_role) and mig 00230 (delete_group_role
-- cascade) wrote `UPDATE group_members SET roles = ..., updated_at = now()`
-- assuming parity with groups.updated_at. The column was never added.
-- assign_role / unassign_role / delete_group_role have all been broken
-- since 00229 — any call errors with `42703: column "updated_at" of
-- relation "group_members" does not exist`. The bug went undetected
-- because the iOS Phase-5 role-assignment UI flow was never exercised
-- end-to-end in production data.
--
-- Discovered 2026-05-17 during Sprint A backfill (mig 00290) which hit
-- the same assumption.
--
-- Surgical fix: drop the `updated_at = now()` clause from each UPDATE.
-- No new column is added (Beta-1 freeze prohibits new state). Atom
-- emission via record_system_event remains the audit trail.
--
-- Preserves all Sprint B (mig 00286 + 00287) semantics:
--   - assign_role / unassign_role: set app.member_roles_write_via_rpc
--     bypass flag before UPDATE (consumed by guard_group_members_roles_write).
--   - delete_group_role: per-member cascade with roleUnassigned atoms
--     (cause = role_deleted) + groupRolesChanged op=deleted atom.
--   - upsert_group_role is unaffected — only mutates groups.updated_at
--     which does exist.

-- =============================================================================
-- 1. assign_role v3 — drop updated_at
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

  perform set_config('app.member_roles_write_via_rpc', '1', true);

  update public.group_members
     set roles = coalesce(roles, '[]'::jsonb) || jsonb_build_array(v_role)
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

comment on function public.assign_role(uuid, uuid, text) is
  'v3 (mig 00289): drops bogus group_members.updated_at write (column never existed; latent bug since 00229). Preserves mig 00287 bypass flag + atom emission.';

-- =============================================================================
-- 2. unassign_role v3 — drop updated_at
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

  perform set_config('app.member_roles_write_via_rpc', '1', true);

  update public.group_members
     set roles = v_new_roles
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

comment on function public.unassign_role(uuid, uuid, text) is
  'v3 (mig 00289): drops bogus group_members.updated_at write (column never existed; latent bug since 00229). Preserves mig 00287 bypass flag + atom emission.';

-- =============================================================================
-- 3. delete_group_role v4 — drop updated_at from the per-member cascade
-- =============================================================================
create or replace function public.delete_group_role(
  p_group_id         uuid,
  p_role_id          text,
  p_expected_version int default null
)
returns public.groups
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid             uuid := auth.uid();
  v_normalized      text;
  v_current_version int;
  v_affected        record;
  g                 public.groups;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;

  if not (public.has_permission(p_group_id, v_uid, 'assignRoles')
          or public.is_group_admin(p_group_id, v_uid)) then
    raise exception 'permission denied: assignRoles';
  end if;

  v_normalized := lower(trim(coalesce(p_role_id, '')));
  if v_normalized = '' then
    raise exception 'role_id required';
  end if;

  if v_normalized in ('founder', 'member') then
    raise exception 'cannot delete system role %', v_normalized;
  end if;

  select roles_version into v_current_version
    from public.groups
   where id = p_group_id
   for update;

  if not found then
    raise exception 'group not found: %', p_group_id;
  end if;

  if p_expected_version is not null and v_current_version <> p_expected_version then
    raise exception 'roles version conflict: expected %, got % — refresh and retry',
      p_expected_version, v_current_version
      using errcode = '40001';
  end if;

  for v_affected in
    select id, user_id
      from public.group_members
     where group_id = p_group_id
       and coalesce(roles, '[]'::jsonb) ? v_normalized
  loop
    perform set_config('app.member_roles_write_via_rpc', '1', true);

    update public.group_members gm
       set roles = (
                     select coalesce(jsonb_agg(elem), '[]'::jsonb)
                       from jsonb_array_elements_text(gm.roles) as t(elem)
                      where elem <> v_normalized
                   )
     where gm.id = v_affected.id;

    perform public.record_system_event(
      p_group_id,
      'roleUnassigned',
      null,
      v_affected.id,
      jsonb_build_object(
        'role',           v_normalized,
        'user_id',        v_affected.user_id,
        'unassigned_by',  v_uid,
        'cause',          'role_deleted'
      )
    );
  end loop;

  perform set_config('app.role_write_via_rpc', '1', true);

  update public.groups
     set roles      = roles - v_normalized,
         updated_at = now()
   where id = p_group_id
   returning * into g;

  perform public.record_system_event(
    p_group_id,
    'groupRolesChanged',
    null,
    null,
    jsonb_build_object(
      'op',         'deleted',
      'role_id',    v_normalized,
      'changed_by', v_uid
    )
  );

  return g;
end;
$$;

comment on function public.delete_group_role(uuid, text, int) is
  'v4 (mig 00289): drops bogus group_members.updated_at write (column never existed) from the cascade. groups.updated_at write preserved — that column DOES exist. Otherwise identical to mig 00286.';
