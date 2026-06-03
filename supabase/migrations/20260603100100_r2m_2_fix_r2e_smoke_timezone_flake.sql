-- ============================================================================
-- R.2M-2 — FIX: smoke R.2E determinista (flake de timezone en la cancelación)
-- ============================================================================
-- Flake encontrado al verificar R.2M: _smoke_r2e_rules_dod falla si la suite
-- corre entre 06:21–08:21 UTC (00:21–02:21 CDMX).
--
-- Causa: el evento empieza en now()-21min (timezone America/Mexico_City) y
-- Daniel cancela en v_starts - 2 horas. En esa ventana, la cancelación cae en
-- el día ANTERIOR en CDMX → same_day_cancellation = false → la regla de
-- "cancelar mismo día" no matchea → R2E FAIL 3.
--
-- Fix (mismo patrón que R.2D-2): el timestamp de cancelación se acota a la
-- medianoche CDMX del día del evento — nunca cruza el límite de día.
-- Cero cambios de comportamiento del backend; solo el smoke se vuelve
-- determinista a cualquier hora.
-- ============================================================================

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
  -- R.2M-2: la cancelación nunca cruza la medianoche CDMX del día del evento
  -- (antes: v_starts - 2 horas a secas → flake entre 00:21 y 02:21 CDMX)
  perform public.cancel_participation(v_event::uuid, a_daniel,
    greatest(v_starts - interval '2 hours',
             date_trunc('day', v_starts at time zone 'America/Mexico_City') at time zone 'America/Mexico_City'));
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
  'R.2E DoD (R.2M-2: determinista — la cancelación de Daniel se acota al mismo día CDMX del evento).';
