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
  u_papa uuid := gen_random_uuid(); a_papa uuid;       -- Jacobo Mizrahi (papá de José)
  u_abuelo uuid := gen_random_uuid(); a_abuelo uuid;   -- José Mizrahi (Abuelo)
  u_pepe uuid := gen_random_uuid(); a_pepe uuid;
  u_alberto uuid := gen_random_uuid(); a_alberto uuid;
  u_david uuid := gen_random_uuid(); a_david uuid;   -- David Achar
  u_boaz uuid := gen_random_uuid(); a_boaz uuid;
  -- grupo del Palco Mundial 2026 (primos, tíos, amigos)
  u_mochon uuid := gen_random_uuid(); a_mochon uuid;
  u_alan uuid := gen_random_uuid(); a_alan uuid;        -- Alan Cohen (primo, hijo de Víctor)
  u_victor uuid := gen_random_uuid(); a_victor uuid;    -- Víctor Cohen (papá de Alan)
  u_joseserur uuid := gen_random_uuid(); a_joseserur uuid;
  u_danserur uuid := gen_random_uuid(); a_danserur uuid;
  u_beto uuid := gen_random_uuid(); a_beto uuid;        -- Beto Serur (papá de Daniel y José Serur)
  u_salo uuid := gen_random_uuid(); a_salo uuid;        -- Salo Saade (cuñado de Alan, yerno de Víctor)
  -- contextos
  c_fam_miz uuid; c_fam_sha uuid; c_comidas uuid; c_proyecto uuid; c_quimibond uuid; c_trust uuid; c_palco uuid;
  -- recursos
  r_palco uuid; r_terreno uuid; r_nave uuid; r_acciones uuid; r_cuenta uuid;
  -- flujo
  v_code text; v_dec uuid; v_txn uuid; v_ev uuid;
  -- fechas reales de los partidos del grupo (Mundial 2026)
  v_m1 timestamptz := '2026-06-11 13:00-06'::timestamptz;  -- Inauguración México vs Sudáfrica
  v_m2 timestamptz := '2026-06-17 13:00-06'::timestamptz;  -- Colombia vs Uzbekistán
  v_m3 timestamptz := '2026-06-24 13:00-06'::timestamptz;  -- México vs Chequia
  v_m4 timestamptz := '2026-06-30 13:00-06'::timestamptz;  -- Ronda de 32
  v_m5 timestamptz := '2026-07-05 13:00-06'::timestamptz;  -- Ronda de 16
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
      ('Jacobo Mizrahi',       'jacobo',     u_papa),     -- papá de José, hijo del Abuelo
      ('José Mizrahi (Abuelo)','joseabuelo', u_abuelo),   -- el patriarca
      ('Pepe Shamosh',         'pepe',       u_pepe),
      ('Alberto Shamosh',      'alberto',    u_alberto),
      ('David Achar',          'davidachar', u_david),
      ('Boaz',                 'boaz',       u_boaz),
      ('José Mochon',          'mochon',     u_mochon),
      ('Alan Cohen',           'alancohen',  u_alan),
      ('Víctor Cohen',         'victorcohen',u_victor),
      ('José Serur',           'joseserur',  u_joseserur),
      ('Daniel Serur',         'danielserur',u_danserur),
      ('Beto Serur',           'betoserur',  u_beto),
      ('Salo Saade',           'salosaade',  u_salo)) t(who, handle, uid)
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
  select actor_id into a_mochon    from public.person_profiles where auth_user_id = u_mochon;
  select actor_id into a_alan      from public.person_profiles where auth_user_id = u_alan;
  select actor_id into a_victor    from public.person_profiles where auth_user_id = u_victor;
  select actor_id into a_joseserur from public.person_profiles where auth_user_id = u_joseserur;
  select actor_id into a_danserur  from public.person_profiles where auth_user_id = u_danserur;
  select actor_id into a_beto      from public.person_profiles where auth_user_id = u_beto;
  select actor_id into a_salo      from public.person_profiles where auth_user_id = u_salo;

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

  -- Palco Mundial 2026 (friend_group; José founder) — el grupo que comparte el palco:
  -- Abuelo (dueño), Jacobo, José Mochon, Cohens, Serurs, Salo.
  c_palco := ((public.create_context('Palco Mundial 2026', 'collective', 'friend_group'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(c_palco))->>'code';
  for r in select unnest(array[u_abuelo, u_papa, u_mochon, u_alan, u_victor, u_joseserur, u_danserur, u_beto, u_salo]) as uid loop
    perform set_config('request.jwt.claims', jsonb_build_object('sub', r.uid::text)::text, true);
    perform public.join_by_invite_code(v_code);
  end loop;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);

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

  -- Grafo familiar del grupo del palco
  insert into public.actor_relationships (subject_actor_id, relationship_type, object_actor_id, metadata, created_by_actor_id) values
    (a_beto,      'related_to', a_papa,   '{"kind":"brother_in_law"}'::jsonb, a_jose), -- esposo de la hermana de Jacobo
    (a_beto,      'related_to', a_joseserur,'{"kind":"father"}'::jsonb, a_jose),
    (a_beto,      'related_to', a_danserur, '{"kind":"father"}'::jsonb, a_jose),
    (a_victor,    'related_to', a_alan,   '{"kind":"father"}'::jsonb, a_jose),
    (a_salo,      'related_to', a_alan,   '{"kind":"brother_in_law"}'::jsonb, a_jose),
    (a_salo,      'related_to', a_victor, '{"kind":"son_in_law"}'::jsonb, a_jose), -- yerno de Víctor
    (a_alan,      'related_to', a_jose,   '{"kind":"cousin"}'::jsonb, a_jose),
    (a_joseserur, 'related_to', a_jose,   '{"kind":"cousin"}'::jsonb, a_jose),
    (a_danserur,  'related_to', a_jose,   '{"kind":"cousin"}'::jsonb, a_jose);

  -- ───────────────────────────────────────────────────────────────────────────
  -- 5. RECURSOS + RIGHTS  (se limpia el auto-OWN y se fijan los rights del spec)
  -- ───────────────────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);

  -- Palco Estadio Azteca (house = reservable). Contexto: Palco Mundial 2026.
  -- Abuelo (el patriarca) es dueño del 50% (mitad Mizrahi); el grupo lo usa/gobierna.
  r_palco := ((public.create_resource(c_palco, 'house', 'Palco Estadio Azteca',
    p_metadata := '{"capacity":10,"mizrahi_allocation":5,"world_cup":true,"estadio":"Azteca"}'::jsonb))->>'resource_id')::uuid;
  perform public.grant_right(r_palco, a_abuelo, 'OWN', p_percent := 50);
  perform public.grant_right(r_palco, a_jose,      'USE');
  perform public.grant_right(r_palco, a_papa,      'USE');
  perform public.grant_right(r_palco, a_mochon,    'USE');
  perform public.grant_right(r_palco, a_alan,      'USE');
  perform public.grant_right(r_palco, a_victor,    'USE');
  perform public.grant_right(r_palco, a_joseserur, 'USE');
  perform public.grant_right(r_palco, a_danserur,  'USE');
  perform public.grant_right(r_palco, a_beto,      'USE');
  perform public.grant_right(r_palco, a_salo,      'USE');

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
  -- Mundial 2026 (Palco Mundial 2026) — 5 partidos reales.
  -- p_invite_all_members:=false → el evento NO invita a todo el contexto; solo
  -- agregamos el roster real de cada partido como participantes.
  v_ev := ((public.create_calendar_event(c_palco, 'Inauguración — México vs Sudáfrica', 'community_event',
    p_starts_at := v_m1, p_ends_at := v_m1 + interval '2 hours', p_invite_all_members := false))->>'event_id')::uuid;
  delete from public.event_participants where event_id = v_ev;  -- quita el auto-host; dejamos solo el roster
  insert into public.event_participants (event_id, participant_actor_id, status, rsvp_at)
    select v_ev, x, 'going', now() from unnest(array[a_jose, a_mochon, a_alan, a_joseserur, a_danserur]) x;

  v_ev := ((public.create_calendar_event(c_palco, 'Colombia vs Uzbekistán', 'community_event',
    p_starts_at := v_m2, p_ends_at := v_m2 + interval '2 hours', p_invite_all_members := false))->>'event_id')::uuid;
  delete from public.event_participants where event_id = v_ev;  -- quita el auto-host; dejamos solo el roster
  insert into public.event_participants (event_id, participant_actor_id, status, rsvp_at)
    select v_ev, x, 'going', now() from unnest(array[a_beto, a_joseserur, a_danserur, a_mochon, a_alan]) x;

  v_ev := ((public.create_calendar_event(c_palco, 'México vs Chequia', 'community_event',
    p_starts_at := v_m3, p_ends_at := v_m3 + interval '2 hours', p_invite_all_members := false))->>'event_id')::uuid;
  delete from public.event_participants where event_id = v_ev;  -- quita el auto-host; dejamos solo el roster
  insert into public.event_participants (event_id, participant_actor_id, status, rsvp_at)
    select v_ev, x, 'going', now() from unnest(array[a_jose, a_danserur, a_mochon, a_papa, a_alan]) x;

  v_ev := ((public.create_calendar_event(c_palco, 'Ronda de 32', 'community_event',
    p_starts_at := v_m4, p_ends_at := v_m4 + interval '2 hours', p_invite_all_members := false))->>'event_id')::uuid;
  delete from public.event_participants where event_id = v_ev;  -- quita el auto-host; dejamos solo el roster
  insert into public.event_participants (event_id, participant_actor_id, status, rsvp_at)
    select v_ev, x, 'going', now() from unnest(array[a_jose, a_salo, a_beto, a_mochon, a_alan]) x;

  v_ev := ((public.create_calendar_event(c_palco, 'Ronda de 16', 'community_event',
    p_starts_at := v_m5, p_ends_at := v_m5 + interval '2 hours', p_invite_all_members := false))->>'event_id')::uuid;
  delete from public.event_participants where event_id = v_ev;  -- quita el auto-host; dejamos solo el roster
  insert into public.event_participants (event_id, participant_actor_id, status, rsvp_at)
    select v_ev, x, 'going', now() from unnest(array[a_jose, a_alan, a_mochon, a_salo, a_victor]) x;

  -- Comidas Miércoles — 4 comidas
  for r in select g, (date_trunc('week', now()) + (g || ' weeks')::interval + interval '20 hours')::timestamptz as ts
           from generate_series(1, 4) g loop
    perform public.create_calendar_event(c_comidas, 'Comida Miércoles #' || r.g, 'dinner',
      p_starts_at := r.ts, p_ends_at := r.ts + interval '3 hours');
  end loop;

  -- ───────────────────────────────────────────────────────────────────────────
  -- 7. RESERVATIONS — una por partido, con su roster (≤5 lugares cada uno)
  -- ───────────────────────────────────────────────────────────────────────────
  -- Insert directo, status 'confirmed'. Fechas distintas → sin traslapes ni
  -- conflictos. El roster va en metadata.attendees (ids) + attendee_names.
  insert into public.resource_reservations
    (resource_id, context_actor_id, requested_by_actor_id, reserved_for_actor_id, starts_at, ends_at, status, metadata)
  values
    (r_palco, c_palco, a_jose, c_palco, v_m1, v_m1 + interval '2 hours', 'confirmed',
     jsonb_build_object('match','Inauguración','teams','México vs Sudáfrica','seats',5,
       'attendees', jsonb_build_array(a_jose, a_mochon, a_alan, a_joseserur, a_danserur),
       'attendee_names', jsonb_build_array('José Mizrahi','José Mochon','Alan Cohen','José Serur','Daniel Serur'))),
    (r_palco, c_palco, a_jose, c_palco, v_m2, v_m2 + interval '2 hours', 'confirmed',
     jsonb_build_object('match','Fase de grupos','teams','Colombia vs Uzbekistán','seats',5,
       'attendees', jsonb_build_array(a_beto, a_joseserur, a_danserur, a_mochon, a_alan),
       'attendee_names', jsonb_build_array('Beto Serur','José Serur','Daniel Serur','José Mochon','Alan Cohen'))),
    (r_palco, c_palco, a_jose, c_palco, v_m3, v_m3 + interval '2 hours', 'confirmed',
     jsonb_build_object('match','Fase de grupos','teams','México vs Chequia','seats',5,
       'attendees', jsonb_build_array(a_jose, a_danserur, a_mochon, a_papa, a_alan),
       'attendee_names', jsonb_build_array('José Mizrahi','Daniel Serur','José Mochon','Jacobo Mizrahi','Alan Cohen'))),
    (r_palco, c_palco, a_jose, c_palco, v_m4, v_m4 + interval '2 hours', 'confirmed',
     jsonb_build_object('match','Ronda de 32','teams','Por definir','seats',5,
       'attendees', jsonb_build_array(a_jose, a_salo, a_beto, a_mochon, a_alan),
       'attendee_names', jsonb_build_array('José Mizrahi','Salo Saade','Beto Serur','José Mochon','Alan Cohen'))),
    (r_palco, c_palco, a_jose, c_palco, v_m5, v_m5 + interval '2 hours', 'confirmed',
     jsonb_build_object('match','Ronda de 16','teams','Por definir','seats',5,
       'attendees', jsonb_build_array(a_jose, a_alan, a_mochon, a_salo, a_victor),
       'attendee_names', jsonb_build_array('José Mizrahi','Alan Cohen','José Mochon','Salo Saade','Víctor Cohen')));

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

  -- Asignación del palco (single_choice) — open, en Palco Mundial 2026.
  -- El palco tiene 5 lugares; cuando un partido tiene más demanda, el grupo decide.
  perform public.create_decision(c_palco, 'generic', '¿Cómo repartimos los lugares cuando hay más de 5 interesados?',
    'El palco tiene 5 lugares por partido; algunos partidos (p. ej. la inauguración) tienen más demanda.', null,
    '{"options":["Sorteo","Rotación entre familias","Antigüedad","First Come First Served"]}'::jsonb,
    'seed-dec-palco', 'single_choice');

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
  -- 13. HIERARCHY (R.2U) — Familia Mizrahi es el contexto raíz
  -- ───────────────────────────────────────────────────────────────────────────
  --   Familia Mizrahi
  --    ├─ Comidas Miércoles Mizrahi
  --    ├─ Palco Mundial 2026
  --    └─ Proyecto Nave Industrial Toluca
  --        └─ Fideicomiso Nave Industrial
  --
  -- José es founder/admin de los 5 contextos, por lo que cumple la doble autoridad
  -- requerida por link_child_context (context.children.link en padre + context.manage en hijo).
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_jose_auth::text)::text, true);
  perform public.link_child_context(c_fam_miz,  c_comidas);
  perform public.link_child_context(c_fam_miz,  c_palco);
  perform public.link_child_context(c_fam_miz,  c_proyecto);
  perform public.link_child_context(c_proyecto, c_trust);

  -- ───────────────────────────────────────────────────────────────────────────
  -- Listo
  -- ───────────────────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', null, true);

  raise notice 'R.SEED.2 CANONICAL: OK — José=% · 7 contextos (incl. Palco Mundial 2026) · 5 recursos · 5 partidos reales con roster + 4 comidas · 4 decisiones · obligaciones (acción+capital) · renta Quimibond · 2 reglas · 4 documentos · trust sin beneficiarios · jerarquía R.2U Familia Mizrahi → 3 hijos → Fideicomiso.', a_jose;
end; $$;
