-- F.EVENT.9 — bounded recurring series.
-- Founder doctrine 2026-06-04: "yo debería de poder crear una serie de eventos
-- con recurrencia o establecer el numero de eventos y ponerles fecha".
--
-- Opción A (lazy + bounded): la serie sigue creándose evento-por-evento al
-- cerrar el anterior, pero ahora puede acotarse por count o end-date.

-- 1. Columnas nuevas.
alter table public.calendar_events
  add column if not exists recurrence_count integer,
  add column if not exists recurrence_until timestamptz,
  add column if not exists occurrence_number integer not null default 1;

update public.calendar_events
   set occurrence_number = 1
 where occurrence_number is null;

alter table public.calendar_events
  drop constraint if exists calendar_events_recurrence_count_positive;
alter table public.calendar_events
  add constraint calendar_events_recurrence_count_positive
  check (recurrence_count is null or recurrence_count > 0);

alter table public.calendar_events
  drop constraint if exists calendar_events_occurrence_number_positive;
alter table public.calendar_events
  add constraint calendar_events_occurrence_number_positive
  check (occurrence_number > 0);

alter table public.calendar_events
  drop constraint if exists calendar_events_bounds_require_recurrence;
alter table public.calendar_events
  add constraint calendar_events_bounds_require_recurrence
  check (
    (recurrence_count is null and recurrence_until is null)
    or recurrence_rule is not null
  );

-- ============= create_calendar_event extended =============
drop function if exists public.create_calendar_event(
  uuid, text, text, timestamptz, timestamptz, text, text, text, text, uuid, boolean, jsonb, text, boolean
);

create or replace function public.create_calendar_event(
  p_context_actor_id uuid,
  p_title text,
  p_event_type text,
  p_starts_at timestamptz,
  p_ends_at timestamptz default null,
  p_description text default null,
  p_timezone text default 'America/Mexico_City',
  p_location_text text default null,
  p_recurrence_rule text default null,
  p_host_actor_id uuid default null,
  p_invite_all_members boolean default true,
  p_metadata jsonb default '{}'::jsonb,
  p_client_id text default null,
  p_is_virtual boolean default false,
  p_recurrence_count integer default null,
  p_recurrence_until timestamptz default null
) returns jsonb
language plpgsql security definer set search_path to 'public', 'auth'
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_id uuid;
  v_existing uuid;
  v_location text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'events.create') then
    raise exception 'not authorized to create events in context %', p_context_actor_id using errcode = '42501';
  end if;

  v_location := nullif(btrim(coalesce(p_location_text, '')), '');
  if not p_is_virtual and v_location is null then
    raise exception 'location_required: events must have a location unless marked as virtual'
      using errcode = '22023';
  end if;

  if (p_recurrence_count is not null or p_recurrence_until is not null)
     and p_recurrence_rule is null then
    raise exception 'recurrence bounds require recurrence_rule' using errcode = '22023';
  end if;
  if p_recurrence_count is not null and p_recurrence_count <= 0 then
    raise exception 'recurrence_count must be positive' using errcode = '22023';
  end if;
  if p_recurrence_until is not null and p_recurrence_until <= p_starts_at then
    raise exception 'recurrence_until must be after starts_at' using errcode = '22023';
  end if;

  if p_client_id is not null then
    select id into v_existing from public.calendar_events
     where context_actor_id = p_context_actor_id and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('event_id', v_existing,
        'event', (select to_jsonb(e) from public.calendar_events e where e.id = v_existing));
    end if;
  end if;

  insert into public.calendar_events
    (context_actor_id, title, description, event_type, starts_at, ends_at, timezone,
     location_text, recurrence_rule, host_actor_id, metadata, client_id, created_by_actor_id,
     is_virtual, recurrence_count, recurrence_until, occurrence_number)
  values
    (p_context_actor_id, btrim(p_title), p_description, p_event_type, p_starts_at, p_ends_at, p_timezone,
     v_location, p_recurrence_rule, coalesce(p_host_actor_id, v_caller),
     coalesce(p_metadata, '{}'::jsonb), p_client_id, v_caller,
     p_is_virtual, p_recurrence_count, p_recurrence_until, 1)
  returning id into v_id;

  update public.calendar_events set series_id = v_id where id = v_id and series_id is null;

  if p_invite_all_members and p_context_actor_id <> v_caller then
    insert into public.event_participants (event_id, participant_actor_id, status)
    select v_id, am.member_actor_id, 'invited'
      from public.actor_memberships am
     where am.context_actor_id = p_context_actor_id and am.membership_status = 'active'
    on conflict (event_id, participant_actor_id) do nothing;
  else
    insert into public.event_participants (event_id, participant_actor_id, status, rsvp_at)
    values (v_id, v_caller, 'going', now())
    on conflict (event_id, participant_actor_id) do nothing;
  end if;

  perform public._emit_activity(p_context_actor_id, v_caller, 'event.created', 'calendar_event', v_id,
    jsonb_build_object('title', btrim(p_title), 'event_type', p_event_type, 'starts_at', p_starts_at,
                       'is_virtual', p_is_virtual,
                       'recurrence_count', p_recurrence_count,
                       'recurrence_until', p_recurrence_until));

  return jsonb_build_object('event_id', v_id,
    'event', (select to_jsonb(e) from public.calendar_events e where e.id = v_id),
    'participants', (select count(*) from public.event_participants where event_id = v_id));
end; $$;

revoke all on function public.create_calendar_event(
  uuid, text, text, timestamptz, timestamptz, text, text, text, text, uuid, boolean, jsonb, text, boolean,
  integer, timestamptz
) from public, anon;
grant execute on function public.create_calendar_event(
  uuid, text, text, timestamptz, timestamptz, text, text, text, text, uuid, boolean, jsonb, text, boolean,
  integer, timestamptz
) to authenticated, service_role;

-- ============= close_event respects bounds =============
create or replace function public.close_event(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public', 'auth'
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_event public.calendar_events%rowtype;
  v_next_id uuid;
  v_next_start timestamptz;
  v_next_host uuid;
  v_next_host_name text;
  v_override uuid;
  v_no_shows integer;
  v_rule text;
  v_interval interval;
  v_rotate_host boolean;
  v_series_id uuid;
  v_source text;
  v_should_create_next boolean := true;
  v_series_completed boolean := false;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_event from public.calendar_events where id = p_event_id for update;
  if v_event.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_event.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized to close event' using errcode = '42501';
  end if;
  if v_event.status = 'completed' then
    return jsonb_build_object(
      'closed_event_id', p_event_id, 'event_id', p_event_id,
      'status', 'completed', 'already_closed', true,
      'next_event_id', v_event.next_event_id);
  end if;

  update public.event_participants
     set status = 'no_show'
   where event_id = p_event_id and status in ('going', 'invited', 'maybe') and checked_in_at is null;
  get diagnostics v_no_shows = row_count;

  update public.calendar_events set status = 'completed' where id = p_event_id;

  if v_event.recurrence_rule is not null then
    v_rule := lower(btrim(v_event.recurrence_rule));
    v_interval := case
      when v_rule in ('daily',   'freq=daily')   then interval '1 day'
      when v_rule in ('weekly',  'freq=weekly')  then interval '7 days'
      when v_rule in ('monthly', 'freq=monthly') then interval '1 month'
      when v_rule in ('yearly',  'freq=yearly')  then interval '1 year'
      else null
    end;
    v_rotate_host := v_rule in ('weekly', 'freq=weekly');

    if v_interval is not null then
      v_next_start := v_event.starts_at + v_interval;

      if v_event.recurrence_count is not null
         and v_event.occurrence_number >= v_event.recurrence_count then
        v_should_create_next := false;
        v_series_completed := true;
      end if;
      if v_event.recurrence_until is not null
         and v_next_start > v_event.recurrence_until then
        v_should_create_next := false;
        v_series_completed := true;
      end if;

      if v_should_create_next then
        v_override := nullif(v_event.metadata->>'next_host_override_actor_id', '')::uuid;
        if v_override is not null and exists (
          select 1 from public.actor_memberships
          where context_actor_id = v_event.context_actor_id
            and member_actor_id = v_override
            and membership_status = 'active'
        ) then
          v_next_host := v_override;
          v_source := 'override';
        elsif v_rotate_host then
          select am.member_actor_id into v_next_host
            from public.actor_memberships am
           where am.context_actor_id = v_event.context_actor_id and am.membership_status = 'active'
           order by (am.member_actor_id = v_event.host_actor_id) desc, am.joined_at, am.member_actor_id
           offset 1 limit 1;
          v_next_host := coalesce(v_next_host, v_event.host_actor_id);
          v_source := 'rotation';
        else
          v_next_host := v_event.host_actor_id;
          v_source := 'same_host';
        end if;

        v_series_id := coalesce(v_event.series_id, v_event.id);

        insert into public.calendar_events
          (context_actor_id, title, description, event_type, starts_at, ends_at, timezone,
           location_text, recurrence_rule, host_actor_id, metadata, created_by_actor_id, is_virtual,
           series_id, previous_event_id,
           recurrence_count, recurrence_until, occurrence_number)
        values
          (v_event.context_actor_id, v_event.title, v_event.description, v_event.event_type,
           v_next_start, v_next_start + coalesce(v_event.ends_at - v_event.starts_at, interval '2 hours'),
           v_event.timezone, v_event.location_text, v_event.recurrence_rule, v_next_host,
           (coalesce(v_event.metadata, '{}'::jsonb) - 'next_host_override_actor_id')
             || jsonb_build_object('previous_event_id', p_event_id),
           v_event.created_by_actor_id, v_event.is_virtual,
           v_series_id, p_event_id,
           v_event.recurrence_count, v_event.recurrence_until, v_event.occurrence_number + 1)
        returning id into v_next_id;

        update public.calendar_events
           set series_id = v_series_id,
               next_event_id = v_next_id,
               metadata = coalesce(metadata, '{}'::jsonb) - 'next_host_override_actor_id'
         where id = p_event_id;

        insert into public.event_participants (event_id, participant_actor_id, status)
        select v_next_id, am.member_actor_id, 'invited'
          from public.actor_memberships am
         where am.context_actor_id = v_event.context_actor_id and am.membership_status = 'active'
        on conflict do nothing;

        perform public._emit_activity(v_event.context_actor_id, v_caller, 'event.next_occurrence_created',
          'calendar_event', v_next_id,
          jsonb_build_object('previous_event_id', p_event_id, 'host_actor_id', v_next_host,
                             'starts_at', v_next_start, 'series_id', v_series_id, 'source', v_source,
                             'occurrence_number', v_event.occurrence_number + 1));
      end if;
    end if;
  end if;

  update public.calendar_events
     set metadata = coalesce(metadata, '{}'::jsonb) - 'next_host_override_actor_id'
   where id = p_event_id;

  if v_next_host is not null then
    select a.display_name into v_next_host_name from public.actors a where a.id = v_next_host;
  end if;

  perform public._emit_activity(v_event.context_actor_id, v_caller, 'event.closed', 'calendar_event', p_event_id,
    jsonb_build_object('no_shows', v_no_shows, 'next_event_id', v_next_id, 'next_host_actor_id', v_next_host,
                       'series_completed', v_series_completed));

  if v_series_completed then
    perform public._emit_activity(v_event.context_actor_id, v_caller, 'event.series_completed',
      'calendar_event', p_event_id,
      jsonb_build_object('series_id', coalesce(v_event.series_id, v_event.id),
                         'occurrence_number', v_event.occurrence_number,
                         'recurrence_count', v_event.recurrence_count,
                         'recurrence_until', v_event.recurrence_until));
  end if;

  return jsonb_build_object(
    'closed_event_id', p_event_id, 'event_id', p_event_id,
    'status', 'completed', 'no_shows', v_no_shows,
    'next_event_id', v_next_id, 'next_host_actor_id', v_next_host,
    'next_host_name', v_next_host_name, 'next_starts_at', v_next_start,
    'series_completed', v_series_completed);
end; $$;

revoke all on function public.close_event(uuid) from public, anon;
grant execute on function public.close_event(uuid) to authenticated, service_role;
