-- 00098 — Emit lifecycle system_events from the remaining RPCs that were
-- silent. Closes the audit gap "events feel without memory" at the
-- group level: today only RSVP submission and fine officialization
-- emit rows, so ActivitySectionView shows almost nothing meaningful
-- for events that haven't accumulated RSVP/fine traffic.
--
-- Three new emits:
--   close_event_no_fines → eventClosed
--   cancel_event         → eventClosed (status:cancelled in payload)
--   join_group_by_code   → memberJoined (both fresh-join and reactivation)
--
-- All three emit AFTER the mutation succeeds. record_system_event's
-- membership gate (00094) passes because the caller is either the
-- event host/admin (already members) or the joining user themself
-- (the same RPC just inserted/reactivated their membership a few
-- statements earlier).
--
-- voteResolved + ruleAmountChanged are deferred — they involve more
-- moving parts (finalize_vote runs in an edge function, the trigger
-- archive_rule_on_repeal_pass mutates rules in a separate context).

create or replace function public.close_event_no_fines(p_event_id uuid)
returns public.events
language plpgsql security definer set search_path = public as $$
declare e public.events;
begin
  select * into e from public.events where id = p_event_id;
  if not found then raise exception 'event not found'; end if;
  if not (public.is_group_admin(e.group_id, auth.uid()) or e.host_id = auth.uid()) then
    raise exception 'host or admin only';
  end if;
  update public.events
    set status = 'completed',
        closed_at = now(),
        updated_at = now()
    where id = p_event_id
    returning * into e;

  perform public.record_system_event(
    e.group_id,
    'eventClosed',
    e.id,
    null,
    jsonb_build_object(
      'title',     e.title,
      'closed_at', e.closed_at,
      'status',    e.status
    )
  );

  return e;
end;
$$;

create or replace function public.cancel_event(
  p_event_id uuid,
  p_reason text default null
) returns public.events
language plpgsql security definer set search_path = public as $$
declare e public.events;
begin
  select * into e from public.events where id = p_event_id;
  if not found then raise exception 'event not found'; end if;
  if not (public.is_group_admin(e.group_id, auth.uid()) or e.host_id = auth.uid()) then
    raise exception 'host or admin only';
  end if;
  update public.events
    set status = 'cancelled',
        cancellation_reason = p_reason,
        updated_at = now()
    where id = p_event_id
    returning * into e;

  -- Cancellation = closure with a reason. ActivitySectionView reads
  -- payload.status to differentiate "Se cerró" vs "Se canceló" rendering.
  perform public.record_system_event(
    e.group_id,
    'eventClosed',
    e.id,
    null,
    jsonb_build_object(
      'title',  e.title,
      'status', 'cancelled',
      'reason', p_reason
    )
  );

  return e;
end;
$$;

create or replace function public.join_group_by_code(p_code text)
returns public.groups
language plpgsql security definer set search_path = public as $$
declare
  g public.groups;
  v_max int;
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'auth required'; end if;
  select * into g from public.groups where invite_code = p_code;
  if not found then raise exception 'invite code not found'; end if;

  if exists (select 1 from public.group_members where group_id = g.id and user_id = v_uid) then
    -- Reactivation: was a member, left, rejoined via code. Still emit
    -- memberJoined so the timeline reflects the (re-)arrival.
    update public.group_members set active = true where group_id = g.id and user_id = v_uid;
    perform public.record_system_event(
      g.id,
      'memberJoined',
      null,
      null,
      jsonb_build_object('user_id', v_uid, 'reactivated', true)
    );
    return g;
  end if;

  select coalesce(max(turn_order), 0) into v_max from public.group_members where group_id = g.id;
  insert into public.group_members (group_id, user_id, role, turn_order)
    values (g.id, v_uid, 'member', v_max + 1);

  perform public.record_system_event(
    g.id,
    'memberJoined',
    null,
    null,
    jsonb_build_object('user_id', v_uid, 'reactivated', false)
  );

  return g;
end;
$$;

comment on function public.close_event_no_fines(uuid) is
  'Closes an event without firing the rule engine (V1). Emits eventClosed to system_events for the activity timeline (00098).';
comment on function public.cancel_event(uuid, text) is
  'Cancels an event with optional reason. Emits eventClosed with status:cancelled payload (00098) — ActivitySectionView differentiates by reading payload.status.';
comment on function public.join_group_by_code(text) is
  'Joins or reactivates a member via invite code. Emits memberJoined (00098) for the activity timeline.';
