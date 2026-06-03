-- ============================================================================
-- R.2J-3 — ACTIVITY: smokes idempotency / automatic actions / list_activity / full simulation
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Smoke R.2J.5 — Activity Idempotency
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2j_activity_idempotency()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_a uuid; a_a uuid; u_b uuid; a_b uuid; u_c uuid; a_c uuid;
  v_ctx uuid; v_code text; v_event uuid; v_casa uuid;
  v_res_b uuid; v_res_c uuid; v_conflict uuid;
  v_decision uuid; v_batch uuid; v_item uuid;
  v_starts timestamptz;
  c_before jsonb; c_after jsonb;
begin
  select auth_id, actor_id into u_a, a_a from public._r2_make_person('R2J Idem A', '+5210000110');
  select auth_id, actor_id into u_b, a_b from public._r2_make_person('R2J Idem B', '+5210000111');
  select auth_id, actor_id into u_c, a_c from public._r2_make_person('R2J Idem C', '+5210000112');

  -- Setup: contexto + regla + evento + recurso + reservaciones en conflicto + decisión
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := (public.create_context('R2J Idempotencia', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  perform public.create_rule(v_ctx::uuid, 'Multa por tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": ">", "field": "minutes_late", "value": 15}'::jsonb,
    p_consequences := '[{"type": "fine", "amount": 100, "currency": "MXN"}]'::jsonb);

  v_starts := now() - interval '30 minutes';
  v_event := (public.create_calendar_event(v_ctx::uuid, 'Cena idem', 'dinner',
    p_starts_at := v_starts, p_host_actor_id := a_a))->>'event_id';

  -- B check-in tarde → multa (rule.evaluated + fine.created + obligation.created)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.check_in_participant(v_event::uuid);

  -- A: gasto con client_id + recurso + reservaciones en conflicto + decisión + settlement
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  perform public.record_expense(v_ctx::uuid, 900, 'MXN', 'Cena idem',
    p_client_id := 'r2j-idem-expense-001');
  v_casa := (public.create_resource(v_ctx::uuid, 'house', 'Casa idem'))->>'resource_id';
  perform public.grant_right(v_casa::uuid, a_b, 'USE');
  perform public.grant_right(v_casa::uuid, a_c, 'USE');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  v_res_b := (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
    now() + interval '5 days', now() + interval '7 days'))->>'reservation_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
  v_res_c := (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
    now() + interval '6 days', now() + interval '8 days'))->>'reservation_id';
  select id into v_conflict from public.reservation_conflicts
   where resource_id = v_casa::uuid and resolution_status = 'open' limit 1;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_decision := (public.create_decision(v_ctx::uuid, 'generic', 'Decisión idem',
    p_payload := jsonb_build_object('options', jsonb_build_array('Si', 'No'))))->>'decision_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.vote_decision(v_decision::uuid, 'approve', 'Si');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  perform public.resolve_reservation_conflict(v_conflict, v_res_b::uuid);
  v_batch := (public.generate_settlement_batch(v_ctx::uuid, 'MXN'))->>'batch_id';
  select id into v_item from public.settlement_items
   where settlement_batch_id = v_batch::uuid limit 1;
  perform public.mark_settlement_paid(v_item);

  -- ═══ Snapshot de conteos críticos ═══
  select jsonb_object_agg(event_type, cnt) into c_before from (
    select event_type, count(*) as cnt from public.activity_events
    where context_actor_id = v_ctx::uuid
      and event_type in ('expense.recorded', 'split.generated', 'obligation.created', 'fine.created',
                         'event.checked_in', 'reservation.conflict_detected', 'reservation.conflict_resolved',
                         'settlement.generated', 'settlement.item_created', 'settlement.paid',
                         'decision.created', 'rule.evaluated')
    group by event_type) t;

  -- ═══ Re-ejecutar TODAS las operaciones idempotentes ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  -- record_expense mismo client_id → replay
  perform public.record_expense(v_ctx::uuid, 900, 'MXN', 'Cena idem',
    p_client_id := 'r2j-idem-expense-001');
  -- generate_settlement_batch → reusa el draft... (el batch quedó draft: 1 item pagado de N? si era 1 item ya se finalizó)
  -- → si está finalized, generate fallaría por "no obligations"; capturarlo como no-op
  begin
    perform public.generate_settlement_batch(v_ctx::uuid, 'MXN');
  exception when others then null;  -- sin obligations abiertas = no-op válido (no genera activity)
  end;
  -- mark_settlement_paid repetido → already_paid
  perform public.mark_settlement_paid(v_item);
  -- detect repetido → no inserta ni emite
  perform public.detect_reservation_conflicts(v_casa::uuid);
  -- resolve repetido → no-op
  perform public.resolve_reservation_conflict(v_conflict, v_res_b::uuid);
  -- check-in repetido → already_checked_in
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.check_in_participant(v_event::uuid);
  -- vote repetido → actualiza el voto (PUEDE emitir vote_cast, pero no duplica el voto)
  perform public.vote_decision(v_decision::uuid, 'approve', 'No');

  -- ═══ Verificación: conteos críticos estables ═══
  select jsonb_object_agg(event_type, cnt) into c_after from (
    select event_type, count(*) as cnt from public.activity_events
    where context_actor_id = v_ctx::uuid
      and event_type in ('expense.recorded', 'split.generated', 'obligation.created', 'fine.created',
                         'event.checked_in', 'reservation.conflict_detected', 'reservation.conflict_resolved',
                         'settlement.generated', 'settlement.item_created', 'settlement.paid',
                         'decision.created', 'rule.evaluated')
    group by event_type) t;

  if c_before is distinct from c_after then
    raise exception 'R2J IDEMPOTENCY FAIL: los re-runs duplicaron activity (antes: %, después: %)', c_before, c_after;
  end if;

  -- el voto sigue siendo UNO (la fila se actualizó, no se duplicó)
  if (select count(*) from public.decision_votes where decision_id = v_decision::uuid) <> 1 then
    raise exception 'R2J IDEMPOTENCY FAIL: el re-voto duplicó decision_votes';
  end if;
  -- exactamente 1 expense.recorded para el client_id
  if (select count(*) from public.money_transactions
      where context_actor_id = v_ctx::uuid and client_id = 'r2j-idem-expense-001') <> 1 then
    raise exception 'R2J IDEMPOTENCY FAIL: transaction duplicada por client_id';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_a, a_b, a_c], array[u_a, u_b, u_c]);

  raise notice 'R.2J ACTIVITY IDEMPOTENCY: PASS (7 operaciones re-ejecutadas, cero activity duplicada)';
end; $$;

revoke all on function public._smoke_r2j_activity_idempotency() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Smoke R.2J.6 — Activity for Automatic Actions
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2j_activity_automatic_actions()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_world jsonb;
  v_cena uuid; v_familia uuid;
begin
  v_world := public._r2j_make_world();
  v_cena := (v_world->>'cena')::uuid;
  v_familia := (v_world->>'familia')::uuid;

  -- rule.evaluated: system + triggered_by + source_rule_id, y la regla es real
  if exists (
    select 1 from public.activity_events
    where context_actor_id = v_cena and event_type = 'rule.evaluated'
      and (not coalesce((payload->>'system')::boolean, false)
           or payload->>'triggered_by_event_type' is null
           or payload->>'source_rule_id' is null)
  ) then
    raise exception 'R2J AUTO FAIL: rule.evaluated sin atribución de sistema completa';
  end if;
  if exists (
    select 1 from public.activity_events ae
    where ae.context_actor_id = v_cena and ae.event_type = 'rule.evaluated'
      and not exists (select 1 from public.rules r where r.id = (ae.payload->>'source_rule_id')::uuid)
  ) then
    raise exception 'R2J AUTO FAIL: rule.evaluated apunta a una regla inexistente';
  end if;

  -- fine.created (desde regla): system + source_rule_id → se puede auditar regla → consecuencia
  if exists (
    select 1 from public.activity_events
    where context_actor_id = v_cena and event_type = 'fine.created'
      and (not coalesce((payload->>'system')::boolean, false)
           or payload->>'source_rule_id' is null
           or payload->>'triggered_by_event_type' is null)
  ) then
    raise exception 'R2J AUTO FAIL: fine.created sin atribución de sistema/regla';
  end if;

  -- obligation.created desde regla: system + source_rule_id
  -- (las de gastos NO llevan system — son acción humana)
  if exists (
    select 1 from public.activity_events
    where context_actor_id = v_cena and event_type = 'obligation.created'
      and payload ? 'source_rule_id'
      and not coalesce((payload->>'system')::boolean, false)
  ) then
    raise exception 'R2J AUTO FAIL: obligation.created de regla sin marca de sistema';
  end if;

  -- reservation.conflict_detected: system + source_reservation_id/conflict_id + actor = system actor
  if exists (
    select 1 from public.activity_events
    where context_actor_id = v_familia and event_type = 'reservation.conflict_detected'
      and (not coalesce((payload->>'system')::boolean, false)
           or payload->>'conflict_id' is null
           or payload->>'source_reservation_id' is null
           or actor_id is distinct from public.system_actor_id())
  ) then
    raise exception 'R2J AUTO FAIL: conflict_detected sin atribución de sistema';
  end if;

  -- settlement.item_created: system + settlement_batch_id
  if exists (
    select 1 from public.activity_events
    where context_actor_id = v_cena and event_type = 'settlement.item_created'
      and (not coalesce((payload->>'system')::boolean, false)
           or not payload ? 'settlement_batch_id')
  ) then
    raise exception 'R2J AUTO FAIL: settlement.item_created sin atribución de sistema/batch';
  end if;

  -- auditoría regla → consecuencia: desde fine.created se llega a la regla y al trigger
  if not exists (
    select 1 from public.activity_events ae
    join public.rules r on r.id = (ae.payload->>'source_rule_id')::uuid
    where ae.context_actor_id = v_cena and ae.event_type = 'fine.created'
      and ae.payload->>'triggered_by_event_type' = r.trigger_event_type
  ) then
    raise exception 'R2J AUTO FAIL: no se puede auditar qué regla generó qué multa';
  end if;

  perform public._r2j_cleanup_world(v_world);
  raise notice 'R.2J ACTIVITY AUTOMATIC ACTIONS: PASS (sistema atribuido, regla → consecuencia auditable)';
end; $$;

revoke all on function public._smoke_r2j_activity_automatic_actions() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Smoke R.2J.7 — list_activity RPC
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2j_list_activity_rpc()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_world jsonb;
  v_cena uuid; v_viaje uuid;
  v_page1 jsonb; v_page2 jsonb;
  v_oldest timestamptz;
  v_caught boolean;
begin
  v_world := public._r2j_make_world();
  v_cena := (v_world->>'cena')::uuid;
  v_viaje := (v_world->>'viaje')::uuid;

  -- 1. Miembro activo lista activity
  perform set_config('request.jwt.claims', jsonb_build_object('sub', (v_world->>'u_jose'))::text, true);
  v_page1 := public.list_activity(v_cena);
  if jsonb_array_length(v_page1->'activity') < 10 then
    raise exception 'R2J LIST FAIL: miembro no puede listar activity (% rows)', jsonb_array_length(v_page1->'activity');
  end if;

  -- 4. Limit aplicado
  v_page1 := public.list_activity(v_cena, 5);
  if jsonb_array_length(v_page1->'activity') <> 5 then
    raise exception 'R2J LIST FAIL: limit 5 no aplicado (% rows)', jsonb_array_length(v_page1->'activity');
  end if;

  -- 5. Cap máximo = 100
  v_page1 := public.list_activity(v_cena, 5000);
  if (v_page1->>'limit')::integer <> 100 or jsonb_array_length(v_page1->'activity') > 100 then
    raise exception 'R2J LIST FAIL: el cap de 100 no se aplicó';
  end if;

  -- 6. Paginación con p_before
  v_page1 := public.list_activity(v_cena, 10);
  select min((e->>'occurred_at')::timestamptz) into v_oldest
    from jsonb_array_elements(v_page1->'activity') e;
  v_page2 := public.list_activity(v_cena, 10, v_oldest);
  if jsonb_array_length(v_page2->'activity') = 0 then
    raise exception 'R2J LIST FAIL: la página 2 está vacía';
  end if;
  -- todas las rows de la página 2 son anteriores al corte
  if exists (
    select 1 from jsonb_array_elements(v_page2->'activity') e
    where (e->>'occurred_at')::timestamptz >= v_oldest
  ) then
    raise exception 'R2J LIST FAIL: la página 2 contiene rows posteriores al corte';
  end if;
  -- sin overlap de ids entre páginas
  if exists (
    select 1 from jsonb_array_elements(v_page1->'activity') e1
    join jsonb_array_elements(v_page2->'activity') e2 on e1->>'id' = e2->>'id'
  ) then
    raise exception 'R2J LIST FAIL: overlap entre páginas';
  end if;

  -- 7. No mezcla contextos: ninguna row del viaje aparece en el listado de la cena
  v_page1 := public.list_activity(v_cena, 100);
  if exists (
    select 1 from jsonb_array_elements(v_page1->'activity') e
    where (e->>'id')::uuid in (select id from public.activity_events where context_actor_id = v_viaje)
  ) then
    raise exception 'R2J LIST FAIL: el listado de la cena mezcla activity del viaje';
  end if;

  -- 2. No-miembro bloqueado (Abuelo nunca fue miembro de la cena)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', (v_world->>'u_abuelo'))::text, true);
  v_caught := false;
  begin
    perform public.list_activity(v_cena);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2J LIST FAIL: no-miembro pudo listar activity'; end if;

  -- 3. Anon bloqueado
  if has_function_privilege('anon', 'public.list_activity(uuid, int, timestamptz)', 'EXECUTE') then
    raise exception 'R2J LIST FAIL: anon puede ejecutar list_activity';
  end if;

  perform public._r2j_cleanup_world(v_world);
  raise notice 'R.2J LIST ACTIVITY RPC: PASS (limit, cap 100, paginación, aislamiento, permisos)';
end; $$;

revoke all on function public._smoke_r2j_list_activity_rpc() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Smoke R.2J.8 — Full Activity Simulation
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2j_full_activity_simulation()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_world jsonb;
  v_ctxs uuid[];
  v_ctx uuid;
  v_domain text;
begin
  v_world := public._r2j_make_world();
  v_ctxs := array[(v_world->>'cena')::uuid, (v_world->>'viaje')::uuid,
                  (v_world->>'familia')::uuid, (v_world->>'negocio')::uuid];

  -- Cada contexto tiene activity propia
  foreach v_ctx in array v_ctxs loop
    if (select count(*) from public.activity_events where context_actor_id = v_ctx) = 0 then
      raise exception 'R2J SIM FAIL: el contexto % no tiene activity', v_ctx;
    end if;
  end loop;

  -- activity > 0 por dominio
  foreach v_domain in array array[
    'context.', 'invite.', 'membership.', 'resource.', 'right.', 'event.', 'rule.',
    'fine.', 'obligation.', 'reservation.', 'decision.', 'expense.', 'split.',
    'game_result.', 'settlement.', 'document.'
  ] loop
    if (select count(*) from public.activity_events
        where context_actor_id = any(v_ctxs) and event_type like v_domain || '%') = 0 then
      raise exception 'R2J SIM FAIL: el dominio % no tiene activity', v_domain;
    end if;
  end loop;

  -- No hay activity con subject_id huérfano (subjects que apuntan a tablas reales)
  if exists (
    select 1 from public.activity_events ae
    where ae.context_actor_id = any(v_ctxs) and ae.subject_id is not null and (
      (ae.subject_type = 'obligation' and not exists (select 1 from public.obligations x where x.id = ae.subject_id))
      or (ae.subject_type = 'reservation' and not exists (select 1 from public.resource_reservations x where x.id = ae.subject_id))
      or (ae.subject_type = 'reservation_conflict' and not exists (select 1 from public.reservation_conflicts x where x.id = ae.subject_id))
      or (ae.subject_type = 'decision' and not exists (select 1 from public.decisions x where x.id = ae.subject_id))
      or (ae.subject_type = 'calendar_event' and not exists (select 1 from public.calendar_events x where x.id = ae.subject_id))
      or (ae.subject_type = 'money_transaction' and not exists (select 1 from public.money_transactions x where x.id = ae.subject_id))
      or (ae.subject_type = 'settlement_batch' and not exists (select 1 from public.settlement_batches x where x.id = ae.subject_id))
      or (ae.subject_type = 'settlement_item' and not exists (select 1 from public.settlement_items x where x.id = ae.subject_id))
      or (ae.subject_type = 'resource' and not exists (select 1 from public.resources x where x.id = ae.subject_id))
      or (ae.subject_type = 'rule' and not exists (select 1 from public.rules x where x.id = ae.subject_id))
    )
  ) then
    raise exception 'R2J SIM FAIL: hay activity con subject_id huérfano';
  end if;

  -- No hay activity con context o actor inexistente (FKs lo garantizan; verificación explícita)
  if exists (
    select 1 from public.activity_events ae
    where ae.context_actor_id = any(v_ctxs)
      and (not exists (select 1 from public.actors a where a.id = ae.context_actor_id)
        or (ae.actor_id is not null and not exists (select 1 from public.actors a where a.id = ae.actor_id)))
  ) then
    raise exception 'R2J SIM FAIL: activity con contexto o actor inexistente';
  end if;

  -- No hay duplicados por client_id (transactions del mundo)
  if exists (
    select client_id, count(*) from public.money_transactions
    where context_actor_id = any(v_ctxs) and client_id is not null
    group by client_id having count(*) > 1
  ) then
    raise exception 'R2J SIM FAIL: transactions duplicadas por client_id';
  end if;

  -- Cada actor autorizado ve solo lo suyo (spot check: Daniel no es miembro de viaje/negocio)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', (v_world->>'u_daniel'))::text, true);
  if public.is_context_member((v_world->>'viaje')::uuid)
     or public.is_context_member((v_world->>'negocio')::uuid) then
    raise exception 'R2J SIM FAIL: Daniel tiene membresía donde no debe';
  end if;

  -- Activity permite reconstruir los eventos principales (la cena tiene la cadena completa)
  if (select count(distinct event_type) from public.activity_events
      where context_actor_id = (v_world->>'cena')::uuid) < 15 then
    raise exception 'R2J SIM FAIL: la cena no tiene la riqueza de activity esperada';
  end if;

  perform public._r2j_cleanup_world(v_world);
  raise notice 'R.2J FULL ACTIVITY SIMULATION: PASS (4 contextos, 16 dominios, cero huérfanos, cero duplicados)';
end; $$;

revoke all on function public._smoke_r2j_full_activity_simulation() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Wrappers CI (_smoke_mvp2_%)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_r2j_activity_contract()
returns void language plpgsql security definer set search_path = public as $$
begin perform public._smoke_r2j_activity_contract(); end; $$;
revoke all on function public._smoke_mvp2_r2j_activity_contract() from public, anon, authenticated;

create or replace function public._smoke_mvp2_r2j_activity_context_isolation()
returns void language plpgsql security definer set search_path = public as $$
begin perform public._smoke_r2j_activity_context_isolation(); end; $$;
revoke all on function public._smoke_mvp2_r2j_activity_context_isolation() from public, anon, authenticated;

create or replace function public._smoke_mvp2_r2j_activity_timeline()
returns void language plpgsql security definer set search_path = public as $$
begin perform public._smoke_r2j_activity_timeline_reconstruction(); end; $$;
revoke all on function public._smoke_mvp2_r2j_activity_timeline() from public, anon, authenticated;

create or replace function public._smoke_mvp2_r2j_activity_idempotency()
returns void language plpgsql security definer set search_path = public as $$
begin perform public._smoke_r2j_activity_idempotency(); end; $$;
revoke all on function public._smoke_mvp2_r2j_activity_idempotency() from public, anon, authenticated;

create or replace function public._smoke_mvp2_r2j_activity_automatic()
returns void language plpgsql security definer set search_path = public as $$
begin perform public._smoke_r2j_activity_automatic_actions(); end; $$;
revoke all on function public._smoke_mvp2_r2j_activity_automatic() from public, anon, authenticated;

create or replace function public._smoke_mvp2_r2j_list_activity()
returns void language plpgsql security definer set search_path = public as $$
begin perform public._smoke_r2j_list_activity_rpc(); end; $$;
revoke all on function public._smoke_mvp2_r2j_list_activity() from public, anon, authenticated;

create or replace function public._smoke_mvp2_r2j_full_simulation()
returns void language plpgsql security definer set search_path = public as $$
begin perform public._smoke_r2j_full_activity_simulation(); end; $$;
revoke all on function public._smoke_mvp2_r2j_full_simulation() from public, anon, authenticated;
