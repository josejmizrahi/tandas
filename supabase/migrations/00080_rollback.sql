-- 00080 rollback — Restore the pre-BigBang create_event_v2 body.
--
-- After rollback the function tries to read g.rotation_enabled again,
-- which is gone post-mig-00078. Pair this rollback with a re-add of the
-- rotation_enabled column if you're truly walking back the OpenPlatform
-- foundation.

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
  e public.events;
  g public.groups;
  v_cycle int;
  v_host uuid;
  v_ends_at timestamptz;
begin
  if not public.is_group_member(p_group_id, auth.uid()) then
    raise exception 'not a member';
  end if;
  select * into g from public.groups where id = p_group_id;
  if not found then raise exception 'group not found'; end if;
  v_cycle := (select coalesce(max(cycle_number), 0) + 1
              from public.events where group_id = p_group_id);
  v_host := coalesce(
    p_host_id,
    case when g.rotation_enabled then public.next_host_for_group(p_group_id, v_cycle) else null end,
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
  return e;
end;
$$;
