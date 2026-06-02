-- ============================================================================
-- R.2D-2 — FIX: same_day timezone-aware + smokes M.5/M.8 deterministas
-- ============================================================================
-- Bug latente expuesto por correr la suite a las 21:04 UTC:
--
--   M.5 Caso 7 y M.8 Caso 4 crean eventos a now()+3h/+4h y esperan que la
--   cancelación sea "same day". Entre 21:00 y 24:00 UTC, now()+3h cruza la
--   medianoche UTC → same_day = false → smoke falla. La suite siempre había
--   corrido en la mañana UTC; hoy fue la primera corrida nocturna.
--
-- Fix de comportamiento (alineado al spec R.2D del founder: timezone =
-- America/Mexico_City):
--   1. cancel_participation: same_day se calcula en el TIMEZONE DEL EVENTO,
--      no en UTC. Una cena 8pm MX cancelada 6pm MX es "mismo día" en México
--      aunque cruce medianoche UTC.
--   2. M.5 Caso 7 y M.8 Caso 4: el evento empieza en now() → la cancelación
--      es same-day por construcción, en cualquier timezone, a cualquier hora.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. cancel_participation: same_day en el timezone del evento
-- ────────────────────────────────────────────────────────────────────────────
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
  v_tz text;
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

  -- R.2D-2: "mismo día" se evalúa en el timezone del evento, no en UTC
  v_tz := coalesce(v_event.timezone, 'UTC');
  v_same_day := v_event.starts_at is not null
    and (v_event.starts_at at time zone v_tz)::date = (v_effective_at at time zone v_tz)::date;

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
-- 2. M.5 smoke: Caso 7 determinista (evento empieza en now())
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
  -- R.2D-2: el evento empieza en now() → la cancelación (también now()) es
  -- same-day por construcción, en cualquier timezone y a cualquier hora UTC.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  declare
    v_today_event uuid;
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
    v_today_event := (public.create_calendar_event(v_ctx, '_smoke_m5 Hoy', 'dinner',
      p_starts_at := now()))->>'event_id';
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

-- ────────────────────────────────────────────────────────────────────────────
-- 3. M.8 smoke: Caso 4 determinista (evento empieza en now())
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_m8_rules()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_ctx uuid;
  v_result jsonb; v_event uuid; v_code text;
  v_fine numeric;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke M8A', '+520000000017', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke M8B', '+520000000018', null);

  -- Setup: contexto con regla "tarde > 15 min → multa $100" y "cancelar same-day → multa $300"
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_ctx := (public.create_context('_smoke_m8 Cena', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  perform public.create_rule(
    v_ctx::uuid, '_smoke_m8 Multa por tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": ">", "field": "minutes_late", "value": 15}'::jsonb,
    p_consequences := '[{"type": "fine", "amount": 100, "currency": "MXN"}]'::jsonb);
  perform public.create_rule(
    v_ctx::uuid, '_smoke_m8 Multa por cancelar same-day',
    p_trigger_event_type := 'event.participation_cancelled',
    p_condition_tree := '{"op": "=", "field": "same_day", "value": true}'::jsonb,
    p_consequences := '[{"type": "fine", "amount": 300, "currency": "MXN"}]'::jsonb);

  -- Caso 1: member NO puede crear reglas
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  declare v_caught boolean := false;
  begin
    begin
      perform public.create_rule(v_ctx::uuid, '_smoke_m8 hack', p_trigger_event_type := 'x');
    exception when insufficient_privilege then v_caught := true;
    end;
    if not v_caught then raise exception 'mvp2_m8 Caso1: member creó regla sin autoridad'; end if;
  end;

  -- Caso 2: evento que ya empezó hace 30 min + check-in tarde → multa $100 automática
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_event := (public.create_calendar_event(v_ctx::uuid, '_smoke_m8 Cena', 'dinner',
    p_starts_at := now() - interval '30 minutes'))->>'event_id';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_result := public.check_in_participant(v_event::uuid);
  if (v_result->'rules'->>'rules_matched')::integer < 1 then
    raise exception 'mvp2_m8 Caso2: regla de tarde no matcheó';
  end if;

  select amount into v_fine from public.obligations
   where debtor_actor_id = v_b and creditor_actor_id = v_ctx::uuid
     and obligation_type = 'fine' and source_event_id = v_event::uuid
     and source_rule_id is not null;
  if v_fine is distinct from 100 then
    raise exception 'mvp2_m8 Caso2: multa incorrecta (% en vez de 100)', v_fine;
  end if;

  -- Caso 3: check-in a tiempo NO genera multa
  declare
    v_event2 uuid; v_obligations_before integer; v_obligations_after integer;
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
    v_event2 := (public.create_calendar_event(v_ctx::uuid, '_smoke_m8 Cena 2', 'dinner',
      p_starts_at := now() + interval '5 minutes'))->>'event_id';
    select count(*) into v_obligations_before from public.obligations where debtor_actor_id = v_a;
    v_result := public.check_in_participant(v_event2::uuid);
    select count(*) into v_obligations_after from public.obligations where debtor_actor_id = v_a;
    if v_obligations_after <> v_obligations_before then
      raise exception 'mvp2_m8 Caso3: multa generada sin llegar tarde';
    end if;
  end;

  -- Caso 4: cancelar same-day → multa $300
  -- R.2D-2: el evento empieza en now() → la cancelación es same-day por
  -- construcción, en cualquier timezone y a cualquier hora UTC.
  declare v_event3 uuid;
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
    v_event3 := (public.create_calendar_event(v_ctx::uuid, '_smoke_m8 Cena Hoy', 'dinner',
      p_starts_at := now()))->>'event_id';
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
    v_result := public.cancel_participation(v_event3::uuid);
    if (v_result->'rules'->>'rules_matched')::integer < 1 then
      raise exception 'mvp2_m8 Caso4: regla de cancelación no matcheó';
    end if;
    if not exists (
      select 1 from public.obligations
      where debtor_actor_id = v_b and amount = 300 and source_event_id = v_event3::uuid
    ) then
      raise exception 'mvp2_m8 Caso4: multa de cancelación no creada';
    end if;
  end;

  -- Caso 5: rule_evaluations registradas (matched y not_matched)
  if not exists (select 1 from public.rule_evaluations where context_actor_id = v_ctx::uuid and outcome = 'matched') then
    raise exception 'mvp2_m8 Caso5: evaluaciones matched no registradas';
  end if;
  if not exists (select 1 from public.rule_evaluations where context_actor_id = v_ctx::uuid and outcome = 'not_matched') then
    raise exception 'mvp2_m8 Caso5: evaluaciones not_matched no registradas';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.rule_evaluations where context_actor_id = v_ctx::uuid;
  delete from public.obligations where context_actor_id = v_ctx::uuid;
  delete from public.rules where context_actor_id = v_ctx::uuid;
  delete from public.event_participants where event_id in (select id from public.calendar_events where context_actor_id = v_ctx::uuid);
  delete from public.calendar_events where context_actor_id = v_ctx::uuid;
  delete from public.context_invites where context_actor_id = v_ctx::uuid;
  delete from public.role_assignments where context_actor_id = v_ctx::uuid;
  delete from public.role_permissions rp using public.roles r where r.id = rp.role_id and r.context_actor_id = v_ctx::uuid;
  delete from public.roles where context_actor_id = v_ctx::uuid;
  delete from public.actor_memberships where context_actor_id = v_ctx::uuid;
  delete from public.actors where id = v_ctx::uuid;
  delete from public.person_profiles where actor_id in (v_a, v_b);
  delete from public.actors where id in (v_a, v_b);
  delete from auth.users where id in (v_auth_a, v_auth_b);

  raise notice '_smoke_mvp2_m8_rules passed (5 casos)';
end; $$;

revoke all on function public._smoke_mvp2_m8_rules() from public, anon, authenticated;

comment on function public._smoke_mvp2_m8_rules() is 'Smoke MVP2 M.8: reglas, evaluator, multas automáticas por tarde/cancelación, obligations.';
