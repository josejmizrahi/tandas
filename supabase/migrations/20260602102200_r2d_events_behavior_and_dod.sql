-- ============================================================================
-- R.2D — EVENTS DoD: comportamiento de eventos + caso exacto del founder
-- ============================================================================
-- Caso: Cena Semanal Amigos — José (founder), David (host), Isaac, Moisés,
-- Daniel. Cena miércoles 20:00–23:00 (America/Mexico_City). RSVPs, check-ins
-- con horas exactas, cancelación, idempotencia y permisos.
--
-- Gaps de comportamiento corregidos (solo RPCs, cero schema — doctrina R.2):
--   1. create_calendar_event: TODOS los participantes iniciales = 'invited'
--      (antes el creador quedaba 'going' automáticamente).
--   2. rsvp_event: activity type 'event.rsvp_updated' (antes 'event.rsvp').
--   3. check_in_participant:
--      - el HOST del evento puede hacer check-in de otros (antes solo
--        events.manage); founder: "Solo host/founder/admin".
--      - hora explícita (corrección/backfill) solo para host/admin.
--      - check-in repetido es no-op: no cambia checked_in_at salvo
--        corrección explícita con autoridad.
--   4. cancel_participation:
--      - requiere ser miembro o participante (antes cualquier authenticated
--        podía crear una fila de participación cancelada).
--      - el host/admin puede registrar la cancelación de otro con hora exacta.
--      - cancel repetido es no-op seguro (no cambia cancelled_at, no re-emite).
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. create_calendar_event: participantes iniciales todos 'invited'
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

  -- idempotencia por client_id
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

  -- R.2D: todos los miembros activos quedan 'invited' (RSVP es un acto explícito,
  -- crear el evento no implica confirmar asistencia)
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
    jsonb_build_object('title', btrim(p_title), 'event_type', p_event_type, 'starts_at', p_starts_at));

  return jsonb_build_object('event_id', v_id,
    'event', (select to_jsonb(e) from public.calendar_events e where e.id = v_id),
    'participants', (select count(*) from public.event_participants where event_id = v_id));
end; $$;

revoke all on function public.create_calendar_event(uuid, text, text, timestamptz, timestamptz, text, text, text, text, uuid, boolean, jsonb, text) from public, anon;
grant execute on function public.create_calendar_event(uuid, text, text, timestamptz, timestamptz, text, text, text, text, uuid, boolean, jsonb, text) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. rsvp_event: activity 'event.rsvp_updated' + no clobberea check-ins
-- ────────────────────────────────────────────────────────────────────────────
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

  -- RSVP repetido actualiza la misma fila; nunca pisa un check-in ya hecho
  insert into public.event_participants (event_id, participant_actor_id, status, rsvp_at)
  values (p_event_id, v_caller, p_status, now())
  on conflict (event_id, participant_actor_id)
  do update set
    status = case when event_participants.checked_in_at is not null
                  then event_participants.status else excluded.status end,
    rsvp_at = now(),
    cancelled_at = null
  returning id into v_pid;

  perform public._emit_activity(v_event.context_actor_id, v_caller, 'event.rsvp_updated', 'event_participant', v_pid,
    jsonb_build_object('event_id', p_event_id, 'status', p_status));

  return jsonb_build_object('participant_id', v_pid, 'status', p_status);
end; $$;

revoke all on function public.rsvp_event(uuid, text) from public, anon;
grant execute on function public.rsvp_event(uuid, text) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. check_in_participant: host privilege + correcciones + idempotencia
-- ────────────────────────────────────────────────────────────────────────────
drop function if exists public.check_in_participant(uuid, uuid);

create or replace function public.check_in_participant(
  p_event_id uuid,
  p_participant_actor_id uuid default null,
  p_checked_in_at timestamptz default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_target uuid := coalesce(p_participant_actor_id, public.current_actor_id());
  v_event public.calendar_events%rowtype;
  v_existing public.event_participants%rowtype;
  v_is_manager boolean;
  v_effective_at timestamptz;
  v_pid uuid;
  v_minutes_late numeric;
  v_status text;
  v_rules jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_event from public.calendar_events where id = p_event_id;
  if v_event.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;

  -- R.2D: el host del evento o quien tenga events.manage es "event manager"
  v_is_manager := (v_event.host_actor_id is not null and v_event.host_actor_id = v_caller)
    or public.has_actor_authority(v_event.context_actor_id, v_caller, 'events.manage');

  -- check-in de terceros: solo host/founder/admin
  if v_target <> v_caller and not v_is_manager then
    raise exception 'not authorized to check in others' using errcode = '42501';
  end if;
  -- self check-in: ser miembro activo
  if v_target = v_caller and not public.is_context_member(v_event.context_actor_id) then
    raise exception 'not a member of event context' using errcode = '42501';
  end if;
  -- hora explícita (corrección/backfill): solo host/founder/admin
  if p_checked_in_at is not null and not v_is_manager then
    raise exception 'explicit check-in time requires event manager authority' using errcode = '42501';
  end if;

  -- R.2D idempotencia: check-in repetido no duplica ni cambia checked_in_at,
  -- salvo corrección explícita por un event manager
  select * into v_existing from public.event_participants
   where event_id = p_event_id and participant_actor_id = v_target;
  if v_existing.id is not null and v_existing.checked_in_at is not null
     and not (v_is_manager and p_checked_in_at is not null) then
    return jsonb_build_object(
      'participant_id', v_existing.id,
      'status', v_existing.status,
      'checked_in_at', v_existing.checked_in_at,
      'minutes_late', v_existing.metadata->'minutes_late',
      'already_checked_in', true);
  end if;

  v_effective_at := coalesce(p_checked_in_at, now());
  v_minutes_late := greatest(0, extract(epoch from (v_effective_at - v_event.starts_at)) / 60.0);
  v_status := case when v_minutes_late > 15 then 'late' else 'attended' end;

  insert into public.event_participants (event_id, participant_actor_id, status, checked_in_at)
  values (p_event_id, v_target, v_status, v_effective_at)
  on conflict (event_id, participant_actor_id)
  do update set status = excluded.status, checked_in_at = excluded.checked_in_at
  returning id into v_pid;

  update public.event_participants
     set metadata = metadata || jsonb_build_object('minutes_late', round(v_minutes_late, 1))
   where id = v_pid;

  perform public._emit_activity(v_event.context_actor_id, v_target, 'event.checked_in', 'event_participant', v_pid,
    jsonb_build_object('event_id', p_event_id, 'minutes_late', round(v_minutes_late, 1), 'status', v_status));

  -- rule engine síncrono (M.8) — la tardanza alimenta R.2E
  v_rules := public.evaluate_rules_for_event(
    v_event.context_actor_id, 'event.checked_in', v_target,
    jsonb_build_object('minutes_late', round(v_minutes_late, 1), 'status', v_status),
    p_event_id);

  return jsonb_build_object('participant_id', v_pid, 'status', v_status,
    'checked_in_at', v_effective_at,
    'minutes_late', round(v_minutes_late, 1), 'rules', v_rules);
end; $$;

revoke all on function public.check_in_participant(uuid, uuid, timestamptz) from public, anon;
grant execute on function public.check_in_participant(uuid, uuid, timestamptz) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. cancel_participation: membership check + correcciones + no-op seguro
-- ────────────────────────────────────────────────────────────────────────────
drop function if exists public.cancel_participation(uuid);

create or replace function public.cancel_participation(
  p_event_id uuid,
  p_participant_actor_id uuid default null,
  p_cancelled_at timestamptz default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_target uuid := coalesce(p_participant_actor_id, public.current_actor_id());
  v_event public.calendar_events%rowtype;
  v_existing public.event_participants%rowtype;
  v_is_manager boolean;
  v_effective_at timestamptz;
  v_pid uuid;
  v_same_day boolean;
  v_rules jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_event from public.calendar_events where id = p_event_id;
  if v_event.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;

  v_is_manager := (v_event.host_actor_id is not null and v_event.host_actor_id = v_caller)
    or public.has_actor_authority(v_event.context_actor_id, v_caller, 'events.manage');

  -- cancelar por terceros u hora explícita: solo host/founder/admin
  if (v_target <> v_caller or p_cancelled_at is not null) and not v_is_manager then
    raise exception 'not authorized to cancel for others or backdate' using errcode = '42501';
  end if;
  -- self cancel: ser miembro activo o participante del evento
  if v_target = v_caller
     and not public.is_context_member(v_event.context_actor_id)
     and not exists (select 1 from public.event_participants
                     where event_id = p_event_id and participant_actor_id = v_caller) then
    raise exception 'not a member of event context' using errcode = '42501';
  end if;

  -- R.2D idempotencia: cancel repetido es no-op seguro
  select * into v_existing from public.event_participants
   where event_id = p_event_id and participant_actor_id = v_target;
  if v_existing.id is not null and v_existing.status = 'cancelled' then
    return jsonb_build_object(
      'participant_id', v_existing.id,
      'status', 'cancelled',
      'cancelled_at', v_existing.cancelled_at,
      'already_cancelled', true);
  end if;

  v_effective_at := coalesce(p_cancelled_at, now());
  v_same_day := v_event.starts_at is not null and v_event.starts_at::date = v_effective_at::date;

  insert into public.event_participants (event_id, participant_actor_id, status, cancelled_at)
  values (p_event_id, v_target, 'cancelled', v_effective_at)
  on conflict (event_id, participant_actor_id)
  do update set status = 'cancelled', cancelled_at = excluded.cancelled_at
  returning id into v_pid;

  update public.event_participants
     set metadata = metadata || jsonb_build_object('same_day_cancellation', v_same_day)
   where id = v_pid;

  perform public._emit_activity(v_event.context_actor_id, v_target, 'event.participation_cancelled', 'event_participant', v_pid,
    jsonb_build_object('event_id', p_event_id, 'same_day', v_same_day));

  -- rule engine síncrono (M.8) — la cancelación alimenta R.2E
  v_rules := public.evaluate_rules_for_event(
    v_event.context_actor_id, 'event.participation_cancelled', v_target,
    jsonb_build_object('same_day', v_same_day),
    p_event_id);

  return jsonb_build_object('participant_id', v_pid, 'status', 'cancelled',
    'cancelled_at', v_effective_at,
    'same_day_cancellation', v_same_day, 'rules', v_rules);
end; $$;

revoke all on function public.cancel_participation(uuid, uuid, timestamptz) from public, anon;
grant execute on function public.cancel_participation(uuid, uuid, timestamptz) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Smoke R.2D — caso exacto del founder
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2d_events_dod()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  u_isaac uuid; a_isaac uuid;
  u_moises uuid; a_moises uuid;
  u_daniel uuid; a_daniel uuid;
  u_out uuid; a_out uuid;
  v_ctx uuid; v_event uuid; v_code text;
  v_result jsonb;
  v_starts timestamptz; v_ends timestamptz;
  v_t1800 timestamptz; v_t2012 timestamptz;
  v_pid_a uuid; v_pid_b uuid;
  v_caught boolean;
  v_fn text;
  r record;
begin
  -- ═══ Setup: Cena Semanal Amigos — José founder, 4 members via invite code ═══
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2D', '+5210000040');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2D', '+5210000041');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2D', '+5210000042');
  select auth_id, actor_id into u_moises, a_moises from public._r2_make_person('Moisés R2D', '+5210000043');
  select auth_id, actor_id into u_daniel, a_daniel from public._r2_make_person('Daniel R2D', '+5210000044');
  select auth_id, actor_id into u_out, a_out from public._r2_make_person('Outsider R2D', '+5210000045');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Cena Semanal Amigos', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Tiempos exactos: "20:00" = now() - 21 min → el check-in natural de Moisés
  -- (now()) cae exactamente en "20:21". now() está congelado en la transacción.
  v_starts := now() - interval '21 minutes';          -- 20:00
  v_ends   := v_starts + interval '3 hours';          -- 23:00
  v_t1800  := v_starts - interval '2 hours';          -- 18:00
  v_t2012  := v_starts + interval '12 minutes';       -- 20:12

  -- ═══ 1. José crea el evento (cena mié 20:00–23:00, tz MX, host = David) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.create_calendar_event(v_ctx::uuid, 'Cena miércoles', 'dinner',
    p_starts_at := v_starts, p_ends_at := v_ends,
    p_timezone := 'America/Mexico_City',
    p_host_actor_id := a_david,
    p_client_id := 'r2d-cena-miercoles');
  v_event := (v_result->>'event_id')::uuid;

  -- calendar_events tiene 1 cena con atributos correctos
  if (select count(*) from public.calendar_events where context_actor_id = v_ctx::uuid) <> 1 then
    raise exception 'R2D FAIL 1: debe existir exactamente 1 evento';
  end if;
  if not exists (
    select 1 from public.calendar_events
    where id = v_event and event_type = 'dinner' and timezone = 'America/Mexico_City'
      and host_actor_id = a_david and starts_at = v_starts and ends_at = v_ends
  ) then
    raise exception 'R2D FAIL 1: atributos del evento incorrectos';
  end if;

  -- event_participants tiene 5 filas, todas 'invited'
  if (select count(*) from public.event_participants where event_id = v_event) <> 5 then
    raise exception 'R2D FAIL 1: esperaba 5 participantes';
  end if;
  if (select count(*) from public.event_participants where event_id = v_event and status = 'invited') <> 5 then
    raise exception 'R2D FAIL 1: todos los participantes iniciales deben ser invited';
  end if;

  -- Idempotencia: create con mismo client_id devuelve el mismo event_id
  if (public.create_calendar_event(v_ctx::uuid, 'Cena miércoles', 'dinner',
        p_starts_at := v_starts, p_client_id := 'r2d-cena-miercoles')->>'event_id')::uuid
     is distinct from v_event then
    raise exception 'R2D FAIL idempotencia: client_id repetido devolvió otro event_id';
  end if;
  if (select count(*) from public.calendar_events where context_actor_id = v_ctx::uuid) <> 1 then
    raise exception 'R2D FAIL idempotencia: client_id repetido duplicó el evento';
  end if;

  -- ═══ 2. David, Isaac, Moisés y Daniel hacen RSVP = going ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.rsvp_event(v_event, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.rsvp_event(v_event, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.rsvp_event(v_event, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.rsvp_event(v_event, 'going');

  -- ═══ 3. José hace RSVP = maybe (y repetido actualiza la misma fila) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_pid_a := (public.rsvp_event(v_event, 'maybe')->>'participant_id')::uuid;
  v_pid_b := (public.rsvp_event(v_event, 'maybe')->>'participant_id')::uuid;
  if v_pid_a is distinct from v_pid_b then
    raise exception 'R2D FAIL 3: RSVP repetido creó otra fila';
  end if;
  if (select count(*) from public.event_participants where event_id = v_event) <> 5 then
    raise exception 'R2D FAIL 3: RSVP repetido duplicó participantes';
  end if;

  -- ═══ 4. David (host) hace check-in a las 20:00 ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.check_in_participant(v_event, p_checked_in_at := v_starts);
  if v_result->>'status' <> 'attended' then
    raise exception 'R2D FAIL 4: David debió quedar attended (quedó %)', v_result->>'status';
  end if;

  -- ═══ 5. Isaac check-in a las 20:12 (lo registra el host) ═══
  v_result := public.check_in_participant(v_event, a_isaac, v_t2012);
  if v_result->>'status' <> 'attended' then
    raise exception 'R2D FAIL 5: Isaac debió quedar attended (12 min < 15)';
  end if;

  -- Permiso: Isaac (miembro, no host/admin) NO puede check-in de otros
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_caught := false;
  begin
    perform public.check_in_participant(v_event, a_moises);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2D FAIL permisos: miembro sin autoridad pudo check-in a otro'; end if;

  -- Permiso: Moisés NO puede self check-in con hora explícita (corrección = host/admin)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  v_caught := false;
  begin
    perform public.check_in_participant(v_event, p_checked_in_at := v_starts);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2D FAIL permisos: corrección de hora sin autoridad permitida'; end if;

  -- ═══ 6. Moisés hace check-in natural (= "20:21") → late ═══
  v_result := public.check_in_participant(v_event);
  if v_result->>'status' <> 'late' then
    raise exception 'R2D FAIL 6: Moisés debió quedar late (quedó %, % min)',
      v_result->>'status', v_result->>'minutes_late';
  end if;
  if (v_result->>'minutes_late')::numeric not between 20 and 22 then
    raise exception 'R2D FAIL 6: minutes_late de Moisés = % (esperaba ~21)', v_result->>'minutes_late';
  end if;

  -- Idempotencia: check-in repetido (Isaac) no duplica ni cambia checked_in_at
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_result := public.check_in_participant(v_event);
  if not coalesce((v_result->>'already_checked_in')::boolean, false) then
    raise exception 'R2D FAIL idempotencia: check-in repetido no fue no-op';
  end if;
  if (select checked_in_at from public.event_participants
      where event_id = v_event and participant_actor_id = a_isaac) is distinct from v_t2012 then
    raise exception 'R2D FAIL idempotencia: check-in repetido cambió checked_in_at de Isaac';
  end if;

  -- ═══ 7. Daniel cancela participación a las 18:00 ═══
  -- (el host registra la cancelación que Daniel avisó a las 18:00)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.cancel_participation(v_event, a_daniel, v_t1800);
  if v_result->>'status' <> 'cancelled' then
    raise exception 'R2D FAIL 7: cancelación de Daniel falló';
  end if;

  -- Idempotencia: cancel repetido (Daniel mismo) es no-op seguro
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  v_result := public.cancel_participation(v_event);
  if not coalesce((v_result->>'already_cancelled')::boolean, false) then
    raise exception 'R2D FAIL idempotencia: cancel repetido no fue no-op';
  end if;
  if (select cancelled_at from public.event_participants
      where event_id = v_event and participant_actor_id = a_daniel) is distinct from v_t1800 then
    raise exception 'R2D FAIL idempotencia: cancel repetido cambió cancelled_at';
  end if;

  -- ═══ 8. Resultado esperado completo (José nunca hizo check-in) ═══
  -- David: attended @ 20:00
  select * into r from public.event_participants where event_id = v_event and participant_actor_id = a_david;
  if r.status <> 'attended' or r.checked_in_at is distinct from v_starts then
    raise exception 'R2D FAIL 8: David esperaba attended@20:00 (% @ %)', r.status, r.checked_in_at;
  end if;
  -- Isaac: attended @ 20:12
  select * into r from public.event_participants where event_id = v_event and participant_actor_id = a_isaac;
  if r.status <> 'attended' or r.checked_in_at is distinct from v_t2012 then
    raise exception 'R2D FAIL 8: Isaac esperaba attended@20:12 (% @ %)', r.status, r.checked_in_at;
  end if;
  -- Moisés: late @ 20:21 (= now())
  select * into r from public.event_participants where event_id = v_event and participant_actor_id = a_moises;
  if r.status <> 'late' or r.checked_in_at is distinct from now() then
    raise exception 'R2D FAIL 8: Moisés esperaba late@20:21 (% @ %)', r.status, r.checked_in_at;
  end if;
  -- Daniel: cancelled @ 18:00, sin check-in
  select * into r from public.event_participants where event_id = v_event and participant_actor_id = a_daniel;
  if r.status <> 'cancelled' or r.cancelled_at is distinct from v_t1800 or r.checked_in_at is not null then
    raise exception 'R2D FAIL 8: Daniel esperaba cancelled@18:00 (% @ %)', r.status, r.cancelled_at;
  end if;
  -- José: maybe, checked_in_at NULL
  select * into r from public.event_participants where event_id = v_event and participant_actor_id = a_jose;
  if r.status <> 'maybe' or r.checked_in_at is not null then
    raise exception 'R2D FAIL 8: José esperaba maybe sin check-in (% @ %)', r.status, r.checked_in_at;
  end if;

  -- context_summary refleja el evento (upcoming/current)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.context_summary(v_ctx::uuid);
  if not exists (
    select 1 from jsonb_array_elements(v_result->'upcoming_events') e
    where (e->>'event_id')::uuid = v_event
  ) then
    raise exception 'R2D FAIL 8: context_summary no refleja el evento';
  end if;

  -- ═══ activity_events registra los 4 tipos ═══
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'event.created') <> 1 then
    raise exception 'R2D FAIL activity: event.created debe ser exactamente 1';
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'event.rsvp_updated') <> 6 then
    raise exception 'R2D FAIL activity: event.rsvp_updated debe ser 6 (4 going + 2 maybe), hay %',
      (select count(*) from public.activity_events
       where context_actor_id = v_ctx::uuid and event_type = 'event.rsvp_updated');
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'event.checked_in') <> 3 then
    raise exception 'R2D FAIL activity: event.checked_in debe ser 3 (no-ops no emiten)';
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'event.participation_cancelled') <> 1 then
    raise exception 'R2D FAIL activity: event.participation_cancelled debe ser 1 (no-ops no emiten)';
  end if;

  -- ═══ Permisos: no-miembro no puede ver ni modificar ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_caught := false;
  begin perform public.rsvp_event(v_event, 'going');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2D FAIL permisos: no-miembro pudo RSVP'; end if;
  v_caught := false;
  begin perform public.check_in_participant(v_event);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2D FAIL permisos: no-miembro pudo check-in'; end if;
  v_caught := false;
  begin perform public.cancel_participation(v_event);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2D FAIL permisos: no-miembro pudo cancelar participación'; end if;
  v_caught := false;
  begin perform public.context_summary(v_ctx::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2D FAIL permisos: no-miembro pudo ver el contexto del evento'; end if;

  -- ═══ Permisos: miembro removido no puede RSVP ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.remove_member(v_ctx::uuid, a_daniel, 'prueba R2D');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  v_caught := false;
  begin perform public.rsvp_event(v_event, 'going');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2D FAIL permisos: miembro removido pudo RSVP'; end if;

  -- ═══ Permisos: anon bloqueado en todos los RPCs de eventos ═══
  foreach v_fn in array array[
    'public.create_calendar_event(uuid, text, text, timestamptz, timestamptz, text, text, text, text, uuid, boolean, jsonb, text)',
    'public.rsvp_event(uuid, text)',
    'public.check_in_participant(uuid, uuid, timestamptz)',
    'public.cancel_participation(uuid, uuid, timestamptz)',
    'public.close_event(uuid)'
  ] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') then
      raise exception 'R2D FAIL permisos: anon puede ejecutar %', v_fn;
    end if;
  end loop;

  -- ═══ Cleanup ═══
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_jose, a_david, a_isaac, a_moises, a_daniel, a_out],
    array[u_jose, u_david, u_isaac, u_moises, u_daniel, u_out]);

  raise notice 'R.2D EVENTS DoD: PASS (cena 20:00-23:00, RSVPs, check-ins exactos, cancelación, idempotencia, permisos)';
end; $$;

revoke all on function public._smoke_r2d_events_dod() from public, anon, authenticated;

comment on function public._smoke_r2d_events_dod() is
  'R.2D DoD exacto: José crea cena (host David) → 5 invited → RSVPs → David attended@20:00, Isaac attended@20:12, Moisés late@20:21, Daniel cancelled@18:00, José maybe → activity → permisos → idempotencia.';

-- Wrapper para CI (descubre funciones _smoke_mvp2_%)
create or replace function public._smoke_mvp2_r2d_events_dod()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._smoke_r2d_events_dod();
end; $$;

revoke all on function public._smoke_mvp2_r2d_events_dod() from public, anon, authenticated;

comment on function public._smoke_mvp2_r2d_events_dod() is
  'Wrapper CI del smoke R.2D (_smoke_r2d_events_dod).';
