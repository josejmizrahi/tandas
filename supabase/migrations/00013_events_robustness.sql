-- =========================================================
-- Migration 00013 — Events Robustness V1
--
-- Adds capacity + plus-ones + waitlist to events / event_attendance
-- and 2 new RPCs (set_rsvp_v2, promote_from_waitlist).
--
-- Aditiva, idempotente. Rollback in 00013_rollback.sql.
-- =========================================================

-- =========================================================
-- 1. events: capacity + plus-ones config (host-controlled)
-- =========================================================
alter table public.events
  add column if not exists capacity_max int
    check (capacity_max is null or capacity_max > 0),
  add column if not exists allow_plus_ones boolean not null default false,
  add column if not exists max_plus_ones_per_member int not null default 0
    check (max_plus_ones_per_member >= 0 and max_plus_ones_per_member <= 10);

-- =========================================================
-- 2. event_attendance: plus_ones count + waitlist
-- =========================================================

-- Drop the existing rsvp_status check so we can extend the allowed values
-- to include 'waitlisted'.
alter table public.event_attendance
  drop constraint if exists event_attendance_rsvp_status_check;
alter table public.event_attendance
  add constraint event_attendance_rsvp_status_check
  check (rsvp_status in ('pending','going','maybe','declined','waitlisted'));

alter table public.event_attendance
  add column if not exists plus_ones int not null default 0
    check (plus_ones >= 0 and plus_ones <= 10),
  add column if not exists waitlist_position int;

create index if not exists idx_attendance_waitlist
  on public.event_attendance(event_id, waitlist_position)
  where rsvp_status = 'waitlisted';

-- =========================================================
-- 3. Helper — current confirmed seat count (going + plus_ones)
-- =========================================================
create or replace function public.event_seat_count(p_event_id uuid)
returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(1 + plus_ones), 0)::int
  from public.event_attendance
  where event_id = p_event_id and rsvp_status = 'going';
$$;

grant execute on function public.event_seat_count(uuid) to authenticated;

-- =========================================================
-- 4. set_rsvp_v2 — extends set_rsvp with plus_ones + auto-waitlist
-- =========================================================
create or replace function public.set_rsvp_v2(
  p_event_id uuid,
  p_status text,
  p_plus_ones int default 0,
  p_reason text default null
) returns public.event_attendance
language plpgsql security definer set search_path = public as $$
declare
  e public.events;
  att public.event_attendance;
  v_uid uuid := auth.uid();
  v_seats_taken int;
  v_max_plus_ones int;
  v_effective_status text := p_status;
  v_next_position int;
begin
  if v_uid is null then raise exception 'auth required'; end if;
  if p_status not in ('pending','going','maybe','declined') then
    raise exception 'invalid rsvp_status: %', p_status;
  end if;
  if p_plus_ones < 0 then raise exception 'plus_ones must be >= 0'; end if;

  select * into e from public.events where id = p_event_id;
  if not found then raise exception 'event not found'; end if;
  if not public.is_group_member(e.group_id, v_uid) then raise exception 'not a member'; end if;

  -- Validate plus-ones policy on the event.
  if p_plus_ones > 0 then
    if not e.allow_plus_ones then raise exception 'plus_ones not allowed'; end if;
    v_max_plus_ones := coalesce(e.max_plus_ones_per_member, 0);
    if p_plus_ones > v_max_plus_ones then
      raise exception 'plus_ones exceeds max % per member', v_max_plus_ones;
    end if;
  end if;

  -- Capacity check on 'going' transitions: if at/over capacity, push to
  -- waitlist instead. Members already in 'going' can update plus_ones up
  -- to capacity; transitions away from 'going' free seats.
  if p_status = 'going' and e.capacity_max is not null then
    v_seats_taken := public.event_seat_count(p_event_id);
    -- Subtract this member's current going seats so re-confirming with
    -- different plus_ones doesn't double-count.
    select coalesce(1 + plus_ones, 0) into v_seats_taken
      from (select v_seats_taken - coalesce((
        select 1 + plus_ones from public.event_attendance
        where event_id = p_event_id and user_id = v_uid and rsvp_status = 'going'
      ), 0) as plus_ones) sub;
    -- Safe re-compute (the inline subquery above is awkward; simpler):
    v_seats_taken := public.event_seat_count(p_event_id);
    declare v_my_existing int := 0;
    begin
      select 1 + plus_ones into v_my_existing
        from public.event_attendance
        where event_id = p_event_id and user_id = v_uid and rsvp_status = 'going';
    exception when no_data_found then
      v_my_existing := 0;
    end;
    v_seats_taken := v_seats_taken - v_my_existing;
    if (v_seats_taken + 1 + p_plus_ones) > e.capacity_max then
      v_effective_status := 'waitlisted';
      select coalesce(max(waitlist_position), 0) + 1 into v_next_position
        from public.event_attendance
        where event_id = p_event_id and rsvp_status = 'waitlisted';
    end if;
  end if;

  -- Upsert attendance row. cancelled_reason is set on declined transitions
  -- only; cleared otherwise.
  insert into public.event_attendance (
    event_id, user_id, rsvp_status, rsvp_at, plus_ones,
    waitlist_position, cancelled_reason
  ) values (
    p_event_id, v_uid, v_effective_status, now(), p_plus_ones,
    case when v_effective_status = 'waitlisted' then v_next_position else null end,
    case when v_effective_status = 'declined' then p_reason else null end
  )
  on conflict (event_id, user_id) do update set
    rsvp_status       = excluded.rsvp_status,
    rsvp_at           = now(),
    plus_ones         = excluded.plus_ones,
    waitlist_position = excluded.waitlist_position,
    cancelled_reason  = excluded.cancelled_reason
  returning * into att;

  return att;
end;
$$;

revoke execute on function public.set_rsvp_v2(uuid, text, int, text) from public, anon;
grant execute on function public.set_rsvp_v2(uuid, text, int, text) to authenticated;

-- =========================================================
-- 5. promote_from_waitlist — host promotes earliest waitlisted to going
-- =========================================================
create or replace function public.promote_from_waitlist(p_event_id uuid)
returns public.event_attendance
language plpgsql security definer set search_path = public as $$
declare
  e public.events;
  next_att public.event_attendance;
  v_uid uuid := auth.uid();
  v_seats_taken int;
  v_seats_needed int;
begin
  select * into e from public.events where id = p_event_id;
  if not found then raise exception 'event not found'; end if;
  if not (public.is_group_admin(e.group_id, v_uid) or e.host_id = v_uid) then
    raise exception 'host or admin only';
  end if;

  -- Find earliest waitlisted member.
  select * into next_att
    from public.event_attendance
    where event_id = p_event_id and rsvp_status = 'waitlisted'
    order by waitlist_position asc, rsvp_at asc
    limit 1;
  if not found then raise exception 'no one on waitlist'; end if;

  v_seats_taken := public.event_seat_count(p_event_id);
  v_seats_needed := 1 + next_att.plus_ones;
  if e.capacity_max is not null and (v_seats_taken + v_seats_needed) > e.capacity_max then
    raise exception 'not enough capacity to promote (taken: %, needed: %, max: %)',
      v_seats_taken, v_seats_needed, e.capacity_max;
  end if;

  update public.event_attendance
    set rsvp_status = 'going', waitlist_position = null, rsvp_at = now()
    where id = next_att.id
    returning * into next_att;
  return next_att;
end;
$$;

revoke execute on function public.promote_from_waitlist(uuid) from public, anon;
grant execute on function public.promote_from_waitlist(uuid) to authenticated;
