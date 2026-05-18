-- 00291 — Sprint C: replace is_group_admin / role-string gates with
-- has_permission across the remaining auth-critical RPCs.
--
-- Plans/Active/RolesRemediation_2026-05-17.md Sprint C.
-- Closes:
--   V3  (HERESY): transfer_right / delegate_right used
--                 gm.role IN ('founder','admin') despite
--                 transferRight / delegateRight permissions
--                 shipping in mig 00255.
--   V9          : can_modify_rules read gm.roles ? 'founder'
--                 directly. Used by RLS rules_update_governance.
--   V10         : fund_lock / fund_unlock used is_group_admin.
--   V11         : space admin RPCs (grant/revoke_access,
--                 update_metadata, promote_from_waitlist) used
--                 is_group_admin.
--   V12         : archive_group / archive_resource used is_group_admin.
--
-- DEFERRED (out of this slice):
--   V13: finalize_vote founder lookup (gm.roles ?| array['founder'])
--        — requires re-shipping the 700-line finalize_vote function
--        with surgical edits. Separate sprint.
--   V11 split: audit suggested a new `manageBookings` permission for
--        space admin RPCs. Beta-1 freeze prohibits new permission
--        catalog entries — using existing modifyGovernance for now.
--        Sprint F can re-evaluate.
--
-- All RPCs preserve their existing exception messages, side effects,
-- and atom emissions. Only the authorization gate changes.

-- =============================================================================
-- V3 (HERESY): transfer_right
-- =============================================================================
create or replace function public.transfer_right(
  p_right_id      uuid,
  p_to_member_id  uuid,
  p_reason        text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  v_caller_id      uuid := auth.uid();
  v_group_id       uuid;
  v_holder_user_id uuid;
  v_holder_member  uuid;
  v_status         text;
  v_transferable   boolean;
  v_to_user        uuid;
  v_has_perm       boolean;
BEGIN
  SELECT group_id INTO v_group_id
    FROM public.resources
   WHERE id = p_right_id AND resource_type = 'right' AND archived_at IS NULL;
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'right % not found or archived', p_right_id USING errcode = '22023';
  END IF;
  SELECT holder_user_id, holder_member_id, status, transferable
    INTO v_holder_user_id, v_holder_member, v_status, v_transferable
    FROM public.right_state_view WHERE right_id = p_right_id;
  IF v_caller_id IS NOT NULL THEN
    IF NOT public.is_group_member(v_group_id, v_caller_id) THEN
      RAISE EXCEPTION 'not a member of this group' USING errcode = '42501';
    END IF;
    -- Sprint C (mig 00291): consult has_permission(transferRight) instead
    -- of reading gm.role text. Permission ships in the founder + admin
    -- defaults since mig 00255 / 00262.
    v_has_perm := public.has_permission(v_group_id, v_caller_id, 'transferRight');
    IF v_caller_id <> v_holder_user_id AND NOT v_has_perm THEN
      RAISE EXCEPTION 'only the holder or a member with transferRight permission may transfer this right' USING errcode = '42501';
    END IF;
  END IF;
  IF v_status <> 'active' THEN
    RAISE EXCEPTION 'cannot transfer a right with status %', v_status USING errcode = '42501';
  END IF;
  IF NOT COALESCE(v_transferable, false) THEN
    RAISE EXCEPTION 'right is not transferable' USING errcode = '42501';
  END IF;
  SELECT gm.user_id INTO v_to_user
    FROM public.group_members gm
   WHERE gm.id = p_to_member_id AND gm.group_id = v_group_id AND gm.active = true;
  IF v_to_user IS NULL THEN
    RAISE EXCEPTION 'new holder must be an active member of the same group' USING errcode = '22023';
  END IF;
  PERFORM public.record_system_event(
    v_group_id, 'rightTransferred', p_right_id, p_to_member_id,
    jsonb_build_object(
      'from_member_id', v_holder_member,
      'to_member_id',   p_to_member_id,
      'transferred_by', v_caller_id,
      'reason',         p_reason
    )
  );
END;
$$;

comment on function public.transfer_right(uuid, uuid, text) is
  'v2 (mig 00291): replaces gm.role IN (founder,admin) HERESY with has_permission(transferRight). Holder bypass preserved.';

-- =============================================================================
-- V3 (HERESY): delegate_right
-- =============================================================================
create or replace function public.delegate_right(
  p_right_id            uuid,
  p_delegate_member_id  uuid,
  p_until               timestamptz default null,
  p_reason              text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  v_caller_id      uuid := auth.uid();
  v_group_id       uuid;
  v_holder_user_id uuid;
  v_status         text;
  v_delegable      boolean;
  v_delegate_user  uuid;
  v_has_perm       boolean;
BEGIN
  SELECT group_id INTO v_group_id
    FROM public.resources
   WHERE id = p_right_id AND resource_type = 'right' AND archived_at IS NULL;
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'right % not found or archived', p_right_id USING errcode = '22023';
  END IF;
  SELECT holder_user_id, status, delegable
    INTO v_holder_user_id, v_status, v_delegable
    FROM public.right_state_view WHERE right_id = p_right_id;
  IF v_caller_id IS NOT NULL THEN
    IF NOT public.is_group_member(v_group_id, v_caller_id) THEN
      RAISE EXCEPTION 'not a member of this group' USING errcode = '42501';
    END IF;
    v_has_perm := public.has_permission(v_group_id, v_caller_id, 'delegateRight');
    IF v_caller_id <> v_holder_user_id AND NOT v_has_perm THEN
      RAISE EXCEPTION 'only the holder or a member with delegateRight permission may delegate this right' USING errcode = '42501';
    END IF;
  END IF;
  IF v_status <> 'active' THEN
    RAISE EXCEPTION 'cannot delegate a right with status %', v_status USING errcode = '42501';
  END IF;
  IF NOT COALESCE(v_delegable, false) THEN
    RAISE EXCEPTION 'right is not delegable' USING errcode = '42501';
  END IF;
  SELECT gm.user_id INTO v_delegate_user
    FROM public.group_members gm
   WHERE gm.id = p_delegate_member_id AND gm.group_id = v_group_id AND gm.active = true;
  IF v_delegate_user IS NULL THEN
    RAISE EXCEPTION 'delegate must be an active member of the same group' USING errcode = '22023';
  END IF;
  PERFORM public.record_system_event(
    v_group_id, 'rightDelegated', p_right_id, p_delegate_member_id,
    jsonb_build_object(
      'delegate_member_id', p_delegate_member_id,
      'until',              p_until,
      'delegated_by',       v_caller_id,
      'reason',             p_reason
    )
  );
END;
$$;

comment on function public.delegate_right(uuid, uuid, timestamptz, text) is
  'v2 (mig 00291): replaces gm.role IN (founder,admin) HERESY with has_permission(delegateRight). Holder bypass preserved.';

-- =============================================================================
-- V10: fund_lock
-- =============================================================================
create or replace function public.fund_lock(
  p_fund_id uuid,
  p_reason  text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  v_uid       uuid := auth.uid();
  v_group_id  uuid;
  v_archived  timestamptz;
  v_is_locked boolean;
  v_reason    text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'auth required' USING errcode = '42501';
  END IF;

  SELECT group_id, archived_at
    INTO v_group_id, v_archived
    FROM public.resources
   WHERE id = p_fund_id
     AND resource_type = 'fund'
   FOR UPDATE;

  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'fund not found' USING errcode = 'check_violation';
  END IF;
  IF v_archived IS NOT NULL THEN
    RAISE EXCEPTION 'fund is archived' USING errcode = 'check_violation';
  END IF;
  -- Sprint C (mig 00291): has_permission(modifyGovernance) instead of
  -- is_group_admin. A dedicated lockFund permission could be split in
  -- a Post-Beta sprint.
  IF NOT public.has_permission(v_group_id, v_uid, 'modifyGovernance') THEN
    RAISE EXCEPTION 'permission denied: modifyGovernance required to lock funds' USING errcode = '42501';
  END IF;

  SELECT is_locked INTO v_is_locked
    FROM public.fund_lock_view
   WHERE fund_id = p_fund_id;

  IF COALESCE(v_is_locked, false) THEN
    RAISE EXCEPTION 'fund is already locked' USING errcode = 'check_violation';
  END IF;

  v_reason := nullif(trim(coalesce(p_reason, '')), '');

  PERFORM public.record_system_event(
    v_group_id, 'fundLocked', p_fund_id, NULL,
    jsonb_build_object('locked_by', v_uid, 'locked_reason', v_reason)
  );
END;
$$;

comment on function public.fund_lock(uuid, text) is
  'v2 (mig 00291): is_group_admin → has_permission(modifyGovernance). Post-Beta: split dedicated lockFund permission.';

-- =============================================================================
-- V10: fund_unlock
-- =============================================================================
create or replace function public.fund_unlock(
  p_fund_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  v_uid         uuid := auth.uid();
  v_group_id    uuid;
  v_archived    timestamptz;
  v_is_locked   boolean;
  v_locked_at   timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'auth required' USING errcode = '42501';
  END IF;

  SELECT group_id, archived_at
    INTO v_group_id, v_archived
    FROM public.resources
   WHERE id = p_fund_id
     AND resource_type = 'fund'
   FOR UPDATE;

  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'fund not found' USING errcode = 'check_violation';
  END IF;
  IF v_archived IS NOT NULL THEN
    RAISE EXCEPTION 'fund is archived' USING errcode = 'check_violation';
  END IF;
  IF NOT public.has_permission(v_group_id, v_uid, 'modifyGovernance') THEN
    RAISE EXCEPTION 'permission denied: modifyGovernance required to unlock funds' USING errcode = '42501';
  END IF;

  SELECT is_locked, locked_at
    INTO v_is_locked, v_locked_at
    FROM public.fund_lock_view
   WHERE fund_id = p_fund_id;

  IF NOT COALESCE(v_is_locked, false) THEN
    RAISE EXCEPTION 'fund is not locked' USING errcode = 'check_violation';
  END IF;

  PERFORM public.record_system_event(
    v_group_id, 'fundUnlocked', p_fund_id, NULL,
    jsonb_build_object('unlocked_by', v_uid, 'previous_locked_at', v_locked_at)
  );
END;
$$;

comment on function public.fund_unlock(uuid) is
  'v2 (mig 00291): is_group_admin → has_permission(modifyGovernance).';

-- =============================================================================
-- V12: archive_group
-- =============================================================================
create or replace function public.archive_group(
  p_group_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;
  if not public.has_permission(p_group_id, v_user_id, 'modifyGovernance') then
    raise exception 'permission denied: modifyGovernance required to archive group' using errcode = 'insufficient_privilege';
  end if;

  update public.groups
     set archived_at = now(),
         archived_by = v_user_id,
         updated_at  = now()
   where id = p_group_id
     and archived_at is null;
end;
$$;

comment on function public.archive_group(uuid) is
  'v2 (mig 00291): is_group_admin → has_permission(modifyGovernance).';

-- =============================================================================
-- V12: archive_resource
-- =============================================================================
create or replace function public.archive_resource(
  p_resource_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  v_uid      uuid := auth.uid();
  v_group_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING errcode = 'insufficient_privilege';
  END IF;

  SELECT group_id INTO v_group_id
    FROM public.resources
   WHERE id = p_resource_id;

  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'resource not found' USING errcode = 'check_violation';
  END IF;

  IF NOT public.has_permission(v_group_id, v_uid, 'modifyGovernance') THEN
    RAISE EXCEPTION 'permission denied: modifyGovernance required to archive resource' USING errcode = 'insufficient_privilege';
  END IF;

  UPDATE public.resources
     SET archived_at = now(),
         archived_by = v_uid,
         updated_at  = now()
   WHERE id = p_resource_id
     AND archived_at IS NULL;
END;
$$;

comment on function public.archive_resource(uuid) is
  'v2 (mig 00291): is_group_admin → has_permission(modifyGovernance).';

-- =============================================================================
-- V11: grant_space_access
-- =============================================================================
create or replace function public.grant_space_access(
  p_space_id  uuid,
  p_member_id uuid,
  p_until     timestamptz default null,
  p_reason    text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_resource_type text;
  v_target_active boolean;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select group_id, resource_type into v_group_id, v_resource_type
    from public.resources where id = p_space_id and archived_at is null;
  if v_group_id is null then
    raise exception 'space not found or archived' using errcode = '02000';
  end if;
  if v_resource_type <> 'space' then
    raise exception 'resource is not a space' using errcode = '22023';
  end if;
  -- Sprint C (mig 00291): has_permission(modifyGovernance) replaces
  -- is_group_admin. Future: split a manageBookings permission.
  if not public.has_permission(v_group_id, v_caller_id, 'modifyGovernance') then
    raise exception 'permission denied: modifyGovernance required to grant space access' using errcode = '42501';
  end if;
  select active into v_target_active from public.group_members
    where id = p_member_id and group_id = v_group_id;
  if v_target_active is null then
    raise exception 'target member not in this group' using errcode = '02000';
  end if;
  if not v_target_active then
    raise exception 'target member not active' using errcode = '22023';
  end if;
  perform public.record_system_event(v_group_id, 'spaceAccessGranted', p_space_id, p_member_id,
    jsonb_strip_nulls(jsonb_build_object(
      'granted_by', v_caller_id,
      'until', p_until,
      'reason', nullif(trim(coalesce(p_reason, '')), ''))));
end;
$$;

comment on function public.grant_space_access(uuid, uuid, timestamptz, text) is
  'v2 (mig 00291): is_group_admin → has_permission(modifyGovernance). Post-Beta: split manageBookings permission.';

-- =============================================================================
-- V11: revoke_space_access
-- =============================================================================
create or replace function public.revoke_space_access(
  p_space_id  uuid,
  p_member_id uuid,
  p_reason    text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_resource_type text;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select group_id, resource_type into v_group_id, v_resource_type
    from public.resources where id = p_space_id;
  if v_group_id is null then
    raise exception 'space not found' using errcode = '02000';
  end if;
  if v_resource_type <> 'space' then
    raise exception 'resource is not a space' using errcode = '22023';
  end if;
  if not public.has_permission(v_group_id, v_caller_id, 'modifyGovernance') then
    raise exception 'permission denied: modifyGovernance required to revoke space access' using errcode = '42501';
  end if;
  perform public.record_system_event(v_group_id, 'spaceAccessRevoked', p_space_id, p_member_id,
    jsonb_strip_nulls(jsonb_build_object(
      'revoked_by', v_caller_id,
      'reason', nullif(trim(coalesce(p_reason, '')), ''))));
end;
$$;

comment on function public.revoke_space_access(uuid, uuid, text) is
  'v2 (mig 00291): is_group_admin → has_permission(modifyGovernance).';

-- =============================================================================
-- V11: update_space_metadata
-- =============================================================================
create or replace function public.update_space_metadata(
  p_space_id uuid,
  p_patch    jsonb
) returns public.resources
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_resource_type text;
  v_old_name      text;
  v_new_row       public.resources;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select group_id, resource_type, metadata->>'name' into v_group_id, v_resource_type, v_old_name
    from public.resources where id = p_space_id and archived_at is null;
  if v_group_id is null then
    raise exception 'space not found or archived' using errcode = '02000';
  end if;
  if v_resource_type <> 'space' then
    raise exception 'resource is not a space' using errcode = '22023';
  end if;
  if not public.has_permission(v_group_id, v_caller_id, 'modifyGovernance') then
    raise exception 'permission denied: modifyGovernance required to update space metadata' using errcode = '42501';
  end if;
  if p_patch is null or p_patch = '{}'::jsonb then
    select * into v_new_row from public.resources where id = p_space_id;
    return v_new_row;
  end if;
  if p_patch ? 'capacity' and (p_patch->>'capacity')::int < 0 then
    raise exception 'capacity must be non-negative' using errcode = '22023';
  end if;
  if p_patch ? 'name' and length(trim(p_patch->>'name')) = 0 then
    raise exception 'name cannot be empty' using errcode = '22023';
  end if;
  update public.resources set metadata = metadata || p_patch, updated_at = now()
    where id = p_space_id returning * into v_new_row;
  return v_new_row;
end;
$$;

comment on function public.update_space_metadata(uuid, jsonb) is
  'v2 (mig 00291): is_group_admin → has_permission(modifyGovernance).';

-- =============================================================================
-- V11: promote_space_from_waitlist
-- =============================================================================
create or replace function public.promote_space_from_waitlist(
  p_space_id uuid
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id      uuid := auth.uid();
  v_group_id       uuid;
  v_resource_type  text;
  v_next_member_id uuid;
  v_next_joined_at timestamptz;
  v_event_id       uuid;
begin
  select group_id, resource_type into v_group_id, v_resource_type
    from public.resources where id = p_space_id;
  if v_group_id is null then
    raise exception 'space not found' using errcode = '02000';
  end if;
  if v_resource_type <> 'space' then
    raise exception 'resource is not a space' using errcode = '22023';
  end if;
  -- Sprint C (mig 00291): has_permission(modifyGovernance) for
  -- authenticated callers. service_role (auth.uid IS NULL) bypass
  -- preserved for the cron-driven waitlist promoter.
  if v_caller_id is not null
     and not public.has_permission(v_group_id, v_caller_id, 'modifyGovernance') then
    raise exception 'permission denied: modifyGovernance required (or service_role for cron)' using errcode = '42501';
  end if;
  with joins as (
    select j.id, j.member_id, coalesce((j.payload->>'priority')::int, 0) as priority, j.occurred_at
    from public.system_events j
    where j.event_type = 'spaceWaitlistJoined' and j.resource_id = p_space_id
  ),
  active as (
    select j.* from joins j
    where not exists (
      select 1 from public.system_events p
      where p.event_type = 'spaceWaitlistPromoted' and p.resource_id = p_space_id
        and p.member_id = j.member_id and p.occurred_at > j.occurred_at
    )
  )
  select member_id, occurred_at into v_next_member_id, v_next_joined_at
    from active order by priority desc, occurred_at asc limit 1;
  if v_next_member_id is null then return null; end if;
  v_event_id := public.record_system_event(v_group_id, 'spaceWaitlistPromoted', p_space_id, v_next_member_id,
    jsonb_build_object(
      'promoted_by', coalesce(v_caller_id::text, 'service_role'),
      'original_joined_at', v_next_joined_at,
      'promoted_at', now()));
  return v_event_id;
end;
$$;

comment on function public.promote_space_from_waitlist(uuid) is
  'v2 (mig 00291): is_group_admin → has_permission(modifyGovernance) for auth callers. service_role bypass preserved for cron.';

-- =============================================================================
-- V9: can_modify_rules
-- =============================================================================
create or replace function public.can_modify_rules(
  p_group_id uuid,
  p_user_id  uuid
) returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_governance_value text;
  v_is_member        boolean;
begin
  select exists (
    select 1 from public.group_members
     where group_id = p_group_id and user_id = p_user_id and active = true
  ) into v_is_member;
  if not v_is_member then return false; end if;

  select governance->>'whoCanModifyRules' into v_governance_value
    from public.groups where id = p_group_id;

  return case v_governance_value
    -- Sprint C (mig 00291): consult has_permission(modifyRules) instead
    -- of reading gm.roles ? 'founder' directly. Used by RLS
    -- rules_update_governance (mig 00024) so any custom role granting
    -- modifyRules now satisfies the gate.
    when 'founder'           then public.has_permission(p_group_id, p_user_id, 'modifyRules')
    when 'anyMember'         then true
    when 'majorityVote'      then false
    when 'supermajorityVote' then false
    else                          false
  end;
end;
$$;

comment on function public.can_modify_rules(uuid, uuid) is
  'v2 (mig 00291): "founder" branch now delegates to has_permission(modifyRules) instead of reading gm.roles directly. Used by RLS rules_update_governance.';
