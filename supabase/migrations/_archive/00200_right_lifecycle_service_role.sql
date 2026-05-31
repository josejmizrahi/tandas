-- Mig 00200: relax service_role gates on right lifecycle RPCs +
-- harden invariants so rule-engine driven transfers/revocations are
-- safe.
--
-- Why
-- ===
-- The rule engine (process-system-events cron) runs as service_role
-- with `auth.uid() = NULL`. It needs to invoke the right lifecycle
-- RPCs to act on rule consequences (`transferRight`, future
-- `revokeRight` / `suspendRight`), but mig 00198's RPCs all fail-fast
-- on `v_caller_id is null` with "not authenticated".
--
-- This migration mirrors mig 00094's pattern (record_system_event):
-- authenticated callers stay gated by `is_group_member`; service_role
-- (no auth.uid) bypasses. The rule engine emits atoms carrying its
-- own `transferred_by`/`revoked_by`/etc. payload so the audit trail
-- still attributes the actor — auth context is replaced by
-- consequence-emitted attribution.
--
-- Updated RPCs:
--   transfer_right, delegate_right, revoke_right, suspend_right,
--   restore_right, exercise_right.
--
-- `update_right_metadata` is intentionally NOT relaxed — admin tuning
-- of knobs (transferable, priority) should always go through a
-- person, not a silent rule consequence. If a rule needs to flip
-- those, it must open a vote first.
--
-- Hardening kept
--   - transferable=true still required for transfer_right (rule or
--     person doesn't override the right's declared transferability).
--   - delegable=true still required for delegate_right.
--   - exercise_right still requires caller = holder OR delegate
--     (service_role exercise would be ambiguous — left blocked).

BEGIN;

-- transfer_right -------------------------------------------------------------
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
  v_from_member   uuid;
  v_to_user       uuid;
begin
  select r.group_id, r.metadata into v_group_id, v_metadata
    from public.resources r
   where r.id = p_right_id and r.resource_type = 'right' and r.archived_at is null;
  if v_group_id is null then
    raise exception 'right % not found or archived', p_right_id using errcode = '22023';
  end if;

  -- Auth gate (mig 00200): authenticated user must be a group member;
  -- service_role / cron bypasses since the rule engine's atom payload
  -- carries its own attribution.
  if v_caller_id is not null then
    if not public.is_group_member(v_group_id, v_caller_id) then
      raise exception 'not a member of this group' using errcode = '42501';
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
grant execute on function public.transfer_right(uuid, uuid, text) to service_role;

-- delegate_right -------------------------------------------------------------
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
  v_delegate_user uuid;
begin
  select r.group_id, r.metadata into v_group_id, v_metadata
    from public.resources r
   where r.id = p_right_id and r.resource_type = 'right' and r.archived_at is null;
  if v_group_id is null then
    raise exception 'right % not found or archived', p_right_id using errcode = '22023';
  end if;

  if v_caller_id is not null then
    if not public.is_group_member(v_group_id, v_caller_id) then
      raise exception 'not a member of this group' using errcode = '42501';
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
grant execute on function public.delegate_right(uuid, uuid, timestamptz, text) to service_role;

-- revoke_right ---------------------------------------------------------------
create or replace function public.revoke_right(
  p_right_id  uuid,
  p_reason    text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_caller_id uuid := auth.uid();
  v_group_id  uuid;
  v_status    text;
begin
  select r.group_id, r.status into v_group_id, v_status
    from public.resources r
   where r.id = p_right_id and r.resource_type = 'right' and r.archived_at is null;
  if v_group_id is null then
    raise exception 'right % not found or archived', p_right_id using errcode = '22023';
  end if;

  if v_caller_id is not null then
    if not public.is_group_member(v_group_id, v_caller_id) then
      raise exception 'not a member of this group' using errcode = '42501';
    end if;
  end if;

  if v_status = 'revoked' then
    return;
  end if;
  update public.resources set status = 'revoked' where id = p_right_id;
  perform public.record_system_event(
    v_group_id, 'rightRevoked', p_right_id, null,
    jsonb_build_object('previous_status', v_status, 'revoked_by', v_caller_id, 'reason', p_reason)
  );
end;
$$;
grant execute on function public.revoke_right(uuid, text) to service_role;

-- suspend_right --------------------------------------------------------------
create or replace function public.suspend_right(
  p_right_id  uuid,
  p_until     timestamptz default null,
  p_reason    text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_caller_id uuid := auth.uid();
  v_group_id  uuid;
begin
  select r.group_id into v_group_id
    from public.resources r
   where r.id = p_right_id and r.resource_type = 'right' and r.archived_at is null;
  if v_group_id is null then
    raise exception 'right % not found or archived', p_right_id using errcode = '22023';
  end if;

  if v_caller_id is not null then
    if not public.is_group_member(v_group_id, v_caller_id) then
      raise exception 'not a member of this group' using errcode = '42501';
    end if;
  end if;

  update public.resources
     set metadata = metadata || jsonb_build_object(
       'suspended_at', now(), 'suspended_until', p_until, 'suspended_by', v_caller_id
     )
   where id = p_right_id;
  perform public.record_system_event(
    v_group_id, 'rightSuspended', p_right_id, null,
    jsonb_build_object('until', p_until, 'suspended_by', v_caller_id, 'reason', p_reason)
  );
end;
$$;
grant execute on function public.suspend_right(uuid, timestamptz, text) to service_role;

-- restore_right --------------------------------------------------------------
create or replace function public.restore_right(
  p_right_id  uuid,
  p_reason    text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_caller_id uuid := auth.uid();
  v_group_id  uuid;
begin
  select r.group_id into v_group_id
    from public.resources r
   where r.id = p_right_id and r.resource_type = 'right' and r.archived_at is null;
  if v_group_id is null then
    raise exception 'right % not found or archived', p_right_id using errcode = '22023';
  end if;

  if v_caller_id is not null then
    if not public.is_group_member(v_group_id, v_caller_id) then
      raise exception 'not a member of this group' using errcode = '42501';
    end if;
  end if;

  update public.resources
     set metadata = metadata - 'suspended_at' - 'suspended_until' - 'suspended_by',
         status   = case when status = 'revoked' then 'active' else status end
   where id = p_right_id;
  perform public.record_system_event(
    v_group_id, 'rightRestored', p_right_id, null,
    jsonb_build_object('restored_by', v_caller_id, 'reason', p_reason)
  );
end;
$$;
grant execute on function public.restore_right(uuid, text) to service_role;

-- exercise_right -------------------------------------------------------------
-- NOT relaxed: an exercise needs a concrete actor (holder/delegate) to
-- attribute the use. Cron-driven exercises are doctrinally suspicious;
-- if such a need emerges, ship a separate `record_right_exercise_for_rule`
-- helper with explicit attribution rather than overloading this RPC.
-- Function body left unchanged from mig 00198.

COMMIT;
