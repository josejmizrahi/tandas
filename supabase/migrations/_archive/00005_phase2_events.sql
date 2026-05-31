-- Phase 2: events RPCs.
-- set_rsvp: member sets their own RSVP for an event (idempotent)
-- close_event: admin marks event completed (Phase 4 will plumb evaluate_event_rules)
-- roll_event_series: idempotent helper that creates the next event in the series

create or replace function public.set_rsvp(
  p_event_id uuid,
  p_status text
)
returns public.event_attendance
language plpgsql security definer set search_path = public as $$
declare
  e public.events;
  att public.event_attendance;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  if p_status not in ('pending','going','maybe','declined') then
    raise exception 'invalid rsvp_status: %', p_status;
  end if;

  select * into e from public.events where id = p_event_id;
  if not found then raise exception 'event not found'; end if;
  if not public.is_group_member(e.group_id, auth.uid()) then raise exception 'not a member'; end if;

  -- Upsert attendance row for this user (event, user) is unique
  insert into public.event_attendance (event_id, user_id, rsvp_status, rsvp_at)
  values (p_event_id, auth.uid(), p_status, now())
  on conflict (event_id, user_id)
  do update set
    rsvp_status = excluded.rsvp_status,
    rsvp_at     = now()
  returning * into att;
  return att;
end;
$$;
revoke execute on function public.set_rsvp(uuid, text) from public, anon;
grant  execute on function public.set_rsvp(uuid, text) to authenticated;

-- close_event: admin marks the event completed.
-- This is the Phase 2 version. Phase 4 will replace it with one that calls
-- evaluate_event_rules and triggers fine creation. For now it just sets status
-- and (if rotation enabled) auto-rolls the next event.
create or replace function public.close_event(p_event_id uuid)
returns public.events
language plpgsql security definer set search_path = public as $$
declare
  e public.events;
  next_id uuid;
begin
  select * into e from public.events where id = p_event_id;
  if not found then raise exception 'event not found'; end if;
  if not public.is_group_admin(e.group_id, auth.uid()) then raise exception 'admin only'; end if;

  update public.events set status = 'completed' where id = p_event_id returning * into e;

  -- Idempotent: only roll if not already rolled
  next_id := public.roll_event_series(p_event_id);
  return e;
end;
$$;
revoke execute on function public.close_event(uuid) from public, anon;
grant  execute on function public.close_event(uuid) to authenticated;

-- roll_event_series: creates the next event after p_event_id, if the group has
-- recurrence configured (default_day_of_week + rotation_enabled). Idempotent
-- via parent_event_id (only creates a child if none exists).
create or replace function public.roll_event_series(p_event_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  e public.events;
  g public.groups;
  v_next timestamptz;
  v_next_id uuid;
begin
  select * into e from public.events where id = p_event_id;
  if not found then return null; end if;
  select * into g from public.groups where id = e.group_id;

  -- Only roll if rotation is enabled and the group has a default day
  if not g.rotation_enabled or g.default_day_of_week is null then return null; end if;

  -- Idempotency: if a child already exists, return it
  select id into v_next_id from public.events where parent_event_id = p_event_id limit 1;
  if v_next_id is not null then return v_next_id; end if;

  -- Compute next event date: same time + 7 days from current event
  -- (uses group timezone for day-of-week math; trigger set_auto_no_show_at recomputes auto_no_show_at)
  v_next := (e.starts_at at time zone g.timezone + interval '7 days') at time zone g.timezone;

  -- Insert next event (status defaults to 'scheduled'). Host is intentionally
  -- null here — Phase 3 will refine this with proper next-host computation
  -- (next_host_for_group RPC already exists in 00003).
  insert into public.events (group_id, starts_at, location, cycle_number, parent_event_id, rsvp_deadline, created_by)
  values (
    e.group_id,
    v_next,
    g.default_location,
    coalesce(e.cycle_number, 0) + 1,
    e.id,
    v_next - interval '24 hours',
    e.created_by
  )
  returning id into v_next_id;

  -- Pre-create attendance rows for all active members
  insert into public.event_attendance (event_id, user_id)
  select v_next_id, gm.user_id
  from public.group_members gm
  where gm.group_id = e.group_id and gm.active
  on conflict do nothing;

  return v_next_id;
end;
$$;
revoke execute on function public.roll_event_series(uuid) from public, anon;
grant  execute on function public.roll_event_series(uuid) to authenticated;
