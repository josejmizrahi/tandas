-- ============================================================================
-- MVP 2.0 — M.5 CALENDAR
-- ============================================================================
-- calendar_events + event_participants + RPCs: create_calendar_event / rsvp_event /
-- check_in_participant / cancel_participation / close_event (recurrencia + no-shows)
-- + RLS + smoke. La evaluación de reglas (multas por tarde/cancelación, host
-- rotativo) llega en M.7 y se engancha a check_in/cancel/close.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. calendar_events
-- ────────────────────────────────────────────────────────────────────────────
create table public.calendar_events (
  id uuid primary key default gen_random_uuid(),
  context_actor_id uuid not null references public.actors(id) on delete cascade,
  title text not null,
  description text,
  event_type text not null check (event_type in
    ('dinner', 'meeting', 'trip', 'game_night', 'community_event', 'deadline', 'other')),
  starts_at timestamptz,
  ends_at timestamptz,
  timezone text,
  location_text text,
  location_metadata jsonb not null default '{}',
  recurrence_rule text,
  host_actor_id uuid references public.actors(id),
  status text not null default 'scheduled' check (status in
    ('scheduled', 'in_progress', 'completed', 'cancelled')),
  metadata jsonb not null default '{}',
  client_id text,
  created_by_actor_id uuid references public.actors(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  cancelled_at timestamptz
);

create index idx_events_context on public.calendar_events (context_actor_id, starts_at desc);
create unique index idx_events_client_id on public.calendar_events (context_actor_id, client_id) where client_id is not null;

create trigger trg_events_touch before update on public.calendar_events
  for each row execute function public.touch_updated_at();

-- ────────────────────────────────────────────────────────────────────────────
-- 2. event_participants
-- ────────────────────────────────────────────────────────────────────────────
create table public.event_participants (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.calendar_events(id) on delete cascade,
  participant_actor_id uuid not null references public.actors(id) on delete cascade,
  status text not null default 'invited' check (status in
    ('invited', 'going', 'maybe', 'declined', 'cancelled', 'attended', 'late', 'no_show')),
  rsvp_at timestamptz,
  checked_in_at timestamptz,
  cancelled_at timestamptz,
  metadata jsonb not null default '{}',
  unique (event_id, participant_actor_id)
);

create index idx_participants_actor on public.event_participants (participant_actor_id);

-- ────────────────────────────────────────────────────────────────────────────
-- 3. RPCs
-- ────────────────────────────────────────────────────────────────────────────
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
  p_client_id text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_id uuid;
  v_existing uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'events.create') then
    raise exception 'not authorized to create events in context %', p_context_actor_id using errcode = '42501';
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
     location_text, recurrence_rule, host_actor_id, metadata, client_id, created_by_actor_id)
  values
    (p_context_actor_id, btrim(p_title), p_description, p_event_type, p_starts_at, p_ends_at, p_timezone,
     p_location_text, p_recurrence_rule, coalesce(p_host_actor_id, v_caller),
     coalesce(p_metadata, '{}'::jsonb), p_client_id, v_caller)
  returning id into v_id;

  -- Auto-invitar a los miembros activos del contexto (flujo cena MVP)
  if p_invite_all_members and p_context_actor_id <> v_caller then
    insert into public.event_participants (event_id, participant_actor_id, status)
    select v_id, am.member_actor_id, case when am.member_actor_id = v_caller then 'going' else 'invited' end
      from public.actor_memberships am
     where am.context_actor_id = p_context_actor_id and am.membership_status = 'active'
    on conflict (event_id, participant_actor_id) do nothing;
  else
    insert into public.event_participants (event_id, participant_actor_id, status, rsvp_at)
    values (v_id, v_caller, 'going', now())
    on conflict (event_id, participant_actor_id) do nothing;
  end if;

  perform public._emit_activity(p_context_actor_id, v_caller, 'event.created', 'calendar_event', v_id,
    jsonb_build_object('title', btrim(p_title), 'event_type', p_event_type, 'starts_at', p_starts_at));

  return jsonb_build_object('event_id', v_id,
    'event', (select to_jsonb(e) from public.calendar_events e where e.id = v_id),
    'participants', (select count(*) from public.event_participants where event_id = v_id));
end; $$;

revoke all on function public.create_calendar_event(uuid, text, text, timestamptz, timestamptz, text, text, text, text, uuid, boolean, jsonb, text) from public, anon;
grant execute on function public.create_calendar_event(uuid, text, text, timestamptz, timestamptz, text, text, text, text, uuid, boolean, jsonb, text) to authenticated, service_role;

-- rsvp_event: self-service
create or replace function public.rsvp_event(p_event_id uuid, p_status text)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_event public.calendar_events%rowtype;
  v_pid uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if p_status not in ('going', 'maybe', 'declined') then
    raise exception 'invalid rsvp status: %', p_status using errcode = '22023';
  end if;

  select * into v_event from public.calendar_events where id = p_event_id;
  if v_event.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if not public.is_context_member(v_event.context_actor_id) then
    raise exception 'not a member of event context' using errcode = '42501';
  end if;
  if v_event.status in ('completed', 'cancelled') then
    raise exception 'event already %', v_event.status using errcode = '22023';
  end if;

  insert into public.event_participants (event_id, participant_actor_id, status, rsvp_at)
  values (p_event_id, v_caller, p_status, now())
  on conflict (event_id, participant_actor_id)
  do update set status = excluded.status, rsvp_at = now(), cancelled_at = null
  returning id into v_pid;

  perform public._emit_activity(v_event.context_actor_id, v_caller, 'event.rsvp', 'event_participant', v_pid,
    jsonb_build_object('event_id', p_event_id, 'status', p_status));

  return jsonb_build_object('participant_id', v_pid, 'status', p_status);
end; $$;

revoke all on function public.rsvp_event(uuid, text) from public, anon;
grant execute on function public.rsvp_event(uuid, text) to authenticated, service_role;

-- check_in_participant: self o por un manager del evento
create or replace function public.check_in_participant(
  p_event_id uuid,
  p_participant_actor_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_target uuid := coalesce(p_participant_actor_id, public.current_actor_id());
  v_event public.calendar_events%rowtype;
  v_pid uuid;
  v_minutes_late numeric;
  v_status text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_event from public.calendar_events where id = p_event_id;
  if v_event.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;

  -- self check-in: ser miembro; check-in de terceros: events.manage
  if v_target <> v_caller
     and not public.has_actor_authority(v_event.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized to check in others' using errcode = '42501';
  end if;
  if v_target = v_caller and not public.is_context_member(v_event.context_actor_id) then
    raise exception 'not a member of event context' using errcode = '42501';
  end if;

  v_minutes_late := greatest(0, extract(epoch from (now() - v_event.starts_at)) / 60.0);
  v_status := case when v_minutes_late > 15 then 'late' else 'attended' end;

  insert into public.event_participants (event_id, participant_actor_id, status, checked_in_at)
  values (p_event_id, v_target, v_status, now())
  on conflict (event_id, participant_actor_id)
  do update set status = excluded.status, checked_in_at = now()
  returning id into v_pid;

  -- metadata para el rule engine (M.7): minutos tarde
  update public.event_participants
     set metadata = metadata || jsonb_build_object('minutes_late', round(v_minutes_late, 1))
   where id = v_pid;

  perform public._emit_activity(v_event.context_actor_id, v_target, 'event.checked_in', 'event_participant', v_pid,
    jsonb_build_object('event_id', p_event_id, 'minutes_late', round(v_minutes_late, 1), 'status', v_status));

  return jsonb_build_object('participant_id', v_pid, 'status', v_status, 'minutes_late', round(v_minutes_late, 1));
end; $$;

revoke all on function public.check_in_participant(uuid, uuid) from public, anon;
grant execute on function public.check_in_participant(uuid, uuid) to authenticated, service_role;

-- cancel_participation: self
create or replace function public.cancel_participation(p_event_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_event public.calendar_events%rowtype;
  v_pid uuid;
  v_same_day boolean;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_event from public.calendar_events where id = p_event_id;
  if v_event.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;

  v_same_day := v_event.starts_at is not null and v_event.starts_at::date = now()::date;

  insert into public.event_participants (event_id, participant_actor_id, status, cancelled_at)
  values (p_event_id, v_caller, 'cancelled', now())
  on conflict (event_id, participant_actor_id)
  do update set status = 'cancelled', cancelled_at = now()
  returning id into v_pid;

  -- metadata para el rule engine (M.7): cancelación same-day
  update public.event_participants
     set metadata = metadata || jsonb_build_object('same_day_cancellation', v_same_day)
   where id = v_pid;

  perform public._emit_activity(v_event.context_actor_id, v_caller, 'event.participation_cancelled', 'event_participant', v_pid,
    jsonb_build_object('event_id', p_event_id, 'same_day', v_same_day));

  return jsonb_build_object('participant_id', v_pid, 'same_day_cancellation', v_same_day);
end; $$;

revoke all on function public.cancel_participation(uuid) from public, anon;
grant execute on function public.cancel_participation(uuid) to authenticated, service_role;

-- close_event: marca completed + no-shows + genera siguiente instancia (recurrencia)
create or replace function public.close_event(p_event_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_event public.calendar_events%rowtype;
  v_next_id uuid;
  v_next_start timestamptz;
  v_next_host uuid;
  v_no_shows integer;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_event from public.calendar_events where id = p_event_id for update;
  if v_event.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_event.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized to close event' using errcode = '42501';
  end if;
  if v_event.status = 'completed' then
    return jsonb_build_object('event_id', p_event_id, 'status', 'completed', 'already_closed', true);
  end if;

  -- no-shows: los que dijeron going/invited y nunca hicieron check-in
  update public.event_participants
     set status = 'no_show'
   where event_id = p_event_id and status in ('going', 'invited', 'maybe') and checked_in_at is null;
  get diagnostics v_no_shows = row_count;

  update public.calendar_events set status = 'completed' where id = p_event_id;

  -- Recurrencia MVP (R4): weekly → siguiente instancia +7 días, host rota al
  -- siguiente miembro activo (orden por joined_at)
  if v_event.recurrence_rule is not null and lower(v_event.recurrence_rule) in ('weekly', 'freq=weekly') then
    v_next_start := v_event.starts_at + interval '7 days';

    select am.member_actor_id into v_next_host
      from public.actor_memberships am
     where am.context_actor_id = v_event.context_actor_id and am.membership_status = 'active'
     order by (am.member_actor_id = v_event.host_actor_id) desc, am.joined_at, am.member_actor_id
     offset 1 limit 1;
    v_next_host := coalesce(v_next_host, v_event.host_actor_id);

    insert into public.calendar_events
      (context_actor_id, title, description, event_type, starts_at, ends_at, timezone,
       location_text, recurrence_rule, host_actor_id, metadata, created_by_actor_id)
    values
      (v_event.context_actor_id, v_event.title, v_event.description, v_event.event_type,
       v_next_start, v_next_start + coalesce(v_event.ends_at - v_event.starts_at, interval '2 hours'),
       v_event.timezone, v_event.location_text, v_event.recurrence_rule, v_next_host,
       v_event.metadata || jsonb_build_object('previous_event_id', p_event_id), v_event.created_by_actor_id)
    returning id into v_next_id;

    insert into public.event_participants (event_id, participant_actor_id, status)
    select v_next_id, am.member_actor_id, 'invited'
      from public.actor_memberships am
     where am.context_actor_id = v_event.context_actor_id and am.membership_status = 'active'
    on conflict do nothing;
  end if;

  perform public._emit_activity(v_event.context_actor_id, v_caller, 'event.closed', 'calendar_event', p_event_id,
    jsonb_build_object('no_shows', v_no_shows, 'next_event_id', v_next_id, 'next_host_actor_id', v_next_host));

  return jsonb_build_object(
    'event_id', p_event_id, 'status', 'completed', 'no_shows', v_no_shows,
    'next_event_id', v_next_id, 'next_host_actor_id', v_next_host);
end; $$;

revoke all on function public.close_event(uuid) from public, anon;
grant execute on function public.close_event(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. RLS
-- ────────────────────────────────────────────────────────────────────────────
alter table public.calendar_events enable row level security;
alter table public.event_participants enable row level security;

create policy events_select on public.calendar_events
  for select to authenticated
  using (public.is_context_member(context_actor_id));

create policy participants_select on public.event_participants
  for select to authenticated
  using (
    participant_actor_id = public.current_actor_id()
    or exists (
      select 1 from public.calendar_events e
      where e.id = event_participants.event_id and public.is_context_member(e.context_actor_id))
  );

revoke all on public.calendar_events, public.event_participants from anon;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Smoke
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_m5_calendar()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_ctx uuid;
  v_result jsonb; v_event uuid; v_code text; v_next uuid;
  v_caught boolean;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke M5A', '+520000000009', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke M5B', '+520000000010', null);

  -- Setup: contexto con A (admin) y B (member)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.create_context('_smoke_m5 Cena', 'collective', 'friend_group');
  v_ctx := (v_result->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Caso 1: crear evento recurrente (cena semanal) → todos invitados
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.create_calendar_event(
    v_ctx, '_smoke_m5 Cena Jueves', 'dinner',
    p_starts_at := now() - interval '30 minutes',  -- ya empezó (para probar late check-in)
    p_recurrence_rule := 'weekly',
    p_host_actor_id := v_a);
  v_event := (v_result->>'event_id')::uuid;
  if (v_result->>'participants')::integer < 2 then
    raise exception 'mvp2_m5 Caso1: no se invitó a todos los miembros';
  end if;

  -- Caso 2: B hace RSVP going
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_result := public.rsvp_event(v_event, 'going');
  if v_result->>'status' <> 'going' then raise exception 'mvp2_m5 Caso2: rsvp falló'; end if;

  -- Caso 3: B hace check-in tarde (evento empezó hace 30 min) → status late + minutes_late
  v_result := public.check_in_participant(v_event);
  if v_result->>'status' <> 'late' then
    raise exception 'mvp2_m5 Caso3: check-in tarde no marcó late (%)' , v_result->>'status';
  end if;
  if (v_result->>'minutes_late')::numeric < 15 then
    raise exception 'mvp2_m5 Caso3: minutes_late incorrecto';
  end if;

  -- Caso 4: no-member NO puede hacer RSVP
  perform set_config('request.jwt.claims', null, true);
  declare
    v_auth_c uuid := gen_random_uuid(); v_c uuid;
  begin
    v_c := public._create_person_actor_for_auth_user(v_auth_c, 'Smoke M5C', '+520000000011', null);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
    v_caught := false;
    begin
      perform public.rsvp_event(v_event, 'going');
    exception when insufficient_privilege then v_caught := true;
    end;
    if not v_caught then raise exception 'mvp2_m5 Caso4: no-member pudo RSVP'; end if;
    perform set_config('request.jwt.claims', null, true);
    delete from public.person_profiles where actor_id = v_c;
    delete from public.actors where id = v_c;
    delete from auth.users where id = v_auth_c;
  end;

  -- Caso 5: close_event → no_show para A (nunca hizo check-in), siguiente instancia creada con host rotado
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.close_event(v_event);
  v_next := (v_result->>'next_event_id')::uuid;
  if v_next is null then raise exception 'mvp2_m5 Caso5: recurrencia no generó siguiente evento'; end if;
  if (v_result->>'no_shows')::integer < 1 then
    raise exception 'mvp2_m5 Caso5: no marcó no_shows';
  end if;
  -- host rotó a B (siguiente miembro activo)
  if (v_result->>'next_host_actor_id')::uuid is distinct from v_b then
    raise exception 'mvp2_m5 Caso5: host no rotó (esperaba B, fue %)', v_result->>'next_host_actor_id';
  end if;
  -- siguiente evento +7 días con todos invitados
  if not exists (
    select 1 from public.calendar_events e
    where e.id = v_next and e.starts_at > now() + interval '6 days'
  ) then
    raise exception 'mvp2_m5 Caso5: siguiente instancia mal fechada';
  end if;

  -- Caso 6: close idempotente
  v_result := public.close_event(v_event);
  if not (v_result->>'already_closed')::boolean then
    raise exception 'mvp2_m5 Caso6: close no es idempotente';
  end if;

  -- Caso 7: cancel_participation same-day
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  declare
    v_today_event uuid;
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
    v_today_event := (public.create_calendar_event(v_ctx, '_smoke_m5 Hoy', 'dinner',
      p_starts_at := now() + interval '3 hours'))->>'event_id';
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
    v_result := public.cancel_participation(v_today_event::uuid);
    if not (v_result->>'same_day_cancellation')::boolean then
      raise exception 'mvp2_m5 Caso7: same-day cancellation no detectada';
    end if;
  end;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.event_participants where event_id in (select id from public.calendar_events where context_actor_id = v_ctx);
  delete from public.calendar_events where context_actor_id = v_ctx;
  delete from public.context_invites where context_actor_id = v_ctx;
  delete from public.role_assignments where context_actor_id = v_ctx;
  delete from public.role_permissions rp using public.roles r where r.id = rp.role_id and r.context_actor_id = v_ctx;
  delete from public.roles where context_actor_id = v_ctx;
  delete from public.actor_memberships where context_actor_id = v_ctx;
  delete from public.actors where id = v_ctx;
  delete from public.person_profiles where actor_id in (v_a, v_b);
  delete from public.actors where id in (v_a, v_b);
  delete from auth.users where id in (v_auth_a, v_auth_b);

  raise notice '_smoke_mvp2_m5_calendar passed (7 casos)';
end; $$;

revoke all on function public._smoke_mvp2_m5_calendar() from public, anon, authenticated;

comment on function public._smoke_mvp2_m5_calendar() is 'Smoke MVP2 M.5: eventos, RSVP, check-in tarde, no-shows, recurrencia semanal + host rotativo.';
