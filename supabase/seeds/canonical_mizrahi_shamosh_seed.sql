-- =============================================================================
-- R.SEED.2 — CANONICAL MIZRAHI / SHAMOSH SEED (Final)
-- =============================================================================
-- Escenario oficial de desarrollo, QA, demos, frontend y smoke tests del MVP 2.0.
-- Reemplaza por completo el seed anterior (founder_demo_*).
--
-- RESET: borra TODA la data (no catálogos) y reconstruye un único mundo canónico
-- usando exclusivamente el modelo MVP actual (sin schema nuevo, sin primitivas
-- nuevas). José se re-ancla a su auth real (jmizrahit@gmail.com) para poder entrar.
--
-- Adaptaciones documentadas (spec ↔ schema actual):
--   · Palco: el tipo `property` NO es reservable en la matriz R.2M-3; para que el
--     palco soporte reservaciones/availability se usa el tipo reservable `house`.
--   · Relationships: `family`/`father_in_law` no son relationship_type válidos →
--     se usa `related_to` con metadata.kind. shareholder_of/beneficiary_of sí existen.
--   · Decisión `draft`: decisions.status no tiene 'draft' → se crea 'open' con
--     payload.lifecycle='draft' (pre-propuesta gobernada por la regla Venta Nave).
--   · Money "Renta Quimibond" (transaction_type=payment) y las obligaciones de
--     capital (money, 29M) se insertan directo (no hay RPC de payment/contribution).
--   · José es founder de los contextos que el DoD exige que pueda navegar
--     (Familia Mizrahi, Comidas Miércoles, Proyecto, Quimibond, Fideicomiso).
--     Familia Shamosh la funda Pepe (José no la necesita).
-- =============================================================================

do $$
declare
  -- José (real)
  v_jose_auth uuid;
  a_jose uuid;
  -- personas demo (@canonical.ruul.test)
  u_papa uuid := gen_random_uuid(); a_papa uuid;
  u_abuelo uuid := gen_random_uuid(); a_abuelo uuid;
  u_pepe uuid := gen_random_uuid(); a_pepe uuid;
  u_alberto uuid := gen_random_uuid(); a_alberto uuid;
  u_david uuid := gen_random_uuid(); a_david uuid;   -- David Achar
  u_boaz uuid := gen_random_uuid(); a_boaz uuid;
  -- contextos
  c_fam_miz uuid; c_fam_sha uuid; c_comidas uuid; c_proyecto uuid; c_quimibond uuid; c_trust uuid;
  -- recursos
  r_palco uuid; r_terreno uuid; r_nave uuid; r_acciones uuid; r_cuenta uuid;
  -- flujo
  v_code text; v_partido1 uuid; v_e uuid; v_dec uuid; v_txn uuid; v_ob uuid;
  v_p1_start timestamptz := '2026-11-21 13:00-06'::timestamptz;
  r record;
begin
  -- ───────────────────────────────────────────────────────────────────────────
  -- 0. Anclar José real (lo necesitamos ANTES del reset)
  -- ───────────────────────────────────────────────────────────────────────────
  select u.id into v_jose_auth from auth.users u where u.email = 'jmizrahit@gmail.com';
  if v_jose_auth is null then
    -- entornos sin José (local/CI): lo creamos para que el seed sea self-contained
    v_jose_auth := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (v_jose_auth, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'jmizrahit@gmail.com', '{"provider":"email","providers":["email"]}'::jsonb,
            '{"full_name":"José Mizrahi"}'::jsonb, now(), now());
  end if;

  -- ───────────────────────────────────────────────────────────────────────────
  -- 1. RESET — borra toda la data (mantiene catálogos). TRUNCATE … CASCADE
  --    evita el trigger append-only de activity_events y respeta los FKs.
  -- ───────────────────────────────────────────────────────────────────────────
  truncate
    public.activity_events,
    public.settlement_items, public.settlement_batches,
    public.money_splits, public.money_transactions,
    public.rule_evaluations, public.obligations,
    public.event_participants, public.calendar_events,
    public.reservation_conflicts, public.resource_reservations,
    public.decision_votes, public.decision_options, public.decisions,
    public.documents,
    public.resource_rights, public.resources,
    public.actor_relationships,
    public.role_assignments, public.roles,
    public.actor_memberships,
    public.rules,
    public.person_profiles, public.actors
  restart identity cascade;

  -- El actor de sistema es foundational (lo referencia system_actor_id()): recrear.
  insert into public.actors (id, actor_kind, actor_subtype, display_name, status, visibility, metadata)
  values ('00000000-0000-0000-0000-000000000001', 'system', 'system', 'Ruul System', 'active', 'private',
          '{"seed":"mvp2_m1"}'::jsonb)
  on conflict (id) do nothing;

  -- auth.users demo de corridas previas
  delete from auth.users where email like '%@canonical.ruul.test';

  -- ───────────────────────────────────────────────────────────────────────────
  -- 2. ACTORES — José (re-anclado) + 6 personas demo (vía trigger de auth.users)
  -- ───────────────────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);
  a_jose := ((public.ensure_person_actor())->>'actor_id')::uuid;
  perform public.update_my_profile(p_full_name := 'José Mizrahi');

  for r in select * from (values
      ('Papá Mizrahi',    'papa',    u_papa),
      ('Abuelo Mizrahi',  'abuelo',  u_abuelo),
      ('Pepe Shamosh',    'pepe',    u_pepe),
      ('Alberto Shamosh', 'alberto', u_alberto),
      ('David Achar',     'davidachar', u_david),
      ('Boaz',            'boaz',    u_boaz)) t(who, handle, uid)
  loop
    insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (r.uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            r.handle || '@canonical.ruul.test',
            '{"provider":"email","providers":["email"],"ruul_canonical":true}'::jsonb,
            jsonb_build_object('full_name', r.who), now(), now());
  end loop;

  select actor_id into a_papa    from public.person_profiles where auth_user_id = u_papa;
  select actor_id into a_abuelo  from public.person_profiles where auth_user_id = u_abuelo;
  select actor_id into a_pepe    from public.person_profiles where auth_user_id = u_pepe;
  select actor_id into a_alberto from public.person_profiles where auth_user_id = u_alberto;
  select actor_id into a_david   from public.person_profiles where auth_user_id = u_david;
  select actor_id into a_boaz    from public.person_profiles where auth_user_id = u_boaz;

  -- ───────────────────────────────────────────────────────────────────────────
  -- 3. CONTEXTOS + MEMBERSHIPS
  -- ───────────────────────────────────────────────────────────────────────────
  -- Familia Mizrahi (José founder; Papá, Abuelo)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);
  c_fam_miz := ((public.create_context('Familia Mizrahi', 'collective', 'family'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(c_fam_miz))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);   perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true); perform public.join_by_invite_code(v_code);

  -- Comidas Miércoles Mizrahi (community; José founder; Papá, Abuelo)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);
  c_comidas := ((public.create_context('Comidas Miércoles Mizrahi', 'collective', 'community'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(c_comidas))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);   perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true); perform public.join_by_invite_code(v_code);

  -- Familia Shamosh (Pepe founder; Alberto)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_pepe::text)::text, true);
  c_fam_sha := ((public.create_context('Familia Shamosh', 'collective', 'family'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(c_fam_sha))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_alberto::text)::text, true); perform public.join_by_invite_code(v_code);

  -- Quimibond (company; José founder para QA)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);
  c_quimibond := ((public.create_context('Quimibond', 'legal_entity', 'company'))->>'context_actor_id')::uuid;

  -- Proyecto Nave Industrial Toluca (project; José founder; board: Papá, Abuelo, Pepe, Alberto)
  c_proyecto := ((public.create_context('Proyecto Nave Industrial Toluca', 'collective', 'project'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(c_proyecto))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);    perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_pepe::text)::text, true);    perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_alberto::text)::text, true); perform public.join_by_invite_code(v_code);

  -- Fideicomiso Nave Industrial (trust; José founder para QA)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);
  c_trust := ((public.create_context('Fideicomiso Nave Industrial', 'legal_entity', 'trust'))->>'context_actor_id')::uuid;

  -- Capital stack del Proyecto (metadata)
  update public.actors set metadata = metadata || jsonb_build_object(
    'capital_stack', jsonb_build_object(
      'land_value', 58000000,
      'shamosh_initial_contribution', 58000000,
      'remaining_capital_split', jsonb_build_object('mizrahi', 0.5, 'shamosh', 0.5),
      'target_ownership', jsonb_build_object('mizrahi', 0.5, 'shamosh', 0.5)))
   where id = c_proyecto;

  -- ───────────────────────────────────────────────────────────────────────────
  -- 4. RELATIONSHIPS
  -- ───────────────────────────────────────────────────────────────────────────
  insert into public.actor_relationships (subject_actor_id, relationship_type, object_actor_id, metadata, created_by_actor_id) values
    (a_papa, 'related_to', a_abuelo,    '{"kind":"family"}'::jsonb,        a_jose),
    (a_pepe, 'related_to', a_alberto,   '{"kind":"family"}'::jsonb,        a_jose),
    (a_jose, 'related_to', a_alberto,   '{"kind":"father_in_law"}'::jsonb, a_jose),
    (a_papa,   'shareholder_of', c_quimibond, '{}'::jsonb, a_jose),
    (a_abuelo, 'shareholder_of', c_quimibond, '{}'::jsonb, a_jose),
    -- FUTURE OWNERSHIP (beneficial, planeado 50/50) del Proyecto
    (c_fam_miz, 'beneficiary_of', c_proyecto, '{"planned":true,"kind":"beneficial","percent":50}'::jsonb, a_jose),
    (c_fam_sha, 'beneficiary_of', c_proyecto, '{"planned":true,"kind":"beneficial","percent":50}'::jsonb, a_jose);

  -- ───────────────────────────────────────────────────────────────────────────
  -- 5. RECURSOS + RIGHTS  (se limpia el auto-OWN y se fijan los rights del spec)
  -- ───────────────────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);

  -- Palco Estadio Azteca (house = reservable). Contexto Familia Mizrahi.
  r_palco := ((public.create_resource(c_fam_miz, 'house', 'Palco Estadio Azteca',
    p_metadata := '{"capacity":10,"mizrahi_allocation":5,"world_cup":true}'::jsonb))->>'resource_id')::uuid;
  perform public.grant_right(r_palco, a_abuelo, 'OWN', p_percent := 50);
  perform public.grant_right(r_palco, c_fam_miz, 'GOVERN');
  perform public.grant_right(r_palco, a_jose,  'USE');
  perform public.grant_right(r_palco, a_papa,  'USE');
  perform public.grant_right(r_palco, a_pepe,  'USE');  -- in-law puede pedir lugar

  -- Terreno Toluca (property). Papá 50 / Abuelo 50.
  r_terreno := ((public.create_resource(c_proyecto, 'property', 'Terreno Toluca',
    p_metadata := '{"agreed_value":58000000}'::jsonb))->>'resource_id')::uuid;
  perform public.grant_right(r_terreno, a_papa,   'OWN', p_percent := 50);
  perform public.grant_right(r_terreno, a_abuelo, 'OWN', p_percent := 50);

  -- Nave Industrial Toluca (property, planned). Fideicomiso OWN 100%.
  r_nave := ((public.create_resource(c_proyecto, 'property', 'Nave Industrial Toluca',
    p_metadata := '{"status":"planned"}'::jsonb))->>'resource_id')::uuid;
  perform public.grant_right(r_nave, c_trust, 'OWN', p_percent := 100);

  -- Acciones Quimibond (security). Papá 50 / Abuelo 50.
  r_acciones := ((public.create_resource(c_quimibond, 'security', 'Acciones Quimibond'))->>'resource_id')::uuid;
  perform public.grant_right(r_acciones, a_papa,   'OWN', p_percent := 50);
  perform public.grant_right(r_acciones, a_abuelo, 'OWN', p_percent := 50);
  perform public.grant_right(r_acciones, a_jose,   'BENEFICIARY');  -- José ve beneficiarios/ownership

  -- Cuenta del Viaje Japón (bank_account). José MANAGE + VIEW.
  r_cuenta := ((public.create_resource(c_fam_miz, 'bank_account', 'Cuenta del Viaje Japón'))->>'resource_id')::uuid;
  perform public.grant_right(r_cuenta, a_jose, 'MANAGE');
  perform public.grant_right(r_cuenta, a_jose, 'VIEW');

  -- ── Propiedad ≤ 100%: el auto-OWN del contexto (create_resource otorga OWN 100%
  --    al contexto) es REDUNDANTE donde ya hay dueños reales (persona/entidad). Lo
  --    convertimos en GOVERN (para que el recurso siga listándose en su contexto) y
  --    lo borramos. Así Papá+Abuelo = 100% del Terreno, etc. — nunca >100%. La Cuenta,
  --    sin otros dueños, conserva su OWN del contexto (dueño institucional legítimo).
  insert into public.resource_rights (resource_id, holder_actor_id, right_kind, granted_by_actor_id, metadata)
  select rr.resource_id, rr.holder_actor_id, 'GOVERN', public.system_actor_id(), '{"source":"seed_fix_ownership"}'::jsonb
    from public.resource_rights rr
   where rr.right_kind = 'OWN' and rr.metadata->>'source' = 'auto_own_on_create'
     and exists (select 1 from public.resource_rights o where o.resource_id = rr.resource_id and o.right_kind = 'OWN'
                  and o.id <> rr.id and o.revoked_at is null and o.expired_at is null)
     and not exists (select 1 from public.resource_rights g where g.resource_id = rr.resource_id
                  and g.holder_actor_id = rr.holder_actor_id and g.right_kind = 'GOVERN' and g.revoked_at is null);
  delete from public.resource_rights rr
   where rr.right_kind = 'OWN' and rr.metadata->>'source' = 'auto_own_on_create'
     and exists (select 1 from public.resource_rights o where o.resource_id = rr.resource_id and o.right_kind = 'OWN'
                  and o.id <> rr.id and o.revoked_at is null and o.expired_at is null);

  -- ───────────────────────────────────────────────────────────────────────────
  -- 6. EVENTOS
  -- ───────────────────────────────────────────────────────────────────────────
  -- Mundial (Familia Mizrahi) — 5 partidos
  v_partido1 := ((public.create_calendar_event(c_fam_miz, 'Partido Mundial 1', 'other',
    p_starts_at := v_p1_start, p_ends_at := v_p1_start + interval '2 hours'))->>'event_id')::uuid;
  perform public.create_calendar_event(c_fam_miz, 'Partido Mundial 2', 'other',
    p_starts_at := v_p1_start + interval '4 days', p_ends_at := v_p1_start + interval '4 days 2 hours');
  perform public.create_calendar_event(c_fam_miz, 'Partido Mundial 3', 'other',
    p_starts_at := v_p1_start + interval '8 days', p_ends_at := v_p1_start + interval '8 days 2 hours');
  perform public.create_calendar_event(c_fam_miz, 'Partido Mundial 4', 'other',
    p_starts_at := v_p1_start + interval '12 days', p_ends_at := v_p1_start + interval '12 days 2 hours');
  perform public.create_calendar_event(c_fam_miz, 'Partido Mundial 5', 'other',
    p_starts_at := v_p1_start + interval '16 days', p_ends_at := v_p1_start + interval '16 days 2 hours');

  -- Comidas Miércoles — 4 comidas
  for r in select g, (date_trunc('week', now()) + (g || ' weeks')::interval + interval '20 hours')::timestamptz as ts
           from generate_series(1, 4) g loop
    perform public.create_calendar_event(c_comidas, 'Comida Miércoles #' || r.g, 'dinner',
      p_starts_at := r.ts, p_ends_at := r.ts + interval '3 hours');
  end loop;

  -- ───────────────────────────────────────────────────────────────────────────
  -- 7. RESERVATIONS + CONFLICTO (Palco, Partido 1) — demanda 7 > capacidad 5
  -- ───────────────────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);
  perform public.request_resource_reservation(r_palco, c_fam_miz, v_p1_start, v_p1_start + interval '2 hours',
    p_reserved_for_actor_id := a_jose, p_metadata := '{"seats":1,"partido":1}'::jsonb, p_client_id := 'seed-palco-jose');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  perform public.request_resource_reservation(r_palco, c_fam_miz, v_p1_start, v_p1_start + interval '2 hours',
    p_reserved_for_actor_id := a_papa, p_metadata := '{"seats":2,"partido":1}'::jsonb, p_client_id := 'seed-palco-papa');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  perform public.request_resource_reservation(r_palco, c_fam_miz, v_p1_start, v_p1_start + interval '2 hours',
    p_reserved_for_actor_id := a_abuelo, p_metadata := '{"seats":2,"partido":1}'::jsonb, p_client_id := 'seed-palco-abuelo');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_pepe::text)::text, true);
  perform public.request_resource_reservation(r_palco, c_fam_miz, v_p1_start, v_p1_start + interval '2 hours',
    p_reserved_for_actor_id := a_pepe, p_metadata := '{"seats":2,"partido":1}'::jsonb, p_client_id := 'seed-palco-pepe');

  -- ───────────────────────────────────────────────────────────────────────────
  -- 8. DECISIONS
  -- ───────────────────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);

  -- Construcción Nave (executed / approved)
  v_dec := ((public.create_decision(c_proyecto, 'generic', '¿Construimos la Nave Industrial?',
    'Aprobación del arranque de obra.', null, '{}'::jsonb, 'seed-dec-construir', 'yes_no_abstain'))->>'decision_id')::uuid;
  update public.decisions set status = 'executed', decided_at = now() - interval '20 days',
         executed_at = now() - interval '18 days',
         result = jsonb_build_object('outcome','approved','approve',4,'reject',0)
   where id = v_dec;
  perform public._emit_activity(c_proyecto, a_jose, 'decision.executed', 'decision', v_dec,
    '{"outcome":"approved"}'::jsonb, p_decision_id := v_dec);

  -- Constructor (single_choice: David Achar vs Boaz) — open
  perform public.create_decision(c_proyecto, 'generic', '¿Quién construye la nave?',
    'Selección del contratista.', null,
    '{"options":["David Achar","Boaz"]}'::jsonb, 'seed-dec-constructor', 'single_choice');

  -- Conflicto Mundial (single_choice) — open, en Familia Mizrahi
  perform public.create_decision(c_fam_miz, 'generic', '¿Cómo asignamos los lugares del Partido 1?',
    'Demanda 7 lugares sobre 5 disponibles.', null,
    '{"options":["Propuesta Abuelo","Propuesta Papá","Sorteo","First Come First Served"]}'::jsonb,
    'seed-dec-conflicto-mundial', 'single_choice');

  -- Venta Futura Nave (yes_no_abstain) — 'draft' representado como open + payload.lifecycle
  v_dec := ((public.create_decision(c_proyecto, 'generic', '¿Vendemos la Nave Industrial?',
    'Pre-propuesta gobernada por la regla Venta Nave (3 de 4 votos).', null,
    '{"lifecycle":"draft","required_yes_votes":3,"total_voters":4}'::jsonb,
    'seed-dec-venta', 'yes_no_abstain'))->>'decision_id')::uuid;

  -- ───────────────────────────────────────────────────────────────────────────
  -- 9. OBLIGATIONS
  -- ───────────────────────────────────────────────────────────────────────────
  -- Aportación Terreno (action) — Papá, Abuelo → al fideicomiso (contexto Proyecto)
  perform public.create_action_obligation(c_proyecto, a_papa,   'Aportar terreno al fideicomiso', 'action');
  perform public.create_action_obligation(c_proyecto, a_abuelo, 'Aportar terreno al fideicomiso', 'action');

  -- Capital Shamosh (money 29M c/u) — directo (no hay RPC de contribution)
  insert into public.obligations (context_actor_id, debtor_actor_id, creditor_actor_id,
    obligation_kind, obligation_type, amount, currency, status, title, metadata) values
    (c_proyecto, a_pepe,    c_proyecto, 'money', 'contribution', 29000000, 'MXN', 'open',
     'Capital construcción nave', '{"concept":"Capital construcción nave"}'::jsonb),
    (c_proyecto, a_alberto, c_proyecto, 'money', 'contribution', 29000000, 'MXN', 'open',
     'Capital construcción nave', '{"concept":"Capital construcción nave"}'::jsonb);

  -- Comidas Miércoles (action) — José postre, Papá vino
  perform public.create_action_obligation(c_comidas, a_jose, 'Llevar postre', 'action');
  perform public.create_action_obligation(c_comidas, a_papa, 'Llevar vino',   'action');

  -- ───────────────────────────────────────────────────────────────────────────
  -- 10. MONEY — Renta Quimibond (payment) → Terreno; split Papá 250k / Abuelo 250k
  -- ───────────────────────────────────────────────────────────────────────────
  insert into public.money_transactions (context_actor_id, from_actor_id, to_actor_id, transaction_type,
    amount, currency, resource_id, metadata, created_by_actor_id)
  values (c_quimibond, c_quimibond, null, 'payment', 500000, 'MXN', r_terreno,
    '{"description":"Renta Quimibond por el terreno/nave"}'::jsonb, a_jose)
  returning id into v_txn;
  insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency) values
    (v_txn, c_quimibond, 'payer',     500000, 'MXN'),
    (v_txn, a_papa,      'creditor',  250000, 'MXN'),
    (v_txn, a_abuelo,    'creditor',  250000, 'MXN');

  -- ───────────────────────────────────────────────────────────────────────────
  -- 11. RULES
  -- ───────────────────────────────────────────────────────────────────────────
  -- Host Rotation (Comidas) — norma sin automatización
  perform public.create_rule(c_comidas, 'Host rota semanalmente',
    p_trigger_event_type := null, p_condition_tree := null, p_consequences := null,
    p_body := 'El anfitrión de la comida rota cada semana entre los miembros.',
    p_rule_type := 'policy');

  -- Venta Nave (Proyecto) — venta requiere decisión con 3 de 4 votos
  perform public.create_rule(c_proyecto, 'Venta de la Nave requiere 3 de 4 votos',
    p_trigger_event_type := 'resource_sale_requested',
    p_condition_tree := jsonb_build_object('op','=','field','resource_id','value', r_nave::text),
    p_consequences := '[{"type":"create_decision","voting_model":"yes_no_abstain","required_yes_votes":3,"total_voters":4}]'::jsonb,
    p_body := 'Vender la Nave Industrial requiere una decisión aprobada por 3 de 4 socios.');

  -- ───────────────────────────────────────────────────────────────────────────
  -- 12. DOCUMENTS
  -- ───────────────────────────────────────────────────────────────────────────
  perform public.register_document('Contrato Fideicomiso', c_trust,    'contract');
  perform public.register_document('Valuación Terreno',     c_proyecto, 'statement', p_resource_id := r_terreno);
  perform public.register_document('Propuesta David Achar',  c_proyecto, 'other');
  perform public.register_document('Propuesta Boaz',         c_proyecto, 'other');

  -- ───────────────────────────────────────────────────────────────────────────
  -- Listo
  -- ───────────────────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', null, true);

  raise notice 'R.SEED.2 CANONICAL: OK — José=% · 6 contextos · 5 recursos · 5 partidos + 4 comidas · conflicto de palco · 4 decisiones · obligaciones (acción+capital) · renta Quimibond · 2 reglas · 4 documentos · trust sin beneficiarios.', a_jose;
end; $$;
