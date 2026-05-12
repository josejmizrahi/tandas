-- Rollback 00126 — restore pre-Tier-1 events schema and dual-write.
-- Drops series_id on events + indices + generated_until on
-- resource_series + reverts create_event_v2 to its 00097 signature.
-- Existing rows with non-null series_id silently lose that linkage on
-- the column drop (the column itself goes away).

alter table public.events drop column if exists series_id;
alter table public.resource_series drop column if exists generated_until;

-- Restore the 00039 trigger function body (without series_id mirror).
create or replace function public.sync_event_to_resource()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if TG_OP = 'DELETE' then
    delete from public.resources where id = OLD.id;
    return OLD;
  end if;
  insert into public.resources (
    id, group_id, resource_type, status, metadata,
    created_by, created_at, updated_at
  ) values (
    NEW.id, NEW.group_id, 'event', NEW.status,
    jsonb_build_object(
      'title', NEW.title, 'cover_image_name', NEW.cover_image_name,
      'cover_image_url', NEW.cover_image_url, 'description', NEW.description,
      'starts_at', NEW.starts_at, 'ends_at', NEW.ends_at,
      'duration_minutes', NEW.duration_minutes, 'location_name', NEW.location,
      'location_lat', NEW.location_lat, 'location_lng', NEW.location_lng,
      'host_id', NEW.host_id, 'cycle_number', NEW.cycle_number,
      'rsvp_deadline', NEW.rsvp_deadline, 'rules_evaluated_at', NEW.rules_evaluated_at,
      'notes', NEW.notes, 'apply_rules', NEW.apply_rules,
      'is_recurring_generated', NEW.is_recurring_generated,
      'parent_event_id', NEW.parent_event_id, 'auto_no_show_at', NEW.auto_no_show_at,
      'closed_at', NEW.closed_at, 'cancellation_reason', NEW.cancellation_reason,
      'capacity_max', NEW.capacity_max, 'allow_plus_ones', NEW.allow_plus_ones,
      'max_plus_ones_per_member', NEW.max_plus_ones_per_member
    ),
    NEW.created_by, NEW.created_at, NEW.updated_at
  )
  on conflict (id) do update
  set group_id      = excluded.group_id,
      resource_type = excluded.resource_type,
      status        = excluded.status,
      metadata      = excluded.metadata,
      updated_at    = excluded.updated_at;
  return NEW;
end;
$$;

-- Restore create_event_v2 to the 00097 signature (no p_series_id, no
-- p_rsvp_deadline). Idempotency for cron-generated rows is removed.
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
  v_cycle := coalesce((select max(cycle_number) from public.events where group_id = p_group_id), 0) + 1;
  v_rotation_on := coalesce((select 'rotating_host' = any (select jsonb_array_elements_text(g.active_modules))), false);
  v_host := coalesce(p_host_id,
    case when v_rotation_on then public.next_host_for_group(p_group_id, v_cycle) else null end,
    auth.uid());
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
  perform public.record_system_event(p_group_id, 'eventCreated', e.id, null,
    jsonb_build_object('title', e.title, 'starts_at', e.starts_at, 'host_id', e.host_id));
  return e;
end;
$$;
