-- F.EVENT.8 — visible host rotation + linked occurrences + manual override.
--
-- Founder doctrine 2026-06-04:
-- 1. El próximo host se puede previsualizar antes del cierre.
-- 2. Admins pueden definir manualmente el siguiente host (override one-shot).
-- 3. close_event crea automáticamente la siguiente ocurrencia.
-- 4. Cero duplicados (SELECT FOR UPDATE + status check).
-- 5. Eventos vinculados por series_id / previous_event_id / next_event_id.

-- 1. New series linkage columns.
alter table public.calendar_events
  add column if not exists series_id uuid,
  add column if not exists previous_event_id uuid references public.calendar_events(id) on delete set null,
  add column if not exists next_event_id uuid references public.calendar_events(id) on delete set null;

update public.calendar_events
   set series_id = id
 where recurrence_rule is not null and series_id is null;

create index if not exists calendar_events_series_id_idx
  on public.calendar_events(series_id) where series_id is not null;
create index if not exists calendar_events_next_event_id_idx
  on public.calendar_events(next_event_id) where next_event_id is not null;

-- ============= preview_next_host(event_id) =============
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
    select am.member_actor_id into v_next_actor
      from public.actor_memberships am
     where am.context_actor_id = v_event.context_actor_id and am.membership_status = 'active'
     order by (am.member_actor_id = v_event.host_actor_id) desc, am.joined_at, am.member_actor_id
     offset 1 limit 1;
    v_next_actor := coalesce(v_next_actor, v_event.host_actor_id);
    v_source := 'rotation';
    v_reason := 'next participant in rotation';
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

-- ============= set_next_host(event_id, actor_id) =============
create or replace function public.set_next_host(p_event_id uuid, p_actor_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public', 'auth'
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_event public.calendar_events%rowtype;
  v_name text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_event from public.calendar_events where id = p_event_id;
  if v_event.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_event.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized to set next host' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.actor_memberships
    where context_actor_id = v_event.context_actor_id
      and member_actor_id = p_actor_id
      and membership_status = 'active'
  ) then
    raise exception 'actor is not an active member of the context' using errcode = '22023';
  end if;

  update public.calendar_events
     set metadata = coalesce(metadata, '{}'::jsonb)
                    || jsonb_build_object('next_host_override_actor_id', p_actor_id)
   where id = p_event_id;

  select a.display_name into v_name from public.actors a where a.id = p_actor_id;

  perform public._emit_activity(v_event.context_actor_id, v_caller, 'event.next_host_overridden',
    'calendar_event', p_event_id,
    jsonb_build_object('next_actor_id', p_actor_id, 'overridden_by', v_caller, 'title', v_event.title));

  return jsonb_build_object(
    'event_id', p_event_id,
    'next_actor_id', p_actor_id,
    'next_actor_name', v_name);
end; $$;

-- ============= close_event rewrite =============
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
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  -- Lock the row — la segunda llamada concurrente espera y al desbloquear ve status='completed'.
  select * into v_event from public.calendar_events where id = p_event_id for update;
  if v_event.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_event.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized to close event' using errcode = '42501';
  end if;
  if v_event.status = 'completed' then
    return jsonb_build_object(
      'closed_event_id', p_event_id,
      'event_id', p_event_id,
      'status', 'completed',
      'already_closed', true,
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
         series_id, previous_event_id)
      values
        (v_event.context_actor_id, v_event.title, v_event.description, v_event.event_type,
         v_next_start, v_next_start + coalesce(v_event.ends_at - v_event.starts_at, interval '2 hours'),
         v_event.timezone, v_event.location_text, v_event.recurrence_rule, v_next_host,
         (coalesce(v_event.metadata, '{}'::jsonb) - 'next_host_override_actor_id')
           || jsonb_build_object('previous_event_id', p_event_id),
         v_event.created_by_actor_id, v_event.is_virtual,
         v_series_id, p_event_id)
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
                           'starts_at', v_next_start, 'series_id', v_series_id, 'source', v_source));
    end if;
  end if;

  update public.calendar_events
     set metadata = coalesce(metadata, '{}'::jsonb) - 'next_host_override_actor_id'
   where id = p_event_id;

  if v_next_host is not null then
    select a.display_name into v_next_host_name from public.actors a where a.id = v_next_host;
  end if;

  perform public._emit_activity(v_event.context_actor_id, v_caller, 'event.closed', 'calendar_event', p_event_id,
    jsonb_build_object('no_shows', v_no_shows, 'next_event_id', v_next_id, 'next_host_actor_id', v_next_host));

  return jsonb_build_object(
    'closed_event_id', p_event_id,
    'event_id', p_event_id,
    'status', 'completed',
    'no_shows', v_no_shows,
    'next_event_id', v_next_id,
    'next_host_actor_id', v_next_host,
    'next_host_name', v_next_host_name,
    'next_starts_at', v_next_start);
end; $$;

-- ============= GRANTs =============
revoke all on function public.preview_next_host(uuid) from public, anon;
grant execute on function public.preview_next_host(uuid) to authenticated, service_role;

revoke all on function public.set_next_host(uuid, uuid) from public, anon;
grant execute on function public.set_next_host(uuid, uuid) to authenticated, service_role;

revoke all on function public.close_event(uuid) from public, anon;
grant execute on function public.close_event(uuid) to authenticated, service_role;
