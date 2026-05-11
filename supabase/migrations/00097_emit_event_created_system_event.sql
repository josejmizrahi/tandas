-- 00097 — Emit `eventCreated` from inside create_event_v2.
--
-- Today create_event_v2 inserts events + event_attendance and relies
-- on the dual-write trigger to mirror to resources. Nothing emits
-- `eventCreated` to system_events, so an event's first activity row
-- only lands when someone RSVPs / checks in / gets fined. The
-- ActivitySectionView in iOS therefore reads "Aún no hay actividad"
-- on every freshly-created event (and on 3 of 6 prod events that
-- never moved past creation).
--
-- The eventCreated case is already in `is_known_system_event_type`
-- (mig 00092 whitelist) and has no rule engine evaluator — it's a
-- "memory only" atom. Payload carries title + starts_at + host_id
-- so ActivitySectionView can render a human row without a join.
--
-- The auth model: create_event_v2 is SECURITY DEFINER but auth.uid()
-- inside still returns the caller (the calling user). The
-- membership check at the top of create_event_v2 already gates this
-- to active group members, so the record_system_event membership
-- gate added in 00094 will pass.

create or replace function public.create_event_v2(
  p_group_id              uuid,
  p_title                 text,
  p_starts_at             timestamp with time zone,
  p_duration_minutes      integer default 180,
  p_location_name         text default null,
  p_location_lat          numeric default null,
  p_location_lng          numeric default null,
  p_host_id               uuid default null,
  p_cover_image_name      text default null,
  p_cover_image_url       text default null,
  p_description           text default null,
  p_apply_rules           boolean default true,
  p_is_recurring_generated boolean default false
) returns public.events
language plpgsql security definer set search_path = public as $$
declare
  e               public.events;
  g               public.groups;
  v_cycle         int;
  v_host          uuid;
  v_ends_at       timestamptz;
  v_rotation_on   boolean;
begin
  if not public.is_group_member(p_group_id, auth.uid()) then
    raise exception 'forbidden: not a member of group';
  end if;

  select * into g from public.groups where id = p_group_id;
  if not found then
    raise exception 'group not found';
  end if;

  v_cycle := coalesce(
    (select max(cycle_number) from public.events where group_id = p_group_id),
    0
  ) + 1;

  v_rotation_on := coalesce(
    (select 'rotating_host' = any (
       select jsonb_array_elements_text(g.active_modules)
     )),
    false
  );

  v_host := coalesce(
    p_host_id,
    case when v_rotation_on
         then public.next_host_for_group(p_group_id, v_cycle)
         else null
    end,
    auth.uid()
  );

  v_ends_at := p_starts_at + make_interval(mins => coalesce(p_duration_minutes, 180));

  insert into public.events (
    group_id, title, starts_at, ends_at, location, location_lat, location_lng,
    host_id, cycle_number, rsvp_deadline, cover_image_name, cover_image_url,
    description, apply_rules, is_recurring_generated, duration_minutes, created_by
  ) values (
    p_group_id, p_title, p_starts_at, v_ends_at,
    p_location_name, p_location_lat, p_location_lng,
    v_host, v_cycle, p_starts_at - interval '4 hours',
    p_cover_image_name, p_cover_image_url, p_description,
    coalesce(p_apply_rules, true), coalesce(p_is_recurring_generated, false),
    coalesce(p_duration_minutes, 180), auth.uid()
  ) returning * into e;

  insert into public.event_attendance (event_id, user_id)
    select e.id, gm.user_id
      from public.group_members gm
     where gm.group_id = p_group_id and gm.active
    on conflict do nothing;

  -- Memory atom: give the event a baseline activity entry so
  -- ActivitySectionView has something to render from day 1. No rule
  -- engine evaluator binds to eventCreated today — it's purely for
  -- the timeline. Payload kept compact and human-renderable.
  perform public.record_system_event(
    p_group_id,
    'eventCreated',
    e.id,
    null,
    jsonb_build_object(
      'title',     e.title,
      'starts_at', e.starts_at,
      'host_id',   e.host_id
    )
  );

  return e;
end;
$$;

comment on function public.create_event_v2 is
  'Event creation post-BigBang (mig 00080). Rotation gating reads groups.active_modules. Emits eventCreated to system_events (00097) so ActivitySectionView has a baseline row from day 1.';
