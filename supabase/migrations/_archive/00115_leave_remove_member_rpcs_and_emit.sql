-- 00102 — `leave_group` + `remove_member` RPCs that emit `memberLeft`,
-- plus a fix-up of the existing `remove_member_on_removal_pass` trigger
-- so the vote-driven removal path also lands a system_event.
--
-- Today three things converge to keep `memberLeft` empty:
--   1. No server-side RPC for self-leave. iOS soft-deletes via direct
--      table mutation, missing the gate + the emit.
--   2. iOS `removeMember(memberId:)` deletes the row directly from
--      `group_members` — no admin check beyond RLS, no event.
--   3. `remove_member_on_removal_pass` (00035) deletes after a
--      member_removal vote passes but never records the moment.
--
-- This migration adds the two missing RPCs and patches the trigger.
-- iOS callers will switch to the RPCs in a paired commit; the direct
-- DELETE path stays viable but will simply not surface in the activity
-- timeline (acceptable transition window — RLS still gates it).
--
-- Soft vs hard delete: leave_group + remove_member set `active = false`
-- so history (votes the member cast, fines they received) keeps a
-- valid FK. The trigger keeps its DELETE for backward-compat with
-- existing data flows that may depend on the row being gone — switching
-- it to soft delete is a behavior change worth its own migration.

-- =============================================================
-- 1. leave_group — self-leave by the calling user
-- =============================================================
create or replace function public.leave_group(p_group_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid       uuid := auth.uid();
  v_member_id uuid;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;

  select id into v_member_id
    from public.group_members
   where group_id = p_group_id
     and user_id  = v_uid
     and active   = true;

  if v_member_id is null then
    raise exception 'not an active member of this group';
  end if;

  -- Emit BEFORE the soft-delete: at this point the caller is still a
  -- member, so record_system_event's membership gate (00094) passes.
  -- Both writes land in the same transaction — a failure on either
  -- rolls back atomically.
  perform public.record_system_event(
    p_group_id,
    'memberLeft',
    null,
    v_member_id,
    jsonb_build_object('user_id', v_uid, 'reason', 'self_leave')
  );

  update public.group_members
     set active     = false,
         updated_at = now()
   where id = v_member_id;
end;
$$;

revoke execute on function public.leave_group(uuid) from public, anon;
grant  execute on function public.leave_group(uuid) to authenticated;

comment on function public.leave_group(uuid) is
  'Self-leave: soft-deletes the calling user''s group_members row + emits memberLeft (00102). Caller must be an active member. Soft delete preserves history (votes cast, fines received) for downstream queries.';

-- =============================================================
-- 2. remove_member — admin-driven removal
-- =============================================================
create or replace function public.remove_member(
  p_group_id uuid,
  p_user_id  uuid,
  p_reason   text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid       uuid := auth.uid();
  v_member_id uuid;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;
  if not public.is_group_admin(p_group_id, v_uid) then
    raise exception 'admin only';
  end if;
  if v_uid = p_user_id then
    raise exception 'admins cannot remove themselves — use leave_group';
  end if;

  select id into v_member_id
    from public.group_members
   where group_id = p_group_id
     and user_id  = p_user_id
     and active   = true;

  if v_member_id is null then
    raise exception 'target user is not an active member of this group';
  end if;

  perform public.record_system_event(
    p_group_id,
    'memberLeft',
    null,
    v_member_id,
    jsonb_build_object(
      'user_id',    p_user_id,
      'removed_by', v_uid,
      'reason',     coalesce(p_reason, 'admin_removed')
    )
  );

  update public.group_members
     set active     = false,
         updated_at = now()
   where id = v_member_id;
end;
$$;

revoke execute on function public.remove_member(uuid, uuid, text) from public, anon;
grant  execute on function public.remove_member(uuid, uuid, text) to authenticated;

comment on function public.remove_member(uuid, uuid, text) is
  'Admin removes another member from a group. Caller must be group admin and cannot remove themselves. Soft-deletes the row + emits memberLeft with removed_by + reason in payload (00102).';

-- =============================================================
-- 3. Patch remove_member_on_removal_pass to emit memberLeft
-- =============================================================
create or replace function public.remove_member_on_removal_pass()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
begin
  if new.vote_type = 'member_removal'
     and new.status = 'resolved'
     and old.status = 'open'
     and (new.payload->>'resolution') = 'passed'
     and new.reference_id is not null then

    select id into v_member_id
      from public.group_members
     where group_id = new.group_id
       and user_id  = new.reference_id;

    delete from public.group_members
     where group_id = new.group_id
       and user_id  = new.reference_id;

    if v_member_id is not null then
      perform public.record_system_event(
        new.group_id,
        'memberLeft',
        null,
        v_member_id,
        jsonb_build_object(
          'user_id', new.reference_id,
          'reason',  'vote_removal',
          'vote_id', new.id
        )
      );
    end if;
  end if;
  return new;
end;
$$;

comment on function public.remove_member_on_removal_pass() is
  'Removes a member when its member_removal vote resolves passed. Emits memberLeft with reason=vote_removal (00102). Watches votes.status open→resolved.';
