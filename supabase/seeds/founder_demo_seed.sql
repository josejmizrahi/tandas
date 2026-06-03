-- =============================================================================
-- RUUL — SEED DEMO DEL FOUNDER (mundo de prueba para los smokes F.14)
-- =============================================================================
-- Crea un mundo realista anclado al actor REAL de José (jmizrahit@gmail.com)
-- usando exclusivamente los RPCs de producción (impersonación vía JWT claims),
-- exactamente igual que los smokes del backend (r2k). No toca datos existentes.
--
-- Personas demo (NO pueden hacer login — email @demo.ruul.test):
--   David Mizrahi · Isaac Mizrahi · Moisés Mizrahi · Daniel Cohen · Alberto Mizrahi
--
-- Mundo creado:
--   · Cena Semanal (friend_group, José founder) — 2 reglas, cena en curso con
--     check-ins/multas/gasto/Catan + cena de la próxima semana con RSVPs
--   · Familia Mizrahi (family, José founder) — Casa Valle con rights y un
--     conflicto de reservación ABIERTO (David vs Isaac)
--   · Viaje Japón 2026 (trip, José founder) — hotel + vuelos con splits cruzados
--   · Negocio Valle (legal_entity/company, José founder) — decisión ABIERTA
--   · Trust Familiar Mizrahi (legal_entity/trust, Abuelo founder) — acciones,
--     José beneficiario
--
-- Lo que queda ABIERTO para hacer desde el iPhone (F.14):
--   1. Cena de hoy: RSVP, check-in (te tocará multa por tarde 😄), cerrar evento
--   2. Generar settlement de la Cena y del Viaje + marcar pagos
--   3. Resolver el conflicto de Casa Valle (David vs Isaac)
--   4. Votar la decisión del Negocio (tu voto la aprueba) y ejecutarla
--   5. Editar tu perfil (tu nombre hoy es "jmizrahit")
--
-- Para borrar todo el demo: supabase/seeds/founder_demo_wipe.sql
-- =============================================================================

do $$
declare
  -- José (real)
  v_jose_auth uuid;
  a_jose uuid;
  -- personas demo
  u_david uuid := gen_random_uuid(); u_isaac uuid := gen_random_uuid();
  u_moises uuid := gen_random_uuid(); u_daniel uuid := gen_random_uuid();
  u_abuelo uuid := gen_random_uuid();
  a_david uuid; a_isaac uuid; a_moises uuid; a_daniel uuid; a_abuelo uuid;
  -- contextos
  c_cena uuid; c_familia uuid; c_viaje uuid; c_negocio uuid; c_trust uuid;
  -- recursos
  r_casa uuid; r_acciones uuid; r_cuenta uuid;
  -- flujo
  v_code text;
  v_dinner_today uuid; v_dinner_next uuid;
  v_starts timestamptz; v_next_starts timestamptz;
  v_decision uuid;
  r record;
begin
  -- ───────────────────────────────────────────────────────────────────
  -- 0. José real + guard de re-ejecución
  -- ───────────────────────────────────────────────────────────────────
  select pp.auth_user_id, pp.actor_id into v_jose_auth, a_jose
    from public.person_profiles pp
    join auth.users u on u.id = pp.auth_user_id
   where u.email = 'jmizrahit@gmail.com';

  if a_jose is null then
    raise exception 'No existe el actor de José (jmizrahit@gmail.com). Haz login en la app primero.';
  end if;

  if exists (
    select 1 from public.actors a
    join public.actor_memberships m on m.context_actor_id = a.id
    where a.display_name = 'Cena Semanal' and m.member_actor_id = a_jose
  ) then
    raise exception 'El demo ya existe. Corre founder_demo_wipe.sql primero si quieres regenerarlo.';
  end if;

  -- ───────────────────────────────────────────────────────────────────
  -- 1. Personas demo (vía el trigger real de auth.users → actors)
  -- ───────────────────────────────────────────────────────────────────
  for r in
    select * from (values
      ('David Mizrahi',   'david',  u_david),
      ('Isaac Mizrahi',   'isaac',  u_isaac),
      ('Moisés Mizrahi',  'moises', u_moises),
      ('Daniel Cohen',    'daniel', u_daniel),
      ('Alberto Mizrahi', 'abuelo', u_abuelo)) t(who, handle, uid)
  loop
    insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (r.uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            r.handle || '@demo.ruul.test',
            '{"provider": "email", "providers": ["email"], "ruul_demo": true}'::jsonb,
            jsonb_build_object('full_name', r.who), now(), now());
  end loop;

  select actor_id into a_david  from public.person_profiles where auth_user_id = u_david;
  select actor_id into a_isaac  from public.person_profiles where auth_user_id = u_isaac;
  select actor_id into a_moises from public.person_profiles where auth_user_id = u_moises;
  select actor_id into a_daniel from public.person_profiles where auth_user_id = u_daniel;
  select actor_id into a_abuelo from public.person_profiles where auth_user_id = u_abuelo;

  if a_david is null or a_isaac is null or a_moises is null or a_daniel is null or a_abuelo is null then
    raise exception 'El trigger de auth no creó los actors demo';
  end if;

  -- ───────────────────────────────────────────────────────────────────
  -- 2. CENA SEMANAL (José founder) + miembros
  -- ───────────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);
  c_cena := ((public.create_context('Cena Semanal', 'collective', 'friend_group'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(c_cena))->>'code';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Reglas (José)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);
  perform public.create_rule(c_cena, 'Multa por llegar tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": ">", "field": "minutes_late", "value": 15}]}'::jsonb,
    p_consequences := '[{"type": "create_obligation", "obligation_type": "fine", "amount": 100, "currency": "MXN", "reason": "late_arrival"}]'::jsonb);
  perform public.create_rule(c_cena, 'Multa por cancelar mismo día',
    p_trigger_event_type := 'event.participation_cancelled',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": "=", "field": "same_day_cancellation", "value": true}]}'::jsonb,
    p_consequences := '[{"type": "create_obligation", "obligation_type": "fine", "amount": 300, "currency": "MXN", "reason": "same_day_cancellation"}]'::jsonb);

  -- Cena EN CURSO (empezó hace 45 min, host David — los check-ins con hora
  -- explícita requieren autoridad de host; José es admin y hace el suyo desde la app)
  v_starts := now() - interval '45 minutes';
  v_dinner_today := ((public.create_calendar_event(c_cena, 'Cena de esta semana', 'dinner',
    p_starts_at := v_starts, p_ends_at := v_starts + interval '3 hours',
    p_timezone := 'America/Mexico_City', p_host_actor_id := a_david,
    p_client_id := 'founder-demo-cena-hoy'))->>'event_id')::uuid;

  -- RSVPs de todos los demo
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.rsvp_event(v_dinner_today, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.rsvp_event(v_dinner_today, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.rsvp_event(v_dinner_today, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.rsvp_event(v_dinner_today, 'going');
  -- Daniel cancela él mismo (sin hora explícita = ahora → mismo día → multa $300)
  perform public.cancel_participation(v_dinner_today);

  -- Check-ins registrados por el host (David): él a tiempo, Isaac a tiempo, Moisés tarde → multa $100
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.check_in_participant(v_dinner_today, p_checked_in_at := v_starts);
  perform public.check_in_participant(v_dinner_today, a_isaac, v_starts + interval '12 minutes');
  perform public.check_in_participant(v_dinner_today, a_moises, v_starts + interval '25 minutes');

  -- Gasto de la cena: David pagó $1,300, Daniel excluido (canceló)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.record_expense(c_cena, 1300, 'MXN', 'Pizza, cerveza y botanas',
    p_split_with := array[a_david, a_jose, a_isaac, a_moises],
    p_event_id := v_dinner_today, p_client_id := 'founder-demo-cena-gasto',
    p_excluded_actor_ids := array[a_daniel]);

  -- Catan: Moisés le ganó $250 a Daniel
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.record_game_result(c_cena, v_dinner_today, 'Catan', a_moises, a_daniel, 250, 'MXN', 'founder-demo-catan');

  -- Cena de la PRÓXIMA semana (host David) con RSVPs parciales
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);
  v_next_starts := (date_trunc('day', now() at time zone 'America/Mexico_City') + interval '7 days' + interval '20 hours 30 minutes') at time zone 'America/Mexico_City';
  v_dinner_next := ((public.create_calendar_event(c_cena, 'Cena de la próxima semana', 'dinner',
    p_starts_at := v_next_starts, p_ends_at := v_next_starts + interval '3 hours',
    p_timezone := 'America/Mexico_City', p_host_actor_id := a_david,
    p_client_id := 'founder-demo-cena-proxima'))->>'event_id')::uuid;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.rsvp_event(v_dinner_next, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.rsvp_event(v_dinner_next, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.rsvp_event(v_dinner_next, 'maybe');

  -- ───────────────────────────────────────────────────────────────────
  -- 3. FAMILIA MIZRAHI (José founder) + Casa Valle + conflicto abierto
  -- ───────────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);
  c_familia := ((public.create_context('Familia Mizrahi', 'collective', 'family'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(c_familia))->>'code';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Casa Valle: el Abuelo la posee (OWN personal) y otorga rights
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  r_casa := ((public.create_resource(a_abuelo, 'house', 'Casa Valle'))->>'resource_id')::uuid;
  perform public.grant_right(r_casa, c_familia, 'GOVERN');
  perform public.grant_right(r_casa, a_jose,   'USE');
  perform public.grant_right(r_casa, a_david,  'USE');
  perform public.grant_right(r_casa, a_isaac,  'USE');
  perform public.grant_right(r_casa, a_moises, 'VIEW');

  -- Historial: David ya la usó dos veces (para que least_recent_use recomiende a Isaac)
  insert into public.resource_reservations (resource_id, context_actor_id, requested_by_actor_id, reserved_for_actor_id, starts_at, ends_at, status) values
    (r_casa, c_familia, a_david, a_david, now() - interval '60 days', now() - interval '58 days', 'completed'),
    (r_casa, c_familia, a_david, a_david, now() - interval '30 days', now() - interval '28 days', 'completed');

  -- Conflicto ABIERTO: David e Isaac piden el mismo fin de semana de julio
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.request_resource_reservation(r_casa, c_familia,
    '2026-07-10 16:00-06'::timestamptz, '2026-07-12 18:00-06'::timestamptz,
    p_client_id := 'founder-demo-res-david');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.request_resource_reservation(r_casa, c_familia,
    '2026-07-10 16:00-06'::timestamptz, '2026-07-12 18:00-06'::timestamptz,
    p_client_id := 'founder-demo-res-isaac');

  -- ───────────────────────────────────────────────────────────────────
  -- 4. VIAJE JAPÓN 2026 (José founder) + gastos cruzados
  -- ───────────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);
  c_viaje := ((public.create_context('Viaje Japón 2026', 'collective', 'trip'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(c_viaje))->>'code';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Cuenta del viaje (recurso del contexto)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);
  r_cuenta := ((public.create_resource(c_viaje, 'bank_account', 'Cuenta del Viaje'))->>'resource_id')::uuid;
  perform public.grant_right(r_cuenta, c_viaje, 'MANAGE');
  perform public.grant_right(r_cuenta, a_david, 'VIEW');
  perform public.grant_right(r_cuenta, a_isaac, 'VIEW');

  -- David pagó el hotel $30,000 (José e Isaac le deben $10,000 c/u)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.record_expense(c_viaje, 30000, 'MXN', 'Hotel Tokio',
    p_split_with := array[a_david, a_jose, a_isaac], p_client_id := 'founder-demo-hotel');

  -- José pagó los vuelos $24,000 (David e Isaac le deben $8,000 c/u)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);
  perform public.record_expense(c_viaje, 24000, 'MXN', 'Vuelos CDMX-Tokio',
    p_split_with := array[a_jose, a_david, a_isaac], p_client_id := 'founder-demo-vuelos');

  -- ───────────────────────────────────────────────────────────────────
  -- 5. NEGOCIO VALLE (legal_entity, José founder) + decisión ABIERTA
  -- ───────────────────────────────────────────────────────────────────
  c_negocio := ((public.create_context('Negocio Valle', 'legal_entity', 'company'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(c_negocio))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- José propone, David ya votó approve — falta el voto de José (desde la app)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);
  v_decision := ((public.create_decision(c_negocio, 'expense_approval',
    '¿Invertimos $100,000 MXN en permisos de construcción?',
    p_payload := '{"amount": 100000, "currency": "MXN"}'::jsonb,
    p_client_id := 'founder-demo-decision'))->>'decision_id')::uuid;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.vote_decision(v_decision, 'approve');

  -- ───────────────────────────────────────────────────────────────────
  -- 6. TRUST FAMILIAR (Abuelo founder/trustee, José beneficiario)
  -- ───────────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  c_trust := ((public.create_context('Trust Familiar Mizrahi', 'legal_entity', 'trust'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(c_trust))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  r_acciones := ((public.create_resource(c_trust, 'other', 'Acciones Quimibond'))->>'resource_id')::uuid;
  perform public.grant_right(r_acciones, a_abuelo, 'MANAGE');
  perform public.grant_right(r_acciones, a_jose, 'BENEFICIARY');

  -- ───────────────────────────────────────────────────────────────────
  -- Listo
  -- ───────────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', null, true);

  raise notice 'SEED FOUNDER DEMO: OK — 5 contextos, 3 recursos, 2 cenas, 2 reglas, multas, gastos, conflicto de reservación abierto y decisión abierta. Actor de José: %', a_jose;
end; $$;
