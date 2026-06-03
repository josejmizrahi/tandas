-- ============================================================================
-- R.2J-2 — ACTIVITY: world builder compartido + smokes contract / isolation / timeline
-- ============================================================================
-- Los 7 smokes de R.2J comparten un "mundo" reproducible: 4 contextos (Cena
-- Semanal Amigos, Viaje Japón, Familia Mizrahi, Negocio Valle), 7 personas y
-- actividad real en todos los dominios (membership, resources, rights, events,
-- rules, reservations, decisions, money, settlement, documents).
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. World builder
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._r2j_make_world()
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid; u_david uuid; a_david uuid; u_isaac uuid; a_isaac uuid;
  u_moises uuid; a_moises uuid; u_daniel uuid; a_daniel uuid; u_abuelo uuid; a_abuelo uuid;
  u_out uuid; a_out uuid;
  v_cena uuid; v_viaje uuid; v_familia uuid; v_negocio uuid;
  v_code text; v_starts timestamptz;
  v_event uuid; v_batch uuid; v_casa uuid; v_terreno uuid;
  v_res_david uuid; v_res_isaac uuid; v_res_extra uuid; v_conflict uuid;
  v_decision uuid; v_right_moises uuid;
  v_item record;
begin
  -- ═══ Personas ═══
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2J', '+5210000100');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2J', '+5210000101');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2J', '+5210000102');
  select auth_id, actor_id into u_moises, a_moises from public._r2_make_person('Moisés R2J', '+5210000103');
  select auth_id, actor_id into u_daniel, a_daniel from public._r2_make_person('Daniel R2J', '+5210000104');
  select auth_id, actor_id into u_abuelo, a_abuelo from public._r2_make_person('Abuelo R2J', '+5210000105');
  select auth_id, actor_id into u_out, a_out from public._r2_make_person('Outsider R2J', '+5210000106');

  -- ═══ Contextos + memberships ═══
  -- Cena Semanal Amigos: José (founder) + David, Isaac, Moisés, Daniel (+ outsider temporal)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_cena := (public.create_context('Cena Semanal Amigos', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_cena::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.join_by_invite_code(v_code);
  -- el outsider entra y luego es removido → membership.removed sin afectar a los 5 core
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Viaje Japón: José (founder) + David, Isaac
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_viaje := (public.create_context('Viaje Japón', 'collective', 'trip'))->>'context_actor_id';
  v_code := (public.create_invite(v_viaje::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Familia Mizrahi: Abuelo (founder) + José, David, Isaac, Moisés, Daniel
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_familia := (public.create_context('Familia Mizrahi', 'collective', 'family'))->>'context_actor_id';
  v_code := (public.create_invite(v_familia::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Negocio Valle: José (founder) + David
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_negocio := (public.create_context('Negocio Valle', 'collective', 'company'))->>'context_actor_id';
  v_code := (public.create_invite(v_negocio::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- ═══ CENA: reglas → evento → RSVPs → check-ins → multas → gasto → juego → doc → settlement → remove ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.create_rule(v_cena::uuid, 'Multa por llegar tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": ">", "field": "minutes_late", "value": 15}]}'::jsonb,
    p_consequences := '[{"type": "create_obligation", "obligation_type": "fine", "amount": 100, "currency": "MXN", "reason": "late_arrival"}]'::jsonb);
  perform public.create_rule(v_cena::uuid, 'Multa por cancelar mismo día',
    p_trigger_event_type := 'event.participation_cancelled',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": "=", "field": "same_day_cancellation", "value": true}]}'::jsonb,
    p_consequences := '[{"type": "create_obligation", "obligation_type": "fine", "amount": 300, "currency": "MXN", "reason": "same_day_cancellation"}]'::jsonb);

  v_starts := now() - interval '21 minutes';
  v_event := (public.create_calendar_event(v_cena::uuid, 'Cena miércoles', 'dinner',
    p_starts_at := v_starts, p_ends_at := v_starts + interval '3 hours',
    p_timezone := 'America/Mexico_City', p_host_actor_id := a_david))->>'event_id';

  -- RSVPs ×5
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');

  -- Check-ins (David host: él, José, Isaac) + cancelación de Daniel + Moisés tarde
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.check_in_participant(v_event::uuid, p_checked_in_at := v_starts);
  perform public.check_in_participant(v_event::uuid, a_jose, v_starts + interval '5 minutes');
  perform public.check_in_participant(v_event::uuid, a_isaac, v_starts + interval '12 minutes');
  perform public.cancel_participation(v_event::uuid, a_daniel, v_starts);  -- multa $300
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.check_in_participant(v_event::uuid);                       -- late → multa $100

  -- Gasto + juego + documento
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.record_expense(v_cena::uuid, 1300, 'MXN', 'Pizza, cerveza y botanas',
    p_split_with := array[a_david, a_jose, a_isaac, a_moises],
    p_event_id := v_event::uuid, p_client_id := 'r2j-cena-expense-001',
    p_excluded_actor_ids := array[a_daniel]);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.record_game_result(v_cena::uuid, v_event::uuid, 'Catan', a_moises, a_daniel, 250, 'MXN', 'r2j-catan-001');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.register_document('Recibo de la cena', p_context_actor_id := v_cena::uuid);

  -- Settlement completo
  v_batch := (public.generate_settlement_batch(v_cena::uuid, 'MXN'))->>'batch_id';
  for v_item in select id from public.settlement_items
                 where settlement_batch_id = v_batch::uuid and status = 'pending' loop
    perform public.mark_settlement_paid(v_item.id);
  end loop;

  -- Remoción (outsider) → membership.removed
  perform public.remove_member(v_cena::uuid, a_out, 'salida del grupo');

  -- ═══ FAMILIA: recursos + rights + reservaciones con conflicto + cancelación ═══
  -- (los recursos se crean EN el contexto Familia → la activity queda en la Familia)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_casa := (public.create_resource(v_familia::uuid, 'house', 'Casa Valle'))->>'resource_id';
  v_terreno := (public.create_resource(v_familia::uuid, 'property', 'Terreno Valle'))->>'resource_id';
  perform public.grant_right(v_casa::uuid, a_david, 'USE');
  perform public.grant_right(v_casa::uuid, a_isaac, 'USE');
  -- right otorgado y revocado → right.revoked
  v_right_moises := (public.grant_right(v_casa::uuid, a_moises, 'USE'))->>'right_id';
  perform public.revoke_right(v_right_moises::uuid);

  -- Conflicto David vs Isaac → resolución a favor de Isaac → Isaac confirma
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_res_david := (public.request_resource_reservation(v_casa::uuid, v_familia::uuid,
    '2026-07-10 16:00-06'::timestamptz, '2026-07-12 18:00-06'::timestamptz))->>'reservation_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_res_isaac := (public.request_resource_reservation(v_casa::uuid, v_familia::uuid,
    '2026-07-10 16:00-06'::timestamptz, '2026-07-12 18:00-06'::timestamptz))->>'reservation_id';
  select id into v_conflict from public.reservation_conflicts
   where resource_id = v_casa::uuid and resolution_status = 'open' limit 1;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  perform public.resolve_reservation_conflict(v_conflict, v_res_isaac::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.confirm_reservation(v_res_isaac::uuid);
  -- reservación cancelada → reservation.cancelled
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_res_extra := (public.request_resource_reservation(v_casa::uuid, v_familia::uuid,
    '2026-07-17 16:00-06'::timestamptz, '2026-07-19 18:00-06'::timestamptz))->>'reservation_id';
  perform public.cancel_reservation(v_res_extra::uuid);

  -- ═══ NEGOCIO: decisión votada y ejecutada + gasto ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_decision := (public.create_decision(v_negocio::uuid, 'resource_purchase', '¿Compramos el terreno contiguo?',
    p_payload := jsonb_build_object('options', jsonb_build_array('Comprar', 'Esperar'))))->>'decision_id';
  perform public.vote_decision(v_decision::uuid, 'approve', 'Comprar');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.vote_decision(v_decision::uuid, 'approve', 'Comprar');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.close_decision(v_decision::uuid);
  perform public.execute_decision(v_decision::uuid);
  perform public.record_expense(v_negocio::uuid, 5000, 'MXN', 'Anticipo terreno',
    p_split_with := array[a_jose, a_david], p_client_id := 'r2j-negocio-anticipo-001');

  -- ═══ VIAJE: gasto hotel ═══
  perform public.record_expense(v_viaje::uuid, 9000, 'MXN', 'Hotel Tokio',
    p_client_id := 'r2j-viaje-hotel-001');

  perform set_config('request.jwt.claims', null, true);

  return jsonb_build_object(
    'cena', v_cena, 'viaje', v_viaje, 'familia', v_familia, 'negocio', v_negocio,
    'jose', a_jose, 'david', a_david, 'isaac', a_isaac, 'moises', a_moises,
    'daniel', a_daniel, 'abuelo', a_abuelo, 'outsider', a_out,
    'u_jose', u_jose, 'u_david', u_david, 'u_isaac', u_isaac, 'u_moises', u_moises,
    'u_daniel', u_daniel, 'u_abuelo', u_abuelo, 'u_outsider', u_out,
    'cena_event', v_event, 'cena_batch', v_batch,
    'casa', v_casa, 'terreno', v_terreno,
    'conflict', v_conflict, 'res_david', v_res_david, 'res_isaac', v_res_isaac,
    'decision', v_decision);
end; $$;

revoke all on function public._r2j_make_world() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Cleanup del mundo
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._r2j_cleanup_world(p_world jsonb)
returns void
language plpgsql security definer set search_path = public, auth
as $$
begin
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context((p_world->>'negocio')::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context((p_world->>'viaje')::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context((p_world->>'familia')::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context((p_world->>'cena')::uuid,
    array[(p_world->>'jose')::uuid, (p_world->>'david')::uuid, (p_world->>'isaac')::uuid,
          (p_world->>'moises')::uuid, (p_world->>'daniel')::uuid, (p_world->>'abuelo')::uuid,
          (p_world->>'outsider')::uuid],
    array[(p_world->>'u_jose')::uuid, (p_world->>'u_david')::uuid, (p_world->>'u_isaac')::uuid,
          (p_world->>'u_moises')::uuid, (p_world->>'u_daniel')::uuid, (p_world->>'u_abuelo')::uuid,
          (p_world->>'u_outsider')::uuid]);
end; $$;

revoke all on function public._r2j_cleanup_world(jsonb) from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Smoke R.2J.1+R.2J.2 — Activity Contract + Shape
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2j_activity_contract()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_world jsonb;
  v_ctxs uuid[];
  v_type text;
  v_missing text[] := array[]::text[];
begin
  v_world := public._r2j_make_world();
  v_ctxs := array[(v_world->>'cena')::uuid, (v_world->>'viaje')::uuid,
                  (v_world->>'familia')::uuid, (v_world->>'negocio')::uuid];

  -- ═══ R.2J.1: las activities mínimas del contrato existen ═══
  foreach v_type in array array[
    'context.created', 'invite.created', 'membership.joined', 'membership.removed',
    'resource.created', 'right.granted', 'right.revoked',
    'event.created', 'event.rsvp_updated', 'event.checked_in', 'event.participation_cancelled',
    'rule.created', 'rule.evaluated', 'fine.created', 'obligation.created',
    'reservation.requested', 'reservation.conflict_detected', 'reservation.conflict_resolved',
    'reservation.approved', 'reservation.rejected', 'reservation.confirmed', 'reservation.cancelled',
    'decision.created', 'decision.vote_cast', 'decision.closed', 'decision.executed',
    'expense.recorded', 'split.generated', 'game_result.recorded',
    'settlement.generated', 'settlement.item_created', 'settlement.paid',
    'document.created'
  ] loop
    if not exists (select 1 from public.activity_events
                   where context_actor_id = any(v_ctxs) and event_type = v_type) then
      v_missing := v_missing || v_type;
    end if;
  end loop;
  if array_length(v_missing, 1) > 0 then
    raise exception 'R2J CONTRACT FAIL: faltan activities: %', v_missing;
  end if;
  -- deferred explícito (sin RPC de archivado de documentos — fuera de scope MVP)
  raise notice 'R2J contract: document.archived = DEFERRED (no existe RPC archive_document)';

  -- ═══ R.2J.2: shape de cada activity del mundo ═══
  -- 1-4: campos obligatorios
  if exists (select 1 from public.activity_events where context_actor_id = any(v_ctxs)
             and (event_type is null or btrim(event_type) = '' or payload is null
                  or occurred_at is null or created_at is null)) then
    raise exception 'R2J SHAPE FAIL: activity con campos obligatorios vacíos';
  end if;
  -- 5: reservation.* → subject reservation/reservation_conflict
  if exists (select 1 from public.activity_events where context_actor_id = any(v_ctxs)
             and event_type like 'reservation.%'
             and subject_type not in ('reservation', 'reservation_conflict')) then
    raise exception 'R2J SHAPE FAIL: reservation.* con subject_type incorrecto';
  end if;
  -- 6: decision.* → decision_id o subject decision
  if exists (select 1 from public.activity_events where context_actor_id = any(v_ctxs)
             and event_type like 'decision.%'
             and decision_id is null and subject_type <> 'decision') then
    raise exception 'R2J SHAPE FAIL: decision.* sin decision_id ni subject decision';
  end if;
  -- 7: obligation.* / fine.* → obligation_id
  if exists (select 1 from public.activity_events where context_actor_id = any(v_ctxs)
             and (event_type like 'obligation.%' or event_type like 'fine.%')
             and obligation_id is null) then
    raise exception 'R2J SHAPE FAIL: obligation/fine sin obligation_id';
  end if;
  -- 8: resource.* / right.* → resource_id
  if exists (select 1 from public.activity_events where context_actor_id = any(v_ctxs)
             and (event_type like 'resource.%' or event_type like 'right.%')
             and resource_id is null) then
    raise exception 'R2J SHAPE FAIL: resource/right sin resource_id';
  end if;
  -- 9: settlement.* → payload con batch o item id
  if exists (select 1 from public.activity_events where context_actor_id = any(v_ctxs)
             and event_type like 'settlement.%'
             and not (payload ? 'settlement_batch_id' or payload ? 'settlement_item_id')) then
    raise exception 'R2J SHAPE FAIL: settlement.* sin batch/item id en payload';
  end if;
  -- 10: actor_id siempre presente (humano o system actor) o payload.system
  if exists (select 1 from public.activity_events where context_actor_id = any(v_ctxs)
             and actor_id is null
             and not coalesce((payload->>'system')::boolean, false)) then
    raise exception 'R2J SHAPE FAIL: activity sin actor_id ni payload.system';
  end if;

  perform public._r2j_cleanup_world(v_world);
  raise notice 'R.2J ACTIVITY CONTRACT + SHAPE: PASS (33 event types, 10 reglas de shape)';
end; $$;

revoke all on function public._smoke_r2j_activity_contract() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Smoke R.2J.3 — Activity Context Isolation
-- ────────────────────────────────────────────────────────────────────────────
-- Evalúa la expresión de la policy RLS (la misma lógica, con el JWT de cada
-- actor) + verifica grants de anon. La visibilidad de cada actor sobre cada
-- contexto debe coincidir exactamente con sus membresías.
create or replace function public._smoke_r2j_activity_context_isolation()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_world jsonb;
  v_visible boolean;
  r record;
begin
  v_world := public._r2j_make_world();

  -- matriz de visibilidad esperada (actor × contexto → puede ver como MIEMBRO)
  for r in
    select * from (values
      -- José es miembro de los 4
      ('u_jose',  'cena',    true), ('u_jose',  'viaje',   true), ('u_jose',  'familia', true), ('u_jose',  'negocio', true),
      -- Daniel: Cena y Familia sí; Viaje y Negocio no
      ('u_daniel','cena',    true), ('u_daniel','familia', true), ('u_daniel','viaje',   false), ('u_daniel','negocio', false),
      -- Isaac: Cena, Viaje, Familia sí; Negocio no
      ('u_isaac', 'cena',    true), ('u_isaac', 'viaje',   true), ('u_isaac', 'familia', true), ('u_isaac', 'negocio', false),
      -- Abuelo: solo Familia
      ('u_abuelo','familia', true), ('u_abuelo','cena',    false), ('u_abuelo','viaje',  false), ('u_abuelo','negocio', false),
      -- no-miembro de todo (el outsider fue removido de la cena)
      ('u_outsider','viaje', false), ('u_outsider','familia', false), ('u_outsider','negocio', false)
    ) t(who, ctx, expected)
  loop
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', (v_world->>r.who))::text, true);

    -- la misma expresión de la policy activity_select, restringida a "miembro del contexto"
    v_visible := public.is_context_member((v_world->>r.ctx)::uuid);

    if v_visible is distinct from r.expected then
      raise exception 'R2J ISOLATION FAIL: % membresía sobre % = % (esperaba %)', r.who, r.ctx, v_visible, r.expected;
    end if;

    -- y la activity del contexto solo es visible (como miembro) cuando expected = true
    if r.expected then
      if not exists (
        select 1 from public.activity_events ae
        where ae.context_actor_id = (v_world->>r.ctx)::uuid
          and (ae.actor_id = public.current_actor_id()
               or public.is_context_member(ae.context_actor_id))
        limit 1
      ) then
        raise exception 'R2J ISOLATION FAIL: % no ve activity de % siendo miembro', r.who, r.ctx;
      end if;
    else
      -- como NO miembro: ninguna activity del contexto es visible vía membresía;
      -- solo podría ver rows donde él mismo es el actor o está involucrado
      if exists (
        select 1 from public.activity_events ae
        where ae.context_actor_id = (v_world->>r.ctx)::uuid
          and ae.actor_id <> public.current_actor_id()
          and public.is_context_member(ae.context_actor_id)
          and (ae.obligation_id is null or not exists (
            select 1 from public.obligations o where o.id = ae.obligation_id
              and public.current_actor_id() in (o.debtor_actor_id, o.creditor_actor_id)))
        limit 1
      ) then
        raise exception 'R2J ISOLATION FAIL: % ve activity ajena de % sin ser miembro', r.who, r.ctx;
      end if;
    end if;
  end loop;

  -- la policy RLS existe y es la v2 (con obligations y rights — no "select true")
  if not exists (
    select 1 from pg_policy
    where polrelid = 'public.activity_events'::regclass and polname = 'activity_select'
      and pg_get_expr(polqual, polrelid) ilike '%is_context_member%'
      and pg_get_expr(polqual, polrelid) ilike '%obligation%'
      and pg_get_expr(polqual, polrelid) ilike '%resource_rights%'
  ) then
    raise exception 'R2J ISOLATION FAIL: la policy RLS no es la v2 rights-aware';
  end if;

  -- anon: sin SELECT en la tabla, sin INSERT/UPDATE/DELETE para nadie vía API
  if has_table_privilege('anon', 'public.activity_events', 'SELECT') then
    raise exception 'R2J ISOLATION FAIL: anon tiene SELECT en activity_events';
  end if;
  if has_table_privilege('authenticated', 'public.activity_events', 'INSERT')
     or has_table_privilege('authenticated', 'public.activity_events', 'UPDATE')
     or has_table_privilege('authenticated', 'public.activity_events', 'DELETE') then
    raise exception 'R2J ISOLATION FAIL: authenticated puede escribir activity_events directamente';
  end if;

  perform public._r2j_cleanup_world(v_world);
  raise notice 'R.2J ACTIVITY CONTEXT ISOLATION: PASS (matriz de visibilidad + RLS v2 + anon bloqueado)';
end; $$;

revoke all on function public._smoke_r2j_activity_context_isolation() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Smoke R.2J.4 — Activity Timeline Reconstruction
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2j_activity_timeline_reconstruction()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_world jsonb;
  v_cena uuid;
  t_ctx timestamptz; t_join timestamptz; t_event timestamptz; t_rsvp timestamptz;
  t_checkin timestamptz; t_fine timestamptz; t_expense timestamptz;
  t_settle timestamptz; t_paid timestamptz;
begin
  v_world := public._r2j_make_world();
  v_cena := (v_world->>'cena')::uuid;

  -- ═══ Hitos de la timeline (occurred_at avanza con clock_timestamp) ═══
  select occurred_at into t_ctx from public.activity_events
   where context_actor_id = v_cena and event_type = 'context.created';
  select min(occurred_at) into t_join from public.activity_events
   where context_actor_id = v_cena and event_type = 'membership.joined';
  select occurred_at into t_event from public.activity_events
   where context_actor_id = v_cena and event_type = 'event.created';
  select min(occurred_at) into t_rsvp from public.activity_events
   where context_actor_id = v_cena and event_type = 'event.rsvp_updated';
  select min(occurred_at) into t_checkin from public.activity_events
   where context_actor_id = v_cena and event_type = 'event.checked_in';
  select min(occurred_at) into t_fine from public.activity_events
   where context_actor_id = v_cena and event_type = 'fine.created';
  select min(occurred_at) into t_expense from public.activity_events
   where context_actor_id = v_cena and event_type = 'expense.recorded';
  select occurred_at into t_settle from public.activity_events
   where context_actor_id = v_cena and event_type = 'settlement.generated';
  select max(occurred_at) into t_paid from public.activity_events
   where context_actor_id = v_cena and event_type = 'settlement.paid';

  -- no faltan eventos críticos
  if t_ctx is null or t_join is null or t_event is null or t_rsvp is null
     or t_checkin is null or t_fine is null or t_expense is null
     or t_settle is null or t_paid is null then
    raise exception 'R2J TIMELINE FAIL: falta un evento crítico en la timeline';
  end if;

  -- la timeline está ordenada (estrictamente: cada hito después del anterior)
  if not (t_ctx < t_join and t_join < t_event and t_event < t_rsvp
          and t_rsvp < t_checkin and t_checkin < t_fine
          and t_fine < t_expense and t_expense < t_settle and t_settle < t_paid) then
    raise exception 'R2J TIMELINE FAIL: la timeline no está en orden (ctx=%, join=%, event=%, rsvp=%, checkin=%, fine=%, expense=%, settle=%, paid=%)',
      t_ctx, t_join, t_event, t_rsvp, t_checkin, t_fine, t_expense, t_settle, t_paid;
  end if;

  -- conteos mínimos de la cena
  if (select count(*) from public.activity_events where context_actor_id = v_cena and event_type = 'membership.joined') < 5
     or (select count(*) from public.activity_events where context_actor_id = v_cena and event_type = 'event.rsvp_updated') < 5
     or (select count(*) from public.activity_events where context_actor_id = v_cena and event_type = 'event.checked_in') <> 4
     or (select count(*) from public.activity_events where context_actor_id = v_cena and event_type = 'event.participation_cancelled') <> 1
     or (select count(*) from public.activity_events where context_actor_id = v_cena and event_type = 'fine.created') <> 2 then
    raise exception 'R2J TIMELINE FAIL: conteos de eventos de la cena incorrectos';
  end if;

  -- cada activity de la cena tiene actor_id (humano o system)
  if exists (select 1 from public.activity_events
             where context_actor_id = v_cena and actor_id is null) then
    raise exception 'R2J TIMELINE FAIL: activity de la cena sin actor';
  end if;

  -- cada obligation activity apunta a una obligation real
  if exists (
    select 1 from public.activity_events ae
    where ae.context_actor_id = v_cena and ae.obligation_id is not null
      and not exists (select 1 from public.obligations o where o.id = ae.obligation_id)
  ) then
    raise exception 'R2J TIMELINE FAIL: obligation activity huérfana';
  end if;

  -- cada settlement activity apunta a un batch/item real en payload
  if exists (
    select 1 from public.activity_events ae
    where ae.context_actor_id = v_cena and ae.event_type like 'settlement.%'
      and not (
        (ae.payload ? 'settlement_batch_id' and exists (
          select 1 from public.settlement_batches b where b.id = (ae.payload->>'settlement_batch_id')::uuid))
        or (ae.payload ? 'settlement_item_id' and exists (
          select 1 from public.settlement_items i where i.id = (ae.payload->>'settlement_item_id')::uuid)))
  ) then
    raise exception 'R2J TIMELINE FAIL: settlement activity no apunta a batch/item real';
  end if;

  -- no aparecen eventos de Viaje/Familia/Negocio en la timeline de la Cena
  -- (los subjects de la cena no aparecen como activity de otros contextos)
  if exists (
    select 1 from public.activity_events ae
    where ae.context_actor_id in ((v_world->>'viaje')::uuid, (v_world->>'familia')::uuid, (v_world->>'negocio')::uuid)
      and ae.subject_id in (
        select subject_id from public.activity_events
        where context_actor_id = v_cena and subject_id is not null
          and event_type in ('event.created', 'expense.recorded', 'settlement.generated'))
  ) then
    raise exception 'R2J TIMELINE FAIL: subjects de la cena aparecen en otros contextos';
  end if;

  perform public._r2j_cleanup_world(v_world);
  raise notice 'R.2J ACTIVITY TIMELINE RECONSTRUCTION: PASS (9 hitos en orden, conteos correctos, cero contaminación)';
end; $$;

revoke all on function public._smoke_r2j_activity_timeline_reconstruction() from public, anon, authenticated;
