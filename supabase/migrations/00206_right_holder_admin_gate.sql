-- Mig 00206: security gate on transfer_right + delegate_right.
--
-- Bug
-- ===
-- Mig 00198 (and the relaxation in mig 00200) checks only
-- `is_group_member(v_group_id, v_caller_id)` before allowing a
-- transfer or delegation. The `transferable=true` / `delegable=true`
-- invariants apply to the RIGHT, not to the caller — so ANY active
-- group member could transfer or delegate a right they don't hold.
--
-- Repro (pre-fix): a non-holder member calls
--   select public.transfer_right('<right-id>', '<their-friend-id>')
-- and the right's holder silently changes. The atom even records
-- `transferred_by` = the unauthorized caller. The iOS ⋯ menu hides
-- the button for non-holders (slice 6 `rightSecondaryActions`), but
-- a curl / SDK caller bypasses that UI gate trivially.
--
-- Fix
-- ===
-- Require the caller to be either:
--   - the current holder (metadata->>'holder_user_id' = auth.uid()), OR
--   - a group admin (group_members.role in ('founder', 'admin'))
--   - service_role / cron (v_caller_id IS NULL — bypasses, matches
--     mig 00200's pattern for rule-driven transfers)
--
-- `revoke_right` / `suspend_right` / `restore_right` already gate on
-- group membership only — that's intentional, those are admin actions
-- and the iOS UI hides them for non-admins. A follow-up slice can
-- promote them to a formal `Permission.manageRights` enum + role
-- grant, but the immediate security gap is on transfer/delegate
-- where a non-holder can silently reassign someone else's claim.
--
-- Out of scope (intentional, for follow-up):
--   - Formal `Permission.transferRight` / `delegateRight` declared in
--     groups.roles[role].permissions. The inline role check used here
--     covers the canonical admin grant; a Permission entry would let
--     custom templates fine-tune (e.g. give "treasurer" transfer
--     authority without making them a full admin).
--   - revoke_right / suspend_right / restore_right gating beyond
--     membership. Same rationale as above.

BEGIN;

-- transfer_right --------------------------------------------------------------
create or replace function public.transfer_right(
  p_right_id        uuid,
  p_to_member_id    uuid,
  p_reason          text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_metadata      jsonb;
  v_holder_uid    uuid;
  v_from_member   uuid;
  v_to_user       uuid;
  v_is_admin      boolean;
begin
  select r.group_id, r.metadata into v_group_id, v_metadata
    from public.resources r
   where r.id = p_right_id and r.resource_type = 'right' and r.archived_at is null;
  if v_group_id is null then
    raise exception 'right % not found or archived', p_right_id using errcode = '22023';
  end if;

  v_holder_uid := (v_metadata->>'holder_user_id')::uuid;

  -- Auth gate (mig 00200 + 00206): authenticated caller must be either
  -- the current holder or an admin/founder of the group. service_role /
  -- cron bypasses (auth.uid() is null) so the rule engine's
  -- transferRight consequence can drive transfers — its authority
  -- comes from the rule definition, not from a user identity.
  if v_caller_id is not null then
    if not public.is_group_member(v_group_id, v_caller_id) then
      raise exception 'not a member of this group' using errcode = '42501';
    end if;

    select exists (
      select 1 from public.group_members gm
       where gm.group_id = v_group_id
         and gm.user_id = v_caller_id
         and gm.active = true
         and gm.role in ('founder', 'admin')
    ) into v_is_admin;

    if v_caller_id <> v_holder_uid and not v_is_admin then
      raise exception 'only the holder or a group admin may transfer this right'
        using errcode = '42501';
    end if;
  end if;

  if coalesce((v_metadata->>'transferable')::boolean, false) is not true then
    raise exception 'right is not transferable' using errcode = '42501';
  end if;

  v_from_member := (v_metadata->>'holder_member_id')::uuid;
  select gm.user_id into v_to_user
    from public.group_members gm
   where gm.id = p_to_member_id and gm.group_id = v_group_id and gm.active = true;
  if v_to_user is null then
    raise exception 'new holder must be an active member of the same group' using errcode = '22023';
  end if;

  update public.resources
     set metadata = metadata || jsonb_build_object(
       'holder_member_id', p_to_member_id, 'holder_user_id', v_to_user
     )
   where id = p_right_id;

  perform public.record_system_event(
    v_group_id, 'rightTransferred', p_right_id, p_to_member_id,
    jsonb_build_object(
      'from_member_id', v_from_member, 'to_member_id', p_to_member_id,
      'transferred_by', v_caller_id, 'reason', p_reason
    )
  );
end;
$$;

comment on function public.transfer_right(uuid, uuid, text) is
  'Reassigns a transferable right. v3 (00206): caller must be the current holder OR a group admin/founder. service_role bypasses for rule-driven transfers.';

-- delegate_right --------------------------------------------------------------
create or replace function public.delegate_right(
  p_right_id           uuid,
  p_delegate_member_id uuid,
  p_until              timestamptz default null,
  p_reason             text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_metadata      jsonb;
  v_holder_uid    uuid;
  v_delegate_user uuid;
  v_is_admin      boolean;
begin
  select r.group_id, r.metadata into v_group_id, v_metadata
    from public.resources r
   where r.id = p_right_id and r.resource_type = 'right' and r.archived_at is null;
  if v_group_id is null then
    raise exception 'right % not found or archived', p_right_id using errcode = '22023';
  end if;

  v_holder_uid := (v_metadata->>'holder_user_id')::uuid;

  if v_caller_id is not null then
    if not public.is_group_member(v_group_id, v_caller_id) then
      raise exception 'not a member of this group' using errcode = '42501';
    end if;

    select exists (
      select 1 from public.group_members gm
       where gm.group_id = v_group_id
         and gm.user_id = v_caller_id
         and gm.active = true
         and gm.role in ('founder', 'admin')
    ) into v_is_admin;

    if v_caller_id <> v_holder_uid and not v_is_admin then
      raise exception 'only the holder or a group admin may delegate this right'
        using errcode = '42501';
    end if;
  end if;

  if coalesce((v_metadata->>'delegable')::boolean, false) is not true then
    raise exception 'right is not delegable' using errcode = '42501';
  end if;

  select gm.user_id into v_delegate_user
    from public.group_members gm
   where gm.id = p_delegate_member_id and gm.group_id = v_group_id and gm.active = true;
  if v_delegate_user is null then
    raise exception 'delegate must be an active member of the same group' using errcode = '22023';
  end if;

  update public.resources
     set metadata = metadata || jsonb_build_object(
       'delegate_member_id', p_delegate_member_id,
       'delegate_user_id',   v_delegate_user,
       'delegate_until',     p_until
     )
   where id = p_right_id;

  perform public.record_system_event(
    v_group_id, 'rightDelegated', p_right_id, p_delegate_member_id,
    jsonb_build_object(
      'delegate_member_id', p_delegate_member_id, 'until', p_until,
      'delegated_by', v_caller_id, 'reason', p_reason
    )
  );
end;
$$;

comment on function public.delegate_right(uuid, uuid, timestamptz, text) is
  'Records a temporary delegation. v3 (00206): caller must be the current holder OR a group admin/founder. service_role bypasses for rule-driven delegations.';

COMMIT;
