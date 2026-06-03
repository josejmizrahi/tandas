-- ============================================================================
-- R.2K — FULL REALITY + AUTH SIMULATION DoD
-- ============================================================================
-- La simulación maestra: 9 personas (vía el trigger REAL de auth.users),
-- 7 contextos (incluyendo legal_entity/company, legal_entity/trust y dos
-- comunidades), 5 recursos únicos, rights, reservaciones, eventos, reglas,
-- decisiones, money, settlement, activity, privacy y RLS — todo en un solo
-- smoke end-to-end.
--
-- Nuevo (permitido por el spec: "endpoint equivalente" del person context):
--   my_world() — agregación del mundo personal: contextos + recursos visibles
--   agrupados por resource_id con reasons[] + obligations abiertas propias.
--
-- Cero tablas nuevas. Cero rediseño de schema.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. my_world() — el person context / My World (R.2K sección 13)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.my_world()
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_me uuid := public.current_actor_id();
begin
  if v_me is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  return jsonb_build_object(
    'actor_id', v_me,
    -- contextos donde soy miembro activo
    'contexts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'context_actor_id', am.context_actor_id,
        'display_name', a.display_name,
        'actor_kind', a.actor_kind,
        'actor_subtype', a.actor_subtype,
        'membership_type', am.membership_type) order by a.display_name)
      from public.actor_memberships am
      join public.actors a on a.id = am.context_actor_id
      where am.member_actor_id = v_me and am.membership_status = 'active'), '[]'::jsonb),
    -- recursos visibles, agrupados por resource_id con reasons[] (sin duplicar filas):
    --   · mis rights directos activos
    --   · rights de holders colectivos que puedo ejercer (resources.manage)
    'resources', coalesce((
      select jsonb_agg(jsonb_build_object(
        'resource_id', r.id,
        'display_name', r.display_name,
        'resource_type', r.resource_type,
        'reasons', r.reasons) order by r.display_name)
      from (
        select res.id, res.display_name, res.resource_type,
               jsonb_agg(distinct reason.path) as reasons
        from public.resources res
        join lateral (
          select rr.right_kind as path
            from public.resource_rights rr
           where rr.resource_id = res.id and rr.holder_actor_id = v_me
             and rr.revoked_at is null and rr.expired_at is null
             and (rr.starts_at is null or rr.starts_at <= now())
             and (rr.ends_at is null or rr.ends_at > now())
          union all
          select rr.right_kind || ' via ' || h.display_name
            from public.resource_rights rr
            join public.actors h on h.id = rr.holder_actor_id
           where rr.resource_id = res.id and rr.holder_actor_id <> v_me
             and rr.revoked_at is null and rr.expired_at is null
             and (rr.starts_at is null or rr.starts_at <= now())
             and (rr.ends_at is null or rr.ends_at > now())
             and public.has_actor_authority(rr.holder_actor_id, v_me, 'resources.manage')
        ) reason on true
        where res.archived_at is null
        group by res.id, res.display_name, res.resource_type
      ) r), '[]'::jsonb),
    -- mis obligations abiertas (como deudor o acreedor)
    'open_obligations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'obligation_id', o.id,
        'context_actor_id', o.context_actor_id,
        'context_name', (select display_name from public.actors where id = o.context_actor_id),
        'role', case when o.debtor_actor_id = v_me then 'debtor' else 'creditor' end,
        'obligation_type', o.obligation_type,
        'amount', o.amount, 'currency', o.currency) order by o.created_at desc)
      from public.obligations o
      where (o.debtor_actor_id = v_me or o.creditor_actor_id = v_me) and o.status = 'open'), '[]'::jsonb));
end; $$;

revoke all on function public.my_world() from public, anon;
grant execute on function public.my_world() to authenticated, service_role;

comment on function public.my_world() is
  'R.2K: el mundo personal del actor — contextos, recursos visibles (agrupados con reasons[]) y obligations abiertas propias. Nunca incluye información de contextos/actores ajenos.';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. El smoke maestro
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2k_full_reality_auth_simulation()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  -- auth ids
  u_jose uuid := gen_random_uuid(); u_david uuid := gen_random_uuid(); u_isaac uuid := gen_random_uuid();
  u_moises uuid := gen_random_uuid(); u_daniel uuid := gen_random_uuid(); u_abuelo uuid := gen_random_uuid();
  u_linda uuid := gen_random_uuid(); u_banco uuid := gen_random_uuid(); u_out uuid := gen_random_uuid();
  -- actor ids
  a_jose uuid; a_david uuid; a_isaac uuid; a_moises uuid; a_daniel uuid; a_abuelo uuid;
  a_linda uuid; a_banco uuid; a_out uuid;
  -- contextos
  c_cena uuid; c_viaje uuid; c_familia uuid; c_negocio uuid; c_sinai uuid; c_maguen uuid; c_trust uuid;
  -- recursos
  r_casa uuid; r_terreno uuid; r_acciones uuid; r_cuenta uuid; r_salon uuid;
  -- flujo
  v_code text; v_starts timestamptz; v_event uuid; v_batch uuid;
  v_res_david uuid; v_res_isaac uuid; v_conflict record;
  v_decision uuid; v_result jsonb; v_world jsonb;
  v_caught boolean; v_item record; v_n integer;
  v_type text; v_missing text[] := array[]::text[];
  r record;
begin
  -- ═══════════════════════════════════════════════════════════════════
  -- 1. AUTH: el trigger real de auth.users crea person_profiles + actors
  -- ═══════════════════════════════════════════════════════════════════
  for r in
    select * from (values
      ('José R2K', u_jose), ('David R2K', u_david), ('Isaac R2K', u_isaac),
      ('Moisés R2K', u_moises), ('Daniel R2K', u_daniel), ('Abuelo R2K', u_abuelo),
      ('Linda R2K', u_linda), ('Banco Fiduciario R2K', u_banco), ('Outsider R2K', u_out)) t(who, uid)
  loop
    insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (r.uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            lower(replace(split_part(r.who, ' ', 1), 'é', 'e')) || '.' || substr(r.uid::text, 1, 8) || '@r2k.test',
            '{"provider": "email", "providers": ["email"]}'::jsonb,
            jsonb_build_object('full_name', r.who), now(), now());
  end loop;

  -- el trigger creó la cadena auth.users → person_profiles → actors
  select actor_id into a_jose from public.person_profiles where auth_user_id = u_jose;
  select actor_id into a_david from public.person_profiles where auth_user_id = u_david;
  select actor_id into a_isaac from public.person_profiles where auth_user_id = u_isaac;
  select actor_id into a_moises from public.person_profiles where auth_user_id = u_moises;
  select actor_id into a_daniel from public.person_profiles where auth_user_id = u_daniel;
  select actor_id into a_abuelo from public.person_profiles where auth_user_id = u_abuelo;
  select actor_id into a_linda from public.person_profiles where auth_user_id = u_linda;
  select actor_id into a_banco from public.person_profiles where auth_user_id = u_banco;
  select actor_id into a_out from public.person_profiles where auth_user_id = u_out;
  if a_jose is null or a_david is null or a_isaac is null or a_moises is null or a_daniel is null
     or a_abuelo is null or a_linda is null or a_banco is null or a_out is null then
    raise exception 'R2K 1 FAIL: el trigger de auth no creó la cadena auth.users → person_profiles → actors';
  end if;

  -- current_actor_id() correcto por usuario (spot check con 3)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  if public.current_actor_id() is distinct from a_jose then
    raise exception 'R2K 1 FAIL: current_actor_id() incorrecto para José';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_banco::text)::text, true);
  if public.current_actor_id() is distinct from a_banco then
    raise exception 'R2K 1 FAIL: current_actor_id() incorrecto para Banco';
  end if;

  -- anon bloqueado en TODOS los RPCs de la app (sweep dinámico)
  perform public._assert_anon_has_no_function_access();

  -- ═══════════════════════════════════════════════════════════════════
  -- 2. CONTEXTOS (7, incluyendo legal_entity y trust)
  -- ═══════════════════════════════════════════════════════════════════
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  c_cena := (public.create_context('Cena Semanal Amigos', 'collective', 'friend_group'))->>'context_actor_id';
  c_viaje := (public.create_context('Viaje Japón 2028', 'collective', 'trip'))->>'context_actor_id';
  c_negocio := (public.create_context('Negocio Valle', 'legal_entity', 'company'))->>'context_actor_id';
  c_sinai := (public.create_context('Monte Sinaí', 'collective', 'community'))->>'context_actor_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  c_familia := (public.create_context('Familia Mizrahi', 'collective', 'family'))->>'context_actor_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  c_maguen := (public.create_context('Maguén David', 'collective', 'community'))->>'context_actor_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_banco::text)::text, true);
  c_trust := (public.create_context('Trust Familiar', 'legal_entity', 'trust'))->>'context_actor_id';

  if (select count(*) from public.actors where id in (c_cena, c_viaje, c_familia, c_negocio, c_sinai, c_maguen, c_trust)) <> 7 then
    raise exception 'R2K 2 FAIL: no se crearon los 7 contextos';
  end if;
  if (select actor_kind from public.actors where id = c_negocio) <> 'legal_entity'
     or (select actor_subtype from public.actors where id = c_trust) <> 'trust' then
    raise exception 'R2K 2 FAIL: kinds/subtypes de legal entity / trust incorrectos';
  end if;

  -- ═══════════════════════════════════════════════════════════════════
  -- 3. MEMBERSHIPS + context_candidates por actor
  -- ═══════════════════════════════════════════════════════════════════
  -- Cena: José (founder) + David, Isaac, Moisés, Daniel
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_code := (public.create_invite(c_cena::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Viaje: José (founder) + David, Isaac
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_code := (public.create_invite(c_viaje::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Familia: Abuelo (founder) + José, David, Isaac, Moisés, Daniel, Linda
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_code := (public.create_invite(c_familia::uuid))->>'code';
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
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_linda::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Negocio: José (founder) + David
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_code := (public.create_invite(c_negocio::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Monte Sinaí: José (founder) + David, Daniel
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_code := (public.create_invite(c_sinai::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Maguén David: Isaac (founder) + Moisés
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_code := (public.create_invite(c_maguen::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Trust: Banco (founder/trustee/admin) + Linda (beneficiary/member) + José (advisor/observer)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_banco::text)::text, true);
  v_code := (public.create_invite(c_trust::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_linda::text)::text, true);
  perform public.join_by_invite_code(v_code);
  -- José como observer (no hay RPC de membership_type custom — fixture aceptado por el spec)
  insert into public.actor_memberships (context_actor_id, member_actor_id, membership_status, membership_type)
  values (c_trust::uuid, a_jose, 'active', 'observer');

  -- Relationships del trust y del negocio (no hay RPC — son data del modelo)
  insert into public.actor_relationships (subject_actor_id, relationship_type, object_actor_id, created_by_actor_id, metadata) values
    (a_banco, 'trustee_of', c_trust::uuid, a_banco, '{}'),
    (a_linda, 'beneficiary_of', c_trust::uuid, a_banco, '{}'),
    (a_jose, 'related_to', c_trust::uuid, a_banco, '{"role": "advisor"}'),
    (a_jose, 'shareholder_of', c_negocio::uuid, a_jose, '{"percent": 50}'),
    (a_david, 'shareholder_of', c_negocio::uuid, a_jose, '{"percent": 50}');

  -- ═══ Validar context_candidates por actor ═══
  -- José ve 6 (todos menos Maguén David)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.context_candidates();
  if (select count(*) from jsonb_array_elements(v_result->'contexts') c
      where (c->>'context_actor_id')::uuid in (c_cena::uuid, c_viaje::uuid, c_familia::uuid, c_negocio::uuid, c_sinai::uuid, c_trust::uuid)) <> 6
     or exists (select 1 from jsonb_array_elements(v_result->'contexts') c
                where (c->>'context_actor_id')::uuid = c_maguen::uuid) then
    raise exception 'R2K 3 FAIL: candidates de José incorrectos';
  end if;
  -- Isaac ve 4 (Cena, Viaje, Familia, Maguén) y NO Negocio/Sinaí/Trust
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_result := public.context_candidates();
  if (select count(*) from jsonb_array_elements(v_result->'contexts') c
      where (c->>'context_actor_id')::uuid in (c_cena::uuid, c_viaje::uuid, c_familia::uuid, c_maguen::uuid)) <> 4
     or exists (select 1 from jsonb_array_elements(v_result->'contexts') c
                where (c->>'context_actor_id')::uuid in (c_negocio::uuid, c_sinai::uuid, c_trust::uuid)) then
    raise exception 'R2K 3 FAIL: candidates de Isaac incorrectos';
  end if;
  -- Daniel ve 3 (Cena, Familia, Sinaí) y NO Viaje/Negocio/Maguén/Trust
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  v_result := public.context_candidates();
  if (select count(*) from jsonb_array_elements(v_result->'contexts') c
      where (c->>'context_actor_id')::uuid in (c_cena::uuid, c_familia::uuid, c_sinai::uuid)) <> 3
     or exists (select 1 from jsonb_array_elements(v_result->'contexts') c
                where (c->>'context_actor_id')::uuid in (c_viaje::uuid, c_negocio::uuid, c_maguen::uuid, c_trust::uuid)) then
    raise exception 'R2K 3 FAIL: candidates de Daniel incorrectos';
  end if;
  -- Outsider autenticado sin memberships: cero contextos del mundo
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_result := public.context_candidates();
  if exists (select 1 from jsonb_array_elements(v_result->'contexts') c
             where (c->>'context_actor_id')::uuid in
               (c_cena::uuid, c_viaje::uuid, c_familia::uuid, c_negocio::uuid, c_sinai::uuid, c_maguen::uuid, c_trust::uuid)) then
    raise exception 'R2K 3 FAIL: el outsider ve contextos privados';
  end if;

  -- ═══════════════════════════════════════════════════════════════════
  -- 4. RECURSOS ÚNICOS + RIGHTS + visibilidad
  -- ═══════════════════════════════════════════════════════════════════
  -- Casa Valle: Abuelo OWN 100% (personal) → rights a Familia/José/David/Isaac/Moisés/Trust
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  r_casa := (public.create_resource(a_abuelo, 'house', 'Casa Valle R2K'))->>'resource_id';
  perform public.grant_right(r_casa::uuid, c_familia::uuid, 'GOVERN');
  perform public.grant_right(r_casa::uuid, a_jose, 'USE');
  perform public.grant_right(r_casa::uuid, a_david, 'USE');
  perform public.grant_right(r_casa::uuid, a_isaac, 'USE');
  perform public.grant_right(r_casa::uuid, a_moises, 'VIEW');
  perform public.grant_right(r_casa::uuid, c_trust::uuid, 'BENEFICIARY');

  -- Terreno Valle: José crea → José OWN 50%, David OWN 50%, Negocio MANAGE
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  r_terreno := (public.create_resource(a_jose, 'property', 'Terreno Valle R2K'))->>'resource_id';
  perform public.grant_right(r_terreno::uuid, a_jose, 'OWN', 50);
  perform public.grant_right(r_terreno::uuid, a_david, 'OWN', 50);
  perform public.grant_right(r_terreno::uuid, c_negocio::uuid, 'MANAGE');

  -- Acciones Quimibond: en el Trust (Banco admin) → Trust OWN + Linda BENEFICIARY + Banco MANAGE
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_banco::text)::text, true);
  r_acciones := (public.create_resource(c_trust::uuid, 'other', 'Acciones Quimibond R2K'))->>'resource_id';
  perform public.grant_right(r_acciones::uuid, a_linda, 'BENEFICIARY');
  perform public.grant_right(r_acciones::uuid, a_banco, 'MANAGE');

  -- Cuenta Viaje Japón: en el Viaje → Viaje MANAGE + José/David/Isaac VIEW
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  r_cuenta := (public.create_resource(c_viaje::uuid, 'bank_account', 'Cuenta Viaje Japón R2K'))->>'resource_id';
  perform public.grant_right(r_cuenta::uuid, c_viaje::uuid, 'MANAGE');
  perform public.grant_right(r_cuenta::uuid, a_jose, 'VIEW');
  perform public.grant_right(r_cuenta::uuid, a_david, 'VIEW');
  perform public.grant_right(r_cuenta::uuid, a_isaac, 'VIEW');

  -- Salón Monte Sinaí: en Monte Sinaí → Sinaí MANAGE + José/David/Daniel VIEW
  r_salon := (public.create_resource(c_sinai::uuid, 'other', 'Salón Monte Sinaí R2K'))->>'resource_id';
  perform public.grant_right(r_salon::uuid, c_sinai::uuid, 'MANAGE');
  perform public.grant_right(r_salon::uuid, a_jose, 'VIEW');
  perform public.grant_right(r_salon::uuid, a_david, 'VIEW');
  perform public.grant_right(r_salon::uuid, a_daniel, 'VIEW');

  -- Cada recurso existe UNA sola vez (no copias por contexto)
  if (select count(*) from public.resources where display_name like '%R2K' and archived_at is null) <> 5 then
    raise exception 'R2K 4 FAIL: los recursos no son únicos (hay % con sufijo R2K)',
      (select count(*) from public.resources where display_name like '%R2K');
  end if;

  -- Matriz de visibilidad por rights (resource_detail)
  -- José ve Casa (USE), Terreno (OWN), Cuenta (VIEW), Salón (VIEW)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.resource_detail(r_casa::uuid);
  perform public.resource_detail(r_terreno::uuid);
  perform public.resource_detail(r_cuenta::uuid);
  perform public.resource_detail(r_salon::uuid);
  -- Linda ve Acciones (BENEFICIARY)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_linda::text)::text, true);
  perform public.resource_detail(r_acciones::uuid);
  -- Banco ve Acciones (MANAGE)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_banco::text)::text, true);
  perform public.resource_detail(r_acciones::uuid);
  -- Isaac NO ve Terreno Valle (sin rights)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_caught := false;
  begin perform public.resource_detail(r_terreno::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 4 FAIL: Isaac ve Terreno Valle sin rights'; end if;
  -- Daniel NO ve Cuenta Viaje
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  v_caught := false;
  begin perform public.resource_detail(r_cuenta::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 4 FAIL: Daniel ve la Cuenta del Viaje sin rights'; end if;

  -- ═══════════════════════════════════════════════════════════════════
  -- 5. CENA FLOW: reglas + evento + check-ins + multas (sin duplicados)
  -- ═══════════════════════════════════════════════════════════════════
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.create_rule(c_cena::uuid, 'Multa por llegar tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": ">", "field": "minutes_late", "value": 15}]}'::jsonb,
    p_consequences := '[{"type": "create_obligation", "obligation_type": "fine", "amount": 100, "currency": "MXN", "reason": "late_arrival"}]'::jsonb);
  perform public.create_rule(c_cena::uuid, 'Multa por cancelar mismo día',
    p_trigger_event_type := 'event.participation_cancelled',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": "=", "field": "same_day_cancellation", "value": true}]}'::jsonb,
    p_consequences := '[{"type": "create_obligation", "obligation_type": "fine", "amount": 300, "currency": "MXN", "reason": "same_day_cancellation"}]'::jsonb);

  v_starts := now() - interval '21 minutes';
  v_event := (public.create_calendar_event(c_cena::uuid, 'Cena miércoles', 'dinner',
    p_starts_at := v_starts, p_ends_at := v_starts + interval '3 hours',
    p_timezone := 'America/Mexico_City', p_host_actor_id := a_david,
    p_client_id := 'r2k-cena-001'))->>'event_id';

  -- RSVPs ×5 going
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');

  -- Check-ins: David 20:00, José 20:05, Isaac 20:12 (host registra), Moisés 20:21 (late), Daniel cancela same-day
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.check_in_participant(v_event::uuid, p_checked_in_at := v_starts);
  perform public.check_in_participant(v_event::uuid, a_jose, v_starts + interval '5 minutes');
  perform public.check_in_participant(v_event::uuid, a_isaac, v_starts + interval '12 minutes');
  perform public.cancel_participation(v_event::uuid, a_daniel, v_starts);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.check_in_participant(v_event::uuid);

  -- Multas correctas: Moisés $100 + Daniel $300, nadie más
  if (select count(*) from public.obligations where context_actor_id = c_cena::uuid and obligation_type = 'fine') <> 2
     or not exists (select 1 from public.obligations where context_actor_id = c_cena::uuid and debtor_actor_id = a_moises and amount = 100 and obligation_type = 'fine')
     or not exists (select 1 from public.obligations where context_actor_id = c_cena::uuid and debtor_actor_id = a_daniel and amount = 300 and obligation_type = 'fine')
     or exists (select 1 from public.obligations where context_actor_id = c_cena::uuid and obligation_type = 'fine'
                and debtor_actor_id in (a_jose, a_david, a_isaac)) then
    raise exception 'R2K 5 FAIL: multas incorrectas';
  end if;

  -- Re-evaluar no duplica (idempotencia del rule engine)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.evaluate_rules_for_event(c_cena::uuid, 'event.checked_in', a_moises,
    jsonb_build_object('minutes_late', 21, 'status', 'late', 'event_type', 'dinner'), v_event::uuid);
  if (select count(*) from public.obligations where context_actor_id = c_cena::uuid and obligation_type = 'fine') <> 2 then
    raise exception 'R2K 5 FAIL: re-evaluar duplicó multas';
  end if;

  -- ═══════════════════════════════════════════════════════════════════
  -- 6. EXPENSE CENA + JUEGO
  -- ═══════════════════════════════════════════════════════════════════
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.record_expense(c_cena::uuid, 1300, 'MXN', 'Pizza, cerveza y botanas',
    p_split_with := array[a_david, a_jose, a_isaac, a_moises],
    p_event_id := v_event::uuid, p_client_id := 'r2k-cena-expense-001',
    p_excluded_actor_ids := array[a_daniel]);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.record_game_result(c_cena::uuid, v_event::uuid, 'Catan', a_moises, a_daniel, 250, 'MXN', 'r2k-catan-001');

  if (select count(*) from public.obligations where context_actor_id = c_cena::uuid
      and obligation_type = 'expense_share' and creditor_actor_id = a_david and amount = 325) <> 3
     or exists (select 1 from public.obligations where debtor_actor_id = a_david and creditor_actor_id = a_david)
     or exists (select 1 from public.obligations where context_actor_id = c_cena::uuid
                and debtor_actor_id = a_daniel and creditor_actor_id = a_david)
     or not exists (select 1 from public.obligations where context_actor_id = c_cena::uuid
                    and debtor_actor_id = a_daniel and creditor_actor_id = a_moises
                    and obligation_type = 'game_debt' and amount = 250) then
    raise exception 'R2K 6 FAIL: gastos/juego incorrectos';
  end if;

  -- ═══════════════════════════════════════════════════════════════════
  -- 7. SETTLEMENT CENA
  -- ═══════════════════════════════════════════════════════════════════
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.generate_settlement_batch(c_cena::uuid, 'MXN');
  v_batch := (v_result->>'batch_id')::uuid;
  -- los items balancean (suma de pagos = suma de netos positivos) y sin self-pagos
  if exists (select 1 from public.settlement_items where settlement_batch_id = v_batch and from_actor_id = to_actor_id)
     or exists (select 1 from public.settlement_items where settlement_batch_id = v_batch and amount <= 0) then
    raise exception 'R2K 7 FAIL: settlement con self-pagos o montos inválidos';
  end if;
  -- pagar todo (admin) + idempotencia
  for v_item in select id from public.settlement_items where settlement_batch_id = v_batch and status = 'pending' loop
    perform public.mark_settlement_paid(v_item.id);
    v_result := public.mark_settlement_paid(v_item.id);
    if not coalesce((v_result->>'already_paid')::boolean, false) then
      raise exception 'R2K 7 FAIL: mark_settlement_paid no es idempotente';
    end if;
  end loop;
  if (select count(*) from public.obligations where context_actor_id = c_cena::uuid and status = 'open') <> 0 then
    raise exception 'R2K 7 FAIL: quedaron obligations abiertas en la cena tras el settlement';
  end if;

  -- ═══════════════════════════════════════════════════════════════════
  -- 8. CASA VALLE RESERVATIONS (least_recent_use_wins)
  -- ═══════════════════════════════════════════════════════════════════
  -- Historial: David 2 confirmadas/completadas, Isaac 0
  insert into public.resource_reservations (resource_id, context_actor_id, requested_by_actor_id, reserved_for_actor_id, starts_at, ends_at, status) values
    (r_casa::uuid, c_familia::uuid, a_david, a_david, now() - interval '60 days', now() - interval '58 days', 'completed'),
    (r_casa::uuid, c_familia::uuid, a_david, a_david, now() - interval '30 days', now() - interval '28 days', 'completed');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_res_david := (public.request_resource_reservation(r_casa::uuid, c_familia::uuid,
    '2026-07-10 16:00-06'::timestamptz, '2026-07-12 18:00-06'::timestamptz,
    p_client_id := 'r2k-res-david-001'))->>'reservation_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_res_isaac := (public.request_resource_reservation(r_casa::uuid, c_familia::uuid,
    '2026-07-10 16:00-06'::timestamptz, '2026-07-12 18:00-06'::timestamptz))->>'reservation_id';

  select * into v_conflict from public.reservation_conflicts
   where resource_id = r_casa::uuid and resolution_status = 'open' limit 1;
  if v_conflict.recommended_winner_actor_id is distinct from a_isaac then
    raise exception 'R2K 8 FAIL: least_recent_use_wins no recomendó a Isaac';
  end if;

  -- Abuelo (admin Familia + OWN) resuelve a favor de Isaac → Isaac confirma
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  perform public.resolve_reservation_conflict(v_conflict.id, v_res_isaac::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.confirm_reservation(v_res_isaac::uuid);
  if (select status from public.resource_reservations where id = v_res_isaac::uuid) <> 'confirmed'
     or (select status from public.resource_reservations where id = v_res_david::uuid) <> 'rejected' then
    raise exception 'R2K 8 FAIL: resolución de conflicto incorrecta';
  end if;
  -- no hay dos approved/confirmed traslapadas
  if exists (
    select 1 from public.resource_reservations a
    join public.resource_reservations b on b.resource_id = a.resource_id and b.id > a.id
     and tstzrange(a.starts_at, a.ends_at) && tstzrange(b.starts_at, b.ends_at)
    where a.resource_id = r_casa::uuid
      and a.status in ('approved', 'confirmed') and b.status in ('approved', 'confirmed')
  ) then
    raise exception 'R2K 8 FAIL: reservaciones traslapadas approved/confirmed';
  end if;
  -- Moisés (VIEW) no puede reservar; Outsider tampoco
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  v_caught := false;
  begin perform public.request_resource_reservation(r_casa::uuid, c_familia::uuid,
    now() + interval '30 days', now() + interval '32 days');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 8 FAIL: Moisés (VIEW) pudo reservar'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_caught := false;
  begin perform public.request_resource_reservation(r_casa::uuid, c_familia::uuid,
    now() + interval '30 days', now() + interval '32 days');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 8 FAIL: Outsider pudo reservar'; end if;

  -- ═══════════════════════════════════════════════════════════════════
  -- 9. VIAJE JAPÓN: hotel $30,000 entre 3 + aislamiento
  -- ═══════════════════════════════════════════════════════════════════
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.record_expense(c_viaje::uuid, 30000, 'MXN', 'Hotel Tokio',
    p_split_with := array[a_jose, a_david, a_isaac], p_client_id := 'r2k-hotel-001');

  if (select count(*) from public.obligations where context_actor_id = c_viaje::uuid
      and obligation_type = 'expense_share' and creditor_actor_id = a_jose and amount = 10000) <> 2
     or exists (select 1 from public.obligations where context_actor_id = c_viaje::uuid
                and debtor_actor_id in (a_daniel, a_moises)) then
    raise exception 'R2K 9 FAIL: gasto del viaje incorrecto o contaminado';
  end if;
  -- Daniel y Moisés no ven el Viaje
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  if public.is_context_member(c_viaje::uuid) then
    raise exception 'R2K 9 FAIL: Daniel es miembro del Viaje';
  end if;
  v_caught := false;
  begin perform public.context_summary(c_viaje::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 9 FAIL: Daniel ve el Viaje'; end if;

  -- ═══════════════════════════════════════════════════════════════════
  -- 10. NEGOCIO VALLE: decisión + contributions
  -- ═══════════════════════════════════════════════════════════════════
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_decision := (public.create_decision(c_negocio::uuid, 'expense_approval',
    '¿Invertimos $100,000 MXN en permisos?',
    p_payload := '{"amount": 100000, "currency": "MXN"}'::jsonb,
    p_client_id := 'r2k-decision-001'))->>'decision_id';
  perform public.vote_decision(v_decision::uuid, 'approve');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.vote_decision(v_decision::uuid, 'approve');
  if v_result->>'status' <> 'approved' then
    raise exception 'R2K 10 FAIL: decisión del negocio no aprobada';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.execute_decision(v_decision::uuid);

  -- Contributions derivadas de la decisión (provenance: source_decision_id)
  insert into public.obligations (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type, amount, currency, status, source_decision_id, metadata) values
    (c_negocio::uuid, a_jose, c_negocio::uuid, 'contribution', 50000, 'MXN', 'open', v_decision::uuid, '{"reason": "inversión permisos"}'),
    (c_negocio::uuid, a_david, c_negocio::uuid, 'contribution', 50000, 'MXN', 'open', v_decision::uuid, '{"reason": "inversión permisos"}');

  -- Isaac y Daniel no ven el Negocio; el Terreno no se duplicó
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_caught := false;
  begin perform public.context_summary(c_negocio::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 10 FAIL: Isaac ve el Negocio'; end if;
  if (select count(*) from public.resources where display_name = 'Terreno Valle R2K') <> 1 then
    raise exception 'R2K 10 FAIL: el Terreno se duplicó';
  end if;

  -- ═══════════════════════════════════════════════════════════════════
  -- 11. COMUNIDADES: cuotas aisladas
  -- ═══════════════════════════════════════════════════════════════════
  insert into public.obligations (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type, amount, currency, status, metadata) values
    (c_sinai::uuid, a_jose, c_sinai::uuid, 'dues', 1800, 'MXN', 'open', '{"reason": "cuota evento"}'),
    (c_sinai::uuid, a_david, c_sinai::uuid, 'dues', 1800, 'MXN', 'open', '{"reason": "cuota evento"}'),
    (c_sinai::uuid, a_daniel, c_sinai::uuid, 'dues', 1800, 'MXN', 'open', '{"reason": "cuota evento"}'),
    (c_maguen::uuid, a_isaac, c_maguen::uuid, 'dues', 500, 'MXN', 'open', '{"reason": "cuota evento"}'),
    (c_maguen::uuid, a_moises, c_maguen::uuid, 'dues', 500, 'MXN', 'open', '{"reason": "cuota evento"}');

  -- José no ve Maguén David; Isaac no ve Monte Sinaí; las cuotas no se mezclan
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_caught := false;
  begin perform public.context_summary(c_maguen::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 11 FAIL: José ve Maguén David'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_caught := false;
  begin perform public.context_summary(c_sinai::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 11 FAIL: Isaac ve Monte Sinaí'; end if;
  if exists (select 1 from public.obligations where context_actor_id = c_sinai::uuid and debtor_actor_id in (a_isaac, a_moises))
     or exists (select 1 from public.obligations where context_actor_id = c_maguen::uuid and debtor_actor_id in (a_jose, a_david, a_daniel)) then
    raise exception 'R2K 11 FAIL: cuotas mezcladas entre comunidades';
  end if;

  -- ═══════════════════════════════════════════════════════════════════
  -- 12. TRUST FAMILIAR
  -- ═══════════════════════════════════════════════════════════════════
  -- Banco (admin/trustee) administra; Linda (beneficiary) ve pero no transfiere;
  -- José (observer) ve el contexto; Outsider no ve nada; las Acciones son únicas
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_banco::text)::text, true);
  perform public.resource_detail(r_acciones::uuid);  -- Banco ve (MANAGE)
  perform public.context_summary(c_trust::uuid);     -- Banco administra
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_linda::text)::text, true);
  perform public.resource_detail(r_acciones::uuid);  -- Linda ve (BENEFICIARY)
  -- Linda no puede transferir (grant SELL requiere OWN)
  v_caught := false;
  begin perform public.grant_right(r_acciones::uuid, a_linda, 'SELL');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 12 FAIL: Linda (beneficiary) pudo auto-otorgarse SELL'; end if;
  -- José (observer) ve el contexto del Trust
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.context_summary(c_trust::uuid);
  -- Outsider no ve el Trust
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_caught := false;
  begin perform public.context_summary(c_trust::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 12 FAIL: Outsider ve el Trust'; end if;
  -- Acciones únicas
  if (select count(*) from public.resources where display_name = 'Acciones Quimibond R2K') <> 1 then
    raise exception 'R2K 12 FAIL: las Acciones se duplicaron';
  end if;

  -- ═══════════════════════════════════════════════════════════════════
  -- 13. PERSON CONTEXT / MY WORLD (José)
  -- ═══════════════════════════════════════════════════════════════════
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_world := public.my_world();

  -- contextos: los 6 de José, sin Maguén David
  if (select count(*) from jsonb_array_elements(v_world->'contexts') c
      where (c->>'context_actor_id')::uuid in (c_cena::uuid, c_viaje::uuid, c_familia::uuid, c_negocio::uuid, c_sinai::uuid, c_trust::uuid)) <> 6
     or exists (select 1 from jsonb_array_elements(v_world->'contexts') c
                where (c->>'context_actor_id')::uuid = c_maguen::uuid) then
    raise exception 'R2K 13 FAIL: my_world contextos incorrectos';
  end if;
  -- recursos: Casa (USE), Terreno (OWN), Cuenta (VIEW), Salón (VIEW) — agrupados, sin duplicados
  if not exists (select 1 from jsonb_array_elements(v_world->'resources') r2
                 where (r2->>'resource_id')::uuid = r_casa::uuid and r2->'reasons' ? 'USE')
     or not exists (select 1 from jsonb_array_elements(v_world->'resources') r2
                    where (r2->>'resource_id')::uuid = r_terreno::uuid and r2->'reasons' ? 'OWN')
     or not exists (select 1 from jsonb_array_elements(v_world->'resources') r2
                    where (r2->>'resource_id')::uuid = r_cuenta::uuid and r2->'reasons' ? 'VIEW')
     or not exists (select 1 from jsonb_array_elements(v_world->'resources') r2
                    where (r2->>'resource_id')::uuid = r_salon::uuid and r2->'reasons' ? 'VIEW') then
    raise exception 'R2K 13 FAIL: my_world recursos/reasons incorrectos';
  end if;
  -- cada recurso aparece exactamente una vez (agrupación correcta)
  if (select count(*) from jsonb_array_elements(v_world->'resources') r2)
     <> (select count(distinct r2->>'resource_id') from jsonb_array_elements(v_world->'resources') r2) then
    raise exception 'R2K 13 FAIL: my_world duplica recursos';
  end if;
  -- las Acciones del Trust NO aparecen (José no tiene right directo ni autoridad de manage en el Trust)
  if exists (select 1 from jsonb_array_elements(v_world->'resources') r2
             where (r2->>'resource_id')::uuid = r_acciones::uuid) then
    raise exception 'R2K 13 FAIL: my_world filtra recursos del Trust a un observer';
  end if;
  -- obligations: Viaje (creditor) + Negocio (debtor) + Monte Sinaí (debtor); la Cena ya se liquidó;
  -- nada de Maguén David ni obligations de otros
  if not exists (select 1 from jsonb_array_elements(v_world->'open_obligations') o
                 where (o->>'context_actor_id')::uuid = c_viaje::uuid and o->>'role' = 'creditor')
     or not exists (select 1 from jsonb_array_elements(v_world->'open_obligations') o
                    where (o->>'context_actor_id')::uuid = c_negocio::uuid and o->>'role' = 'debtor')
     or not exists (select 1 from jsonb_array_elements(v_world->'open_obligations') o
                    where (o->>'context_actor_id')::uuid = c_sinai::uuid and o->>'role' = 'debtor')
     or exists (select 1 from jsonb_array_elements(v_world->'open_obligations') o
                where (o->>'context_actor_id')::uuid in (c_maguen::uuid, c_cena::uuid)) then
    raise exception 'R2K 13 FAIL: my_world obligations incorrectas';
  end if;

  -- ═══════════════════════════════════════════════════════════════════
  -- 14. ACTIVITY GLOBAL
  -- ═══════════════════════════════════════════════════════════════════
  foreach v_type in array array[
    'context.created', 'membership.joined', 'resource.created', 'right.granted',
    'event.created', 'event.rsvp_updated', 'event.checked_in', 'event.participation_cancelled',
    'rule.created', 'rule.evaluated', 'fine.created', 'obligation.created',
    'expense.recorded', 'split.generated',
    'reservation.requested', 'reservation.conflict_detected', 'reservation.conflict_resolved',
    'decision.created', 'decision.vote_cast', 'decision.executed',
    'settlement.generated', 'settlement.paid'
  ] loop
    if not exists (
      select 1 from public.activity_events
      where event_type = v_type
        and (context_actor_id in (c_cena::uuid, c_viaje::uuid, c_familia::uuid, c_negocio::uuid, c_sinai::uuid, c_maguen::uuid, c_trust::uuid)
             or actor_id in (a_jose, a_david, a_isaac, a_moises, a_daniel, a_abuelo, a_linda, a_banco))
    ) then
      v_missing := v_missing || v_type;
    end if;
  end loop;
  if array_length(v_missing, 1) > 0 then
    raise exception 'R2K 14 FAIL: faltan activities: %', v_missing;
  end if;

  -- sin subjects huérfanos ni referencias inexistentes (en los contextos del mundo)
  if exists (
    select 1 from public.activity_events ae
    where ae.context_actor_id in (c_cena::uuid, c_viaje::uuid, c_familia::uuid, c_negocio::uuid, c_sinai::uuid, c_maguen::uuid, c_trust::uuid)
      and (not exists (select 1 from public.actors a where a.id = ae.context_actor_id)
        or (ae.actor_id is not null and not exists (select 1 from public.actors a where a.id = ae.actor_id)))
  ) then
    raise exception 'R2K 14 FAIL: activity con referencias inexistentes';
  end if;

  -- list_activity respeta membresías: José lista la Cena; Outsider no puede
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  if jsonb_array_length((public.list_activity(c_cena::uuid))->'activity') = 0 then
    raise exception 'R2K 14 FAIL: list_activity vacío para un miembro';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_caught := false;
  begin perform public.list_activity(c_cena::uuid);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 14 FAIL: el Outsider listó activity ajena'; end if;

  -- ═══════════════════════════════════════════════════════════════════
  -- 15. AUTH / PRIVACY FINAL
  -- ═══════════════════════════════════════════════════════════════════
  -- Outsider: no puede RSVP, reservar, votar, registrar gastos, ni ver activity (ya probado)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_caught := false;
  begin perform public.rsvp_event(v_event::uuid, 'going');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 15 FAIL: Outsider pudo RSVP'; end if;
  v_caught := false;
  begin perform public.vote_decision(v_decision::uuid, 'approve');
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2K 15 FAIL: Outsider pudo votar'; end if;
  v_caught := false;
  begin perform public.record_expense(c_cena::uuid, 100, 'MXN', 'hack');
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 15 FAIL: Outsider registró gasto'; end if;

  -- Usuario A no puede actuar como usuario B:
  -- Isaac no puede registrar gasto pagado por David (sin money.record_for_others)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_caught := false;
  begin perform public.record_expense(c_cena::uuid, 100, 'MXN', 'por otro', p_paid_by_actor_id := a_david);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 15 FAIL: Isaac registró gasto como David'; end if;
  -- Isaac no puede hacer check-in de otros (no es host/admin)
  v_caught := false;
  begin perform public.check_in_participant(v_event::uuid, a_moises);
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'R2K 15 FAIL: Isaac hizo check-in por otro'; end if;
  -- Isaac no puede otorgar rights sobre la Casa (no tiene OWN/MANAGE)
  v_caught := false;
  begin perform public.grant_right(r_casa::uuid, a_isaac, 'OWN', 100);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'R2K 15 FAIL: Isaac se auto-otorgó OWN'; end if;

  -- ═══════════════════════════════════════════════════════════════════
  -- 16. IDEMPOTENCIA GLOBAL (client_ids re-ejecutados)
  -- ═══════════════════════════════════════════════════════════════════
  -- create_event
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  if ((public.create_calendar_event(c_cena::uuid, 'Cena miércoles', 'dinner',
        p_starts_at := v_starts, p_client_id := 'r2k-cena-001'))->>'event_id')::uuid is distinct from v_event::uuid then
    raise exception 'R2K 16 FAIL: create_event no es idempotente';
  end if;
  -- record_expense
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.record_expense(c_cena::uuid, 1300, 'MXN', 'Pizza, cerveza y botanas',
    p_split_with := array[a_david, a_jose, a_isaac, a_moises],
    p_event_id := v_event::uuid, p_client_id := 'r2k-cena-expense-001',
    p_excluded_actor_ids := array[a_daniel]);
  if not coalesce((v_result->>'idempotent_replay')::boolean, false) then
    raise exception 'R2K 16 FAIL: record_expense no es idempotente';
  end if;
  -- request_reservation
  if ((public.request_resource_reservation(r_casa::uuid, c_familia::uuid,
        '2026-07-10 16:00-06'::timestamptz, '2026-07-12 18:00-06'::timestamptz,
        p_client_id := 'r2k-res-david-001'))->>'reservation_id')::uuid is distinct from v_res_david::uuid then
    raise exception 'R2K 16 FAIL: request_reservation no es idempotente';
  end if;
  -- create_decision
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  if ((public.create_decision(c_negocio::uuid, 'expense_approval', '¿Invertimos $100,000 MXN en permisos?',
        p_client_id := 'r2k-decision-001'))->>'decision_id')::uuid is distinct from v_decision::uuid then
    raise exception 'R2K 16 FAIL: create_decision no es idempotente';
  end if;
  -- generate_settlement_batch (sin obligations abiertas en cena → falla controlada = no duplica)
  v_caught := false;
  begin perform public.generate_settlement_batch(c_cena::uuid, 'MXN');
  exception when others then v_caught := true; end;
  if not v_caught then
    -- si no falló es porque reusó un draft → verificar que no duplicó batches
    if (select count(*) from public.settlement_batches where context_actor_id = c_cena::uuid and currency = 'MXN') > 1 then
      raise exception 'R2K 16 FAIL: generate_settlement_batch duplicó batches';
    end if;
  end if;
  -- los gastos con client_id no duplicaron transactions
  if exists (
    select client_id from public.money_transactions
    where context_actor_id in (c_cena::uuid, c_viaje::uuid, c_negocio::uuid) and client_id is not null
    group by client_id having count(*) > 1
  ) then
    raise exception 'R2K 16 FAIL: transactions duplicadas por client_id';
  end if;

  -- ═══ Cleanup ═══
  perform set_config('request.jwt.claims', null, true);
  delete from public.actor_relationships where subject_actor_id in (a_jose, a_david, a_isaac, a_moises, a_daniel, a_abuelo, a_linda, a_banco);
  perform public._r2_cleanup_context(c_trust::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(c_maguen::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(c_sinai::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(c_negocio::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(c_viaje::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(c_familia::uuid, array[]::uuid[], array[]::uuid[]);
  perform public._r2_cleanup_context(c_cena::uuid,
    array[a_jose, a_david, a_isaac, a_moises, a_daniel, a_abuelo, a_linda, a_banco, a_out],
    array[u_jose, u_david, u_isaac, u_moises, u_daniel, u_abuelo, u_linda, u_banco, u_out]);

  raise notice 'R.2K FULL REALITY + AUTH SIMULATION: PASS — Backend MVP 2.0 validado end-to-end. Ruul soporta realidad multi-contexto con auth, resources únicos, rights, memberships, events, rules, reservations, decisions, money, settlement y activity sin leaks.';
end; $$;

revoke all on function public._smoke_r2k_full_reality_auth_simulation() from public, anon, authenticated;

comment on function public._smoke_r2k_full_reality_auth_simulation() is
  'R.2K DoD: simulación maestra end-to-end — 9 personas (trigger real de auth), 7 contextos (collective/legal_entity/trust/community), 5 recursos únicos, rights, eventos, reglas, reservaciones, decisiones, money, settlement, activity, my_world, privacy e idempotencia global.';

-- Wrapper CI
create or replace function public._smoke_mvp2_r2k_full_reality()
returns void language plpgsql security definer set search_path = public as $$
begin perform public._smoke_r2k_full_reality_auth_simulation(); end; $$;
revoke all on function public._smoke_mvp2_r2k_full_reality() from public, anon, authenticated;
