-- F.EVENT.10 — configurable host rotation order.
-- Founder doctrine 2026-06-04: "como configuro el orden de los hosts?"
--
-- host_rotation_order es UUID[] opcional en cada evento. Si está nil, la
-- rotación usa la lógica natural (joined_at ASC); si tiene valores, la
-- rotación los respeta cíclicamente. Se propaga a la siguiente ocurrencia
-- en close_event como cualquier otro campo de serie.

alter table public.calendar_events
  add column if not exists host_rotation_order uuid[];

-- preview_next_host extended (configured order wins over join-order)
create or replace function public.preview_next_host(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public', 'auth'
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_event public.calendar_events%rowtype;
  v_override uuid;
  v_next_actor uuid;
  v_name text;
  v_source text;
  v_reason text;
  v_rule text;
  v_pos integer;
  v_len integer;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_event from public.calendar_events where id = p_event_id;
  if v_event.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if not public.is_context_member(v_event.context_actor_id, v_caller) then
    raise exception 'not authorized to preview next host' using errcode = '42501';
  end if;

  v_override := nullif(v_event.metadata->>'next_host_override_actor_id', '')::uuid;
  v_rule := lower(btrim(coalesce(v_event.recurrence_rule, '')));

  if v_override is not null and exists (
    select 1 from public.actor_memberships
    where context_actor_id = v_event.context_actor_id
      and member_actor_id = v_override
      and membership_status = 'active'
  ) then
    v_next_actor := v_override;
    v_source := 'override';
    v_reason := 'manual override';
  elsif v_rule in ('weekly', 'freq=weekly') then
    if v_event.host_rotation_order is not null
       and array_length(v_event.host_rotation_order, 1) > 0 then
      v_len := array_length(v_event.host_rotation_order, 1);
      v_pos := array_position(v_event.host_rotation_order, v_event.host_actor_id);
      if v_pos is null then
        v_next_actor := v_event.host_rotation_order[1];
      else
        v_next_actor := v_event.host_rotation_order[(v_pos % v_len) + 1];
      end if;
      v_source := 'rotation';
      v_reason := 'next in configured rotation';
    else
      select am.member_actor_id into v_next_actor
        from public.actor_memberships am
       where am.context_actor_id = v_event.context_actor_id and am.membership_status = 'active'
       order by (am.member_actor_id = v_event.host_actor_id) desc, am.joined_at, am.member_actor_id
       offset 1 limit 1;
      v_next_actor := coalesce(v_next_actor, v_event.host_actor_id);
      v_source := 'rotation';
      v_reason := 'next participant in rotation';
    end if;
  elsif v_rule in ('daily', 'freq=daily', 'monthly', 'freq=monthly', 'yearly', 'freq=yearly') then
    v_next_actor := v_event.host_actor_id;
    v_source := 'rotation';
    v_reason := 'same host (no rotation for this frequency)';
  else
    return jsonb_build_object(
      'next_actor_id', null, 'next_actor_name', null, 'source', null,
      'reason', 'event is not recurring');
  end if;

  select a.display_name into v_name from public.actors a where a.id = v_next_actor;

  return jsonb_build_object(
    'next_actor_id', v_next_actor,
    'next_actor_name', v_name,
    'source', v_source,
    'reason', v_reason);
end; $$;

-- close_event respects configured rotation order + propagates to next occurrence
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
  v_pos integer;
  v_len integer;
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
          if v_event.host_rotation_order is not null
             and array_length(v_event.host_rotation_order, 1) > 0 then
            v_len := array_length(v_event.host_rotation_order, 1);
            v_pos := array_position(v_event.host_rotation_order, v_event.host_actor_id);
            if v_pos is null then
              v_next_host := v_event.host_rotation_order[1];
            else
              v_next_host := v_event.host_rotation_order[(v_pos % v_len) + 1];
            end if;
            v_source := 'rotation_configured';
          else
            select am.member_actor_id into v_next_host
              from public.actor_memberships am
             where am.context_actor_id = v_event.context_actor_id and am.membership_status = 'active'
             order by (am.member_actor_id = v_event.host_actor_id) desc, am.joined_at, am.member_actor_id
             offset 1 limit 1;
            v_next_host := coalesce(v_next_host, v_event.host_actor_id);
            v_source := 'rotation';
          end if;
        else
          v_next_host := v_event.host_actor_id;
          v_source := 'same_host';
        end if;

        v_series_id := coalesce(v_event.series_id, v_event.id);

        insert into public.calendar_events
          (context_actor_id, title, description, event_type, starts_at, ends_at, timezone,
           location_text, recurrence_rule, host_actor_id, metadata, created_by_actor_id, is_virtual,
           series_id, previous_event_id,
           recurrence_count, recurrence_until, occurrence_number,
           host_rotation_order)
        values
          (v_event.context_actor_id, v_event.title, v_event.description, v_event.event_type,
           v_next_start, v_next_start + coalesce(v_event.ends_at - v_event.starts_at, interval '2 hours'),
           v_event.timezone, v_event.location_text, v_event.recurrence_rule, v_next_host,
           (coalesce(v_event.metadata, '{}'::jsonb) - 'next_host_override_actor_id')
             || jsonb_build_object('previous_event_id', p_event_id),
           v_event.created_by_actor_id, v_event.is_virtual,
           v_series_id, p_event_id,
           v_event.recurrence_count, v_event.recurrence_until, v_event.occurrence_number + 1,
           v_event.host_rotation_order)
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

-- set_host_rotation_order(event_id, actor_ids) — admin reorders the cycle.
-- Passing NULL clears the order and falls back to natural rotation.
create or replace function public.set_host_rotation_order(p_event_id uuid, p_actor_ids uuid[])
returns jsonb language plpgsql security definer set search_path to 'public', 'auth'
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_event public.calendar_events%rowtype;
  v_actor_id uuid;
  v_unique_count integer;
  v_total_count integer;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_event from public.calendar_events where id = p_event_id;
  if v_event.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_event.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized to set rotation order' using errcode = '42501';
  end if;

  if p_actor_ids is null or array_length(p_actor_ids, 1) is null then
    update public.calendar_events set host_rotation_order = null where id = p_event_id;
    perform public._emit_activity(v_event.context_actor_id, v_caller, 'event.host_rotation_cleared',
      'calendar_event', p_event_id, jsonb_build_object('title', v_event.title));
    return jsonb_build_object('event_id', p_event_id, 'cleared', true);
  end if;

  v_total_count := array_length(p_actor_ids, 1);
  select count(distinct x) into v_unique_count from unnest(p_actor_ids) x;
  if v_unique_count <> v_total_count then
    raise exception 'duplicate actor in rotation order' using errcode = '22023';
  end if;

  foreach v_actor_id in array p_actor_ids loop
    if not exists (
      select 1 from public.actor_memberships
      where context_actor_id = v_event.context_actor_id
        and member_actor_id = v_actor_id
        and membership_status = 'active'
    ) then
      raise exception 'actor % is not an active member of the context', v_actor_id using errcode = '22023';
    end if;
  end loop;

  update public.calendar_events
     set host_rotation_order = p_actor_ids
   where id = p_event_id;

  perform public._emit_activity(v_event.context_actor_id, v_caller, 'event.host_rotation_set',
    'calendar_event', p_event_id,
    jsonb_build_object('title', v_event.title, 'order_count', v_total_count));

  return jsonb_build_object(
    'event_id', p_event_id,
    'host_rotation_order', to_jsonb(p_actor_ids),
    'cleared', false);
end; $$;

revoke all on function public.preview_next_host(uuid) from public, anon;
grant execute on function public.preview_next_host(uuid) to authenticated, service_role;

revoke all on function public.close_event(uuid) from public, anon;
grant execute on function public.close_event(uuid) to authenticated, service_role;

revoke all on function public.set_host_rotation_order(uuid, uuid[]) from public, anon;
grant execute on function public.set_host_rotation_order(uuid, uuid[]) to authenticated, service_role;
