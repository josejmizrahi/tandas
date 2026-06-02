-- ============================================================================
-- R.2E — RULES DoD: engine endurecido + caso exacto del founder
-- ============================================================================
-- Caso: Cena Semanal Amigos con el estado heredado de R.2D (David attended@20:00,
-- Isaac attended@20:12, Moisés late@20:21, Daniel cancelled@18:00 same-day,
-- José maybe). Dos reglas: tarde >15min → $100, cancelar same-day → $300.
--
-- Gaps del engine corregidos (solo RPCs, cero schema — doctrina R.2):
--   1. evaluate_rules_for_event:
--      - GATE de ejecución directa: solo self / host del evento / rules.manage
--        (antes cualquier authenticated podía fabricar payloads y multar a otros).
--      - IDEMPOTENCIA: misma regla + evento + participante + reason → una sola
--        obligation; re-evaluar devuelve la misma (already_existed).
--      - METADATA de obligation: reason, participant_actor_id,
--        triggering_event_type, rule_evaluation_id (la evaluación se registra
--        primero y la obligation la referencia).
--      - ACTIVITY: rule.evaluated (cada evaluación) + obligation.created +
--        fine.created (cuando obligation_type = fine).
--   2. check_in_participant: payload incluye event_type (condición "dinner").
--   3. cancel_participation: payload incluye event_type + same_day_cancellation.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. evaluate_rules_for_event v2
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.evaluate_rules_for_event(
  p_context_actor_id uuid,
  p_trigger_event_type text,
  p_subject_actor_id uuid,
  p_payload jsonb,
  p_source_event_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_rule record;
  v_matched integer := 0;
  v_obligations jsonb := '[]'::jsonb;
  v_rule_obligations jsonb;
  v_consequence jsonb;
  v_obligation_id uuid;
  v_eval_id uuid;
  v_outcome text;
  v_reason text;
  v_obligation_type text;
  v_existing uuid;
  v_is_new boolean;
begin
  -- R.2E gate: ejecución directa solo para self, host del evento, o rules.manage.
  -- Las llamadas internas (check_in/cancel) siempre cumplen: self o host.
  -- v_caller null = service_role / cron → permitido.
  if v_caller is not null
     and v_caller <> p_subject_actor_id
     and not exists (
       select 1 from public.calendar_events e
       where e.id = p_source_event_id and e.host_actor_id = v_caller)
     and not public.has_actor_authority(p_context_actor_id, v_caller, 'rules.manage') then
    raise exception 'not authorized to evaluate rules for other actors' using errcode = '42501';
  end if;

  for v_rule in
    select * from public.rules
    where context_actor_id = p_context_actor_id
      and status = 'active'
      and trigger_event_type = p_trigger_event_type
  loop
    v_outcome := case when public._eval_condition(v_rule.condition_tree, p_payload)
                      then 'matched' else 'not_matched' end;
    v_rule_obligations := '[]'::jsonb;

    -- R.2E: la evaluación se registra PRIMERO para que las obligations la referencien
    insert into public.rule_evaluations
      (rule_id, context_actor_id, triggering_event_type, triggering_object_id, outcome, metadata)
    values
      (v_rule.id, p_context_actor_id, p_trigger_event_type, p_source_event_id, v_outcome,
       jsonb_build_object('subject_actor_id', p_subject_actor_id, 'payload', p_payload))
    returning id into v_eval_id;

    if v_outcome = 'matched' then
      v_matched := v_matched + 1;

      for v_consequence in select * from jsonb_array_elements(coalesce(v_rule.consequences, '[]'::jsonb)) loop
        if v_consequence->>'type' in ('fine', 'create_obligation') then
          v_obligation_type := coalesce(v_consequence->>'obligation_type', 'fine');
          v_reason := coalesce(v_consequence->>'reason', v_rule.title);

          -- R.2E idempotencia: misma regla + evento + participante + reason → 1 obligation
          select id into v_existing from public.obligations
           where source_rule_id = v_rule.id
             and source_event_id is not distinct from p_source_event_id
             and debtor_actor_id = p_subject_actor_id
             and metadata->>'reason' is not distinct from v_reason
             and status <> 'cancelled'
           limit 1;

          v_is_new := v_existing is null;
          if v_is_new then
            insert into public.obligations
              (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type,
               amount, currency, source_event_id, source_rule_id, metadata)
            values
              (p_context_actor_id,
               p_subject_actor_id,
               p_context_actor_id,  -- creditor = el contexto
               v_obligation_type,
               (v_consequence->>'amount')::numeric,
               coalesce(v_consequence->>'currency', 'MXN'),
               p_source_event_id,
               v_rule.id,
               jsonb_build_object(
                 'reason', v_reason,
                 'participant_actor_id', p_subject_actor_id,
                 'triggering_event_type', p_trigger_event_type,
                 'rule_evaluation_id', v_eval_id,
                 'rule_title', v_rule.title,
                 'trigger', p_trigger_event_type))
            returning id into v_obligation_id;

            perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'obligation.created',
              'obligation', v_obligation_id,
              jsonb_build_object('rule_title', v_rule.title, 'amount', (v_consequence->>'amount')::numeric,
                                 'obligation_type', v_obligation_type, 'reason', v_reason),
              p_obligation_id := v_obligation_id);

            if v_obligation_type = 'fine' then
              perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'fine.created',
                'obligation', v_obligation_id,
                jsonb_build_object('rule_title', v_rule.title, 'amount', (v_consequence->>'amount')::numeric,
                                   'reason', v_reason),
                p_obligation_id := v_obligation_id);
            end if;
          else
            v_obligation_id := v_existing;
          end if;

          v_rule_obligations := v_rule_obligations || jsonb_build_object(
            'obligation_id', v_obligation_id,
            'rule_id', v_rule.id,
            'amount', (v_consequence->>'amount')::numeric,
            'already_existed', not v_is_new);
        end if;
      end loop;

      update public.rule_evaluations
         set consequences_emitted = jsonb_build_object('obligations', v_rule_obligations)
       where id = v_eval_id;

      v_obligations := v_obligations || v_rule_obligations;
    end if;

    -- R.2E activity: cada evaluación queda auditada
    perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'rule.evaluated',
      'rule_evaluation', v_eval_id,
      jsonb_build_object('rule_id', v_rule.id, 'rule_title', v_rule.title, 'outcome', v_outcome));
  end loop;

  return jsonb_build_object('rules_matched', v_matched, 'obligations_created', v_obligations);
end; $$;

revoke all on function public.evaluate_rules_for_event(uuid, text, uuid, jsonb, uuid) from public, anon;
grant execute on function public.evaluate_rules_for_event(uuid, text, uuid, jsonb, uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. check_in_participant: payload con event_type
-- ────────────────────────────────────────────────────────────────────────────
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

  v_is_manager := (v_event.host_actor_id is not null and v_event.host_actor_id = v_caller)
    or public.has_actor_authority(v_event.context_actor_id, v_caller, 'events.manage');

  if v_target <> v_caller and not v_is_manager then
    raise exception 'not authorized to check in others' using errcode = '42501';
  end if;
  if v_target = v_caller and not public.is_context_member(v_event.context_actor_id) then
    raise exception 'not a member of event context' using errcode = '42501';
  end if;
  if p_checked_in_at is not null and not v_is_manager then
    raise exception 'explicit check-in time requires event manager authority' using errcode = '42501';
  end if;

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

  -- R.2E: el payload incluye event_type para condiciones tipo "event_type = dinner"
  v_rules := public.evaluate_rules_for_event(
    v_event.context_actor_id, 'event.checked_in', v_target,
    jsonb_build_object('minutes_late', round(v_minutes_late, 1), 'status', v_status,
                       'event_type', v_event.event_type),
    p_event_id);

  return jsonb_build_object('participant_id', v_pid, 'status', v_status,
    'checked_in_at', v_effective_at,
    'minutes_late', round(v_minutes_late, 1), 'rules', v_rules);
end; $$;

revoke all on function public.check_in_participant(uuid, uuid, timestamptz) from public, anon;
grant execute on function public.check_in_participant(uuid, uuid, timestamptz) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. cancel_participation: payload con event_type + same_day_cancellation
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

  if (v_target <> v_caller or p_cancelled_at is not null) and not v_is_manager then
    raise exception 'not authorized to cancel for others or backdate' using errcode = '42501';
  end if;
  if v_target = v_caller
     and not public.is_context_member(v_event.context_actor_id)
     and not exists (select 1 from public.event_participants
                     where event_id = p_event_id and participant_actor_id = v_caller) then
    raise exception 'not a member of event context' using errcode = '42501';
  end if;

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

  -- R.2E: payload con event_type + same_day_cancellation (nombre de campo del spec);
  -- same_day se mantiene por compat con reglas anteriores
  v_rules := public.evaluate_rules_for_event(
    v_event.context_actor_id, 'event.participation_cancelled', v_target,
    jsonb_build_object('same_day', v_same_day, 'same_day_cancellation', v_same_day,
                       'event_type', v_event.event_type),
    p_event_id);

  return jsonb_build_object('participant_id', v_pid, 'status', 'cancelled',
    'cancelled_at', v_effective_at,
    'same_day_cancellation', v_same_day, 'rules', v_rules);
end; $$;

revoke all on function public.cancel_participation(uuid, uuid, timestamptz) from public, anon;
grant execute on function public.cancel_participation(uuid, uuid, timestamptz) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Smoke R.2E — caso exacto del founder
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2e_rules_dod()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  u_isaac uuid; a_isaac uuid;
  u_moises uuid; a_moises uuid;
  u_daniel uuid; a_daniel uuid;
  v_ctx uuid; v_event uuid; v_code text;
  v_rule1 uuid; v_rule2 uuid;
  v_result jsonb; v_payload jsonb;
  v_starts timestamptz;
  v_oblig_moises uuid; v_oblig_daniel uuid;
  v_caught boolean;
  v_fn text;
begin
  -- ═══ Setup: Cena Semanal Amigos + estado heredado de R.2D ═══
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2E', '+5210000050');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2E', '+5210000051');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2E', '+5210000052');
  select auth_id, actor_id into u_moises, a_moises from public._r2_make_person('Moisés R2E', '+5210000053');
  select auth_id, actor_id into u_daniel, a_daniel from public._r2_make_person('Daniel R2E', '+5210000054');

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

  -- Evento: cena 20:00-23:00 MX, host David ("20:00" = now() - 21 min)
  v_starts := now() - interval '21 minutes';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_event := (public.create_calendar_event(v_ctx::uuid, 'Cena miércoles', 'dinner',
    p_starts_at := v_starts, p_ends_at := v_starts + interval '3 hours',
    p_timezone := 'America/Mexico_City', p_host_actor_id := a_david))->>'event_id';

  -- Estado R.2D heredado (SIN reglas todavía → los check-ins no generan multas):
  -- José RSVP maybe; David attended@20:00; Isaac attended@20:12 (host lo registra);
  -- Moisés late@20:21 (natural); Daniel cancelled@18:00 (host lo registra)
  perform public.rsvp_event(v_event::uuid, 'maybe');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.check_in_participant(v_event::uuid, p_checked_in_at := v_starts);
  perform public.check_in_participant(v_event::uuid, a_isaac, v_starts + interval '12 minutes');
  perform public.cancel_participation(v_event::uuid, a_daniel, v_starts - interval '2 hours');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.check_in_participant(v_event::uuid);

  -- Sanity del estado heredado
  if (select count(*) from public.obligations where context_actor_id = v_ctx::uuid) <> 0 then
    raise exception 'R2E FAIL setup: hay multas antes de crear reglas';
  end if;
  if (select status from public.event_participants where event_id = v_event::uuid and participant_actor_id = a_moises) <> 'late' then
    raise exception 'R2E FAIL setup: Moisés no quedó late';
  end if;

  -- ═══ 1. Crear ambas reglas (José, founder/admin) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_rule1 := (public.create_rule(v_ctx::uuid, 'Multa por llegar tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": ">", "field": "minutes_late", "value": 15}]}'::jsonb,
    p_consequences := '[{"type": "create_obligation", "obligation_type": "fine",
      "amount": 100, "currency": "MXN", "reason": "late_arrival"}]'::jsonb))->>'rule_id';

  v_rule2 := (public.create_rule(v_ctx::uuid, 'Multa por cancelar mismo día',
    p_trigger_event_type := 'event.participation_cancelled',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": "=", "field": "same_day_cancellation", "value": true}]}'::jsonb,
    p_consequences := '[{"type": "create_obligation", "obligation_type": "fine",
      "amount": 300, "currency": "MXN", "reason": "same_day_cancellation"}]'::jsonb))->>'rule_id';

  if v_rule1 is null or v_rule2 is null then
    raise exception 'R2E FAIL 1: las reglas no se crearon';
  end if;

  -- Permiso: miembro normal (Isaac) NO puede crear reglas
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_caught := false;
  begin
    perform public.create_rule(v_ctx::uuid, 'R2E hack', p_trigger_event_type := 'x');
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2E FAIL permisos: miembro normal creó una regla'; end if;

  -- ═══ 2. Evaluar el check-in de Moisés (José, admin) ═══
  -- El payload se reconstruye desde el estado guardado del participante
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  select jsonb_build_object(
    'minutes_late', (ep.metadata->>'minutes_late')::numeric,
    'status', ep.status,
    'event_type', ce.event_type)
  into v_payload
  from public.event_participants ep
  join public.calendar_events ce on ce.id = ep.event_id
  where ep.event_id = v_event::uuid and ep.participant_actor_id = a_moises;

  v_result := public.evaluate_rules_for_event(v_ctx::uuid, 'event.checked_in', a_moises, v_payload, v_event::uuid);
  if (v_result->>'rules_matched')::integer <> 1 then
    raise exception 'R2E FAIL 2: regla de tardanza no matcheó para Moisés (matched=%)', v_result->>'rules_matched';
  end if;
  v_oblig_moises := (v_result->'obligations_created'->0->>'obligation_id')::uuid;

  -- ═══ 3. Evaluar la cancelación de Daniel (José, admin) ═══
  select jsonb_build_object(
    'same_day_cancellation', (ep.metadata->>'same_day_cancellation')::boolean,
    'event_type', ce.event_type)
  into v_payload
  from public.event_participants ep
  join public.calendar_events ce on ce.id = ep.event_id
  where ep.event_id = v_event::uuid and ep.participant_actor_id = a_daniel;

  v_result := public.evaluate_rules_for_event(v_ctx::uuid, 'event.participation_cancelled', a_daniel, v_payload, v_event::uuid);
  if (v_result->>'rules_matched')::integer <> 1 then
    raise exception 'R2E FAIL 3: regla de cancelación no matcheó para Daniel';
  end if;
  v_oblig_daniel := (v_result->'obligations_created'->0->>'obligation_id')::uuid;

  -- ═══ Evaluar David e Isaac → not_matched, sin multas ═══
  -- David: lo evalúa José (admin)
  v_result := public.evaluate_rules_for_event(v_ctx::uuid, 'event.checked_in', a_david,
    jsonb_build_object('minutes_late', 0, 'status', 'attended', 'event_type', 'dinner'), v_event::uuid);
  if (v_result->>'rules_matched')::integer <> 0 then
    raise exception 'R2E FAIL: David recibió multa sin llegar tarde';
  end if;
  -- Isaac: lo evalúa David (HOST, no admin) → el gate de host permite ejecución directa
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.evaluate_rules_for_event(v_ctx::uuid, 'event.checked_in', a_isaac,
    jsonb_build_object('minutes_late', 12, 'status', 'attended', 'event_type', 'dinner'), v_event::uuid);
  if (v_result->>'rules_matched')::integer <> 0 then
    raise exception 'R2E FAIL: Isaac recibió multa sin llegar tarde';
  end if;

  -- ═══ 4. Re-ejecutar ambas evaluaciones → idempotencia ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  select jsonb_build_object(
    'minutes_late', (ep.metadata->>'minutes_late')::numeric,
    'status', ep.status, 'event_type', 'dinner')
  into v_payload
  from public.event_participants ep
  where ep.event_id = v_event::uuid and ep.participant_actor_id = a_moises;

  v_result := public.evaluate_rules_for_event(v_ctx::uuid, 'event.checked_in', a_moises, v_payload, v_event::uuid);
  if (v_result->'obligations_created'->0->>'obligation_id')::uuid is distinct from v_oblig_moises then
    raise exception 'R2E FAIL 4: re-evaluación no devolvió la misma obligation de Moisés';
  end if;
  if not (v_result->'obligations_created'->0->>'already_existed')::boolean then
    raise exception 'R2E FAIL 4: re-evaluación no marcó already_existed';
  end if;

  v_result := public.evaluate_rules_for_event(v_ctx::uuid, 'event.participation_cancelled', a_daniel,
    jsonb_build_object('same_day_cancellation', true, 'event_type', 'dinner'), v_event::uuid);
  if (v_result->'obligations_created'->0->>'obligation_id')::uuid is distinct from v_oblig_daniel then
    raise exception 'R2E FAIL 4: re-evaluación no devolvió la misma obligation de Daniel';
  end if;

  -- ═══ Resultado esperado ═══
  -- Moisés: exactamente 1 fine $100 MXN
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and debtor_actor_id = a_moises) <> 1 then
    raise exception 'R2E FAIL resultado: Moisés debe tener exactamente 1 multa';
  end if;
  if not exists (
    select 1 from public.obligations
    where id = v_oblig_moises and debtor_actor_id = a_moises and creditor_actor_id = v_ctx::uuid
      and obligation_type = 'fine' and amount = 100 and currency = 'MXN' and status = 'open'
      and source_rule_id = v_rule1::uuid and source_event_id = v_event::uuid
      and metadata->>'reason' = 'late_arrival'
      and (metadata->>'participant_actor_id')::uuid = a_moises
      and metadata->>'triggering_event_type' = 'event.checked_in'
      and metadata->>'rule_evaluation_id' is not null
  ) then
    raise exception 'R2E FAIL resultado: multa de Moisés incorrecta (monto/rule/event/metadata)';
  end if;

  -- Daniel: exactamente 1 fine $300 MXN
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and debtor_actor_id = a_daniel) <> 1 then
    raise exception 'R2E FAIL resultado: Daniel debe tener exactamente 1 multa';
  end if;
  if not exists (
    select 1 from public.obligations
    where id = v_oblig_daniel and debtor_actor_id = a_daniel and creditor_actor_id = v_ctx::uuid
      and obligation_type = 'fine' and amount = 300 and currency = 'MXN' and status = 'open'
      and source_rule_id = v_rule2::uuid and source_event_id = v_event::uuid
      and metadata->>'reason' = 'same_day_cancellation'
      and (metadata->>'participant_actor_id')::uuid = a_daniel
      and metadata->>'triggering_event_type' = 'event.participation_cancelled'
      and metadata->>'rule_evaluation_id' is not null
  ) then
    raise exception 'R2E FAIL resultado: multa de Daniel incorrecta (monto/rule/event/metadata)';
  end if;

  -- David, Isaac, José: cero multas; total contexto = 2
  if exists (select 1 from public.obligations
             where context_actor_id = v_ctx::uuid
               and debtor_actor_id in (a_david, a_isaac, a_jose)) then
    raise exception 'R2E FAIL resultado: David/Isaac/José tienen multas que no deberían';
  end if;
  if (select count(*) from public.obligations where context_actor_id = v_ctx::uuid) <> 2 then
    raise exception 'R2E FAIL resultado: deben existir exactamente 2 multas en el contexto';
  end if;

  -- rule_evaluation_id apunta a una evaluación matched de la regla correcta
  if not exists (
    select 1 from public.obligations o
    join public.rule_evaluations re on re.id = (o.metadata->>'rule_evaluation_id')::uuid
    where o.id = v_oblig_moises and re.rule_id = v_rule1::uuid and re.outcome = 'matched'
  ) or not exists (
    select 1 from public.obligations o
    join public.rule_evaluations re on re.id = (o.metadata->>'rule_evaluation_id')::uuid
    where o.id = v_oblig_daniel and re.rule_id = v_rule2::uuid and re.outcome = 'matched'
  ) then
    raise exception 'R2E FAIL resultado: rule_evaluation_id no apunta a la evaluación matched correcta';
  end if;

  -- rule_evaluations: matched (Moisés ×2, Daniel ×2) y not_matched (David, Isaac)
  if (select count(*) from public.rule_evaluations
      where context_actor_id = v_ctx::uuid and outcome = 'matched') <> 4 then
    raise exception 'R2E FAIL evaluaciones: esperaba 4 matched (Moisés ×2 + Daniel ×2)';
  end if;
  if (select count(*) from public.rule_evaluations
      where context_actor_id = v_ctx::uuid and outcome = 'not_matched') <> 2 then
    raise exception 'R2E FAIL evaluaciones: esperaba 2 not_matched (David + Isaac)';
  end if;

  -- activity_events: rule.evaluated, obligation.created, fine.created
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'rule.evaluated') <> 6 then
    raise exception 'R2E FAIL activity: rule.evaluated debe ser 6 (4 matched + 2 not_matched)';
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'obligation.created') <> 2 then
    raise exception 'R2E FAIL activity: obligation.created debe ser 2 (idempotencia no re-emite)';
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'fine.created') <> 2 then
    raise exception 'R2E FAIL activity: fine.created debe ser 2';
  end if;

  -- ═══ Permisos: miembro normal NO puede evaluar reglas sobre otros ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_caught := false;
  begin
    perform public.evaluate_rules_for_event(v_ctx::uuid, 'event.checked_in', a_moises,
      '{"minutes_late": 999, "event_type": "dinner"}'::jsonb, v_event::uuid);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then
    raise exception 'R2E FAIL permisos: miembro normal pudo evaluar reglas sobre otro actor';
  end if;

  -- anon bloqueado
  foreach v_fn in array array[
    'public.create_rule(uuid, text, text, jsonb, jsonb, text, text, int)',
    'public.evaluate_rules_for_event(uuid, text, uuid, jsonb, uuid)'
  ] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') then
      raise exception 'R2E FAIL permisos: anon puede ejecutar %', v_fn;
    end if;
  end loop;

  -- ═══ Cleanup ═══
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_jose, a_david, a_isaac, a_moises, a_daniel],
    array[u_jose, u_david, u_isaac, u_moises, u_daniel]);

  raise notice 'R.2E RULES DoD: PASS (2 reglas, multas Moisés $100 + Daniel $300, idempotencia, permisos)';
end; $$;

revoke all on function public._smoke_r2e_rules_dod() from public, anon, authenticated;

comment on function public._smoke_r2e_rules_dod() is
  'R.2E DoD exacto: reglas tarde→$100 y cancelación same-day→$300 → evaluar Moisés/Daniel → multas correctas con metadata completa → David/Isaac/José sin multa → idempotencia → permisos.';

-- Wrapper para CI (descubre funciones _smoke_mvp2_%)
create or replace function public._smoke_mvp2_r2e_rules_dod()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._smoke_r2e_rules_dod();
end; $$;

revoke all on function public._smoke_mvp2_r2e_rules_dod() from public, anon, authenticated;

comment on function public._smoke_mvp2_r2e_rules_dod() is
  'Wrapper CI del smoke R.2E (_smoke_r2e_rules_dod).';
