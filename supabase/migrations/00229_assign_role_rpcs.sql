-- 00229 — assign_role + unassign_role RPCs. Phase 5 (RolesV2 completion).
--
-- Background
-- ==========
-- mig 00063 shipped groups.roles + has_permission, and mig 00067 wired
-- templates.config.defaultRoles → groups.roles via seed_template_roles
-- at create time. What was missing for end-to-end role management:
-- the actual assignment surface. Founders couldn't grant a custom role
-- (treasurer, seat_owner, etc.) to a member without raw SQL.
--
-- This migration adds the two RPCs the iOS app uses to mutate
-- group_members.roles (jsonb array) under controlled gates.
--
-- Gating
-- ======
-- Both RPCs require has_permission(group_id, auth.uid(), 'assignRoles').
-- Founders inherit this permission via the column default in mig 00063
-- (extended in 00209 for right ops). Other members can be granted
-- 'assignRoles' via a custom role declared in templates or via
-- upsert_group_role (mig 00230). is_group_admin is kept as a defensive
-- legacy fallback for groups that predate the founder default seed.
--
-- Invariants
-- ==========
--   1. Target role must exist in groups.roles (no silent typo creates).
--   2. max_holders is enforced atomically (count BEFORE update).
--   3. Idempotent: re-assigning a role the member already holds, or
--      removing a role they don't have, is a no-op and emits no event.
--   4. Cannot remove the 'member' system role (it is the implicit
--      baseline — removing it would orphan the membership).
--   5. Cannot remove the last 'founder' from a group (would lock the
--      group out of governance edits). Founder must be replaced first.
--
-- Events
-- ======
-- Successful (non-noop) assignment emits `roleAssigned`; revocation
-- emits `roleUnassigned`. Whitelist extension lives in mig 00231.
-- Payload mirrors memberLeft conventions: { role, user_id, [un]assigned_by }.

-- =============================================================================
-- 1. assign_role(p_group_id, p_user_id, p_role)
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

  -- max_holders enforcement (count distinct active members already holding it).
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

  -- Idempotent no-op: role already present.
  if coalesce(v_member.roles, '[]'::jsonb) ? v_role then
    return v_member;
  end if;

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
  'Phase 5 (mig 00229): adds p_role to group_members.roles jsonb array. Gated by has_permission(assignRoles) or is_group_admin. Enforces max_holders, requires the role to exist in groups.roles. Idempotent. Emits roleAssigned on a real change.';

-- =============================================================================
-- 2. unassign_role(p_group_id, p_user_id, p_role)
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

  -- Last-founder protection. Allow removing 'founder' only when at
  -- least one other active member still holds it. Founder rotation
  -- must therefore be done in two steps: assign_role(new_founder,
  -- 'founder') then unassign_role(old_founder, 'founder').
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

  -- Idempotent no-op: role not present.
  if not (coalesce(v_member.roles, '[]'::jsonb) ? v_role) then
    return v_member;
  end if;

  -- Strip the role. coalesce inside the aggregate handles the
  -- edge case where the resulting array is empty.
  select coalesce(jsonb_agg(elem), '[]'::jsonb)
    into v_new_roles
    from jsonb_array_elements_text(v_member.roles) as t(elem)
   where elem <> v_role;

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
  'Phase 5 (mig 00229): removes p_role from group_members.roles jsonb array. Gated by has_permission(assignRoles) or is_group_admin. Blocks removing system "member" and the last "founder". Idempotent. Emits roleUnassigned on a real change.';
