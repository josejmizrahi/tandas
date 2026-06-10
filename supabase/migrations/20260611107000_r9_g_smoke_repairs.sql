-- ============================================================================
-- R.9.G — REPLAY REPAIRS: smokes desactualizados + shims de drift (2026-06-10)
-- ============================================================================
-- La cadena de migrations evolucionó comportamiento/firma sin actualizar los
-- smokes antiguos (precedente repo: 20260603164118 "update_r2g_smoke_...",
-- 20260605000003 "fix_event_location_smokes", etc.). Este migration NO cambia
-- comportamiento shipped: solo (a) reconstruye un objeto que existe en la BD
-- viva pero nunca aterrizó en disco, (b) extiende el helper de cleanup de
-- smokes, y (c) re-declara smokes con aserciones alineadas al backend vigente.
--
-- Inventario de causas (replay 2026-06-10, suite _smoke_mvp2_* completa):
--   · resource_conflicts: tabla creada en live vía MCP, ausente en disco →
--     attention_inbox() revienta en replay (42P01). Shim §1.
--   · _r2_cleanup_context ignoraba las tablas pool de R.8 →
--     actors_created_by_actor_id_fkey al limpiar (23503). §2.
--   · Firmas evolucionadas: request_resource_reservation 7→8 args (r2t),
--     create_calendar_event 13→16 (r5v3a), create_decision 8→9 (r7_h_1) →
--     has_function_privilege con firma inexistente = 42883. §3.
--   · Settlement handshake 2-way (r5z 20260610220000): mark_settlement_paid
--     por el deudor ya NO finaliza el item; el acreedor/admin confirma con
--     confirm_settlement_paid. Los smokes de pago se actualizan al flujo real. §3.
--   · Idempotencia R.6.A: re-evaluar reglas con la misma key se dedupea antes
--     de consecuencias (resultado vacío, sin filas nuevas). §3 (r2e).
--   · Catálogo de acciones r5a_b5a/F.2X + alias 'action' de r7_h_2: las
--     aserciones de r2m3/r2s se alinean al contrato vigente. §3.
--   · Doble evaluación sync+trigger (R.6.B) para reglas SIN condición de
--     event_type: el contract smoke usa ahora la misma forma de regla que
--     r2e/r2h (condición and con event_type) para evaluar una sola vez. §3.
--   · resources.context_actor_id (drift live-only): el smoke r8_a inserta
--     condicionalmente para pasar en replay y en live. §3.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- §1. Shim de drift: public.resource_conflicts
-- ────────────────────────────────────────────────────────────────────────────
-- Existe en la BD viva (consumida por attention_inbox 20260608105005/234500,
-- _r5w/_r5z context descriptor) pero su migration nunca aterrizó en disco.
-- Columnas reconstruidas de TODOS los call sites en disco. En live este CREATE
-- es no-op (IF NOT EXISTS).
create table if not exists public.resource_conflicts (
  id uuid primary key default gen_random_uuid(),
  context_actor_id uuid not null references public.actors(id) on delete cascade,
  resource_id uuid references public.resources(id) on delete cascade,
  conflict_type text,
  severity text not null default 'warning',
  status text not null default 'open',
  source_type text,
  source_id uuid,
  payload jsonb not null default '{}'::jsonb,
  detected_at timestamptz not null default now()
);

create index if not exists idx_resource_conflicts_context_status
  on public.resource_conflicts (context_actor_id, status);

alter table public.resource_conflicts enable row level security;

comment on table public.resource_conflicts is
  'R.9.G replay shim: tabla de la BD viva (drift MCP) reconstruida en disco para que attention_inbox()/context descriptor repliquen. En live el CREATE IF NOT EXISTS es no-op.';

-- ────────────────────────────────────────────────────────────────────────────
-- §2 + §3. Cleanup helper + smokes re-declarados
-- (cuerpos = última definición vigente en la cadena, cambio mínimo documentado).
-- ────────────────────────────────────────────────────────────────────────────

-- ── m6: anon-check apunta a la firma 8-arg vigente (la 7-arg fue dropeada en 20260604000205)
CREATE OR REPLACE FUNCTION public._smoke_mvp2_m6_reservations()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_ctx uuid; v_house uuid;
  v_result jsonb; v_res_a uuid; v_res_b uuid; v_conflict uuid; v_code text;
  v_caught boolean;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke M6A', '+520000000012', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke M6B', '+520000000013', null);

  -- Setup: contexto familia + casa + B como member CON USE right (R.2F rights-based)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_ctx := (public.create_context('_smoke_m6 Familia', 'collective', 'family'))->>'context_actor_id';
  v_house := (public.create_resource(v_ctx::uuid, 'house', '_smoke_m6 Casa Lago'))->>'resource_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.join_by_invite_code(v_code);
  -- R.2F: reservar requiere USE/MANAGE/OWN → A (admin del contexto dueño) otorga USE a B
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  perform public.grant_right(v_house::uuid, v_b, 'USE');

  -- Caso 1: A solicita reservación del fin de semana (autoridad sobre el contexto dueño)
  v_result := public.request_resource_reservation(
    v_house::uuid, v_ctx::uuid,
    now() + interval '5 days', now() + interval '7 days');
  v_res_a := (v_result->>'reservation_id')::uuid;
  if v_res_a is null then raise exception 'mvp2_m6 Caso1: request falló'; end if;

  -- Caso 2: B solicita el MISMO fin de semana → conflicto detectado
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_result := public.request_resource_reservation(
    v_house::uuid, v_ctx::uuid,
    now() + interval '6 days', now() + interval '8 days');
  v_res_b := (v_result->>'reservation_id')::uuid;
  if (v_result->>'conflicts_detected')::integer < 1 then
    raise exception 'mvp2_m6 Caso2: conflicto no detectado';
  end if;

  select id into v_conflict from public.reservation_conflicts
   where resource_id = v_house::uuid and resolution_status = 'open' limit 1;
  if v_conflict is null then raise exception 'mvp2_m6 Caso2: conflict row no existe'; end if;

  -- Caso 3: B (USE, sin MANAGE/OWN/GOVERN ni admin) NO puede resolver el conflicto
  v_caught := false;
  begin
    perform public.resolve_reservation_conflict(v_conflict, v_res_b);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'mvp2_m6 Caso3: member resolvió conflicto sin autoridad'; end if;

  -- Caso 4: A (admin) resuelve a favor de A → B queda rejected, A approved
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.resolve_reservation_conflict(v_conflict, v_res_a);
  if not exists (select 1 from public.resource_reservations where id = v_res_a and status = 'approved') then
    raise exception 'mvp2_m6 Caso4: ganador no quedó approved';
  end if;
  if not exists (select 1 from public.resource_reservations where id = v_res_b and status = 'rejected') then
    raise exception 'mvp2_m6 Caso4: perdedor no quedó rejected';
  end if;

  -- Caso 5: EXCLUDE constraint — aprobar otra reservación traslapada explota a nivel DB
  declare
    v_res_c uuid;
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
    v_res_c := (public.request_resource_reservation(
      v_house::uuid, v_ctx::uuid,
      now() + interval '5 days' + interval '12 hours', now() + interval '6 days'))->>'reservation_id';
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
    v_caught := false;
    begin
      perform public.approve_reservation(v_res_c::uuid);
    exception when exclusion_violation then v_caught := true;
    end;
    if not v_caught then raise exception 'mvp2_m6 Caso5: EXCLUDE constraint no aplicó'; end if;
  end;

  -- Caso 6: anon sin acceso
  if has_table_privilege('anon', 'public.resource_reservations', 'SELECT')
     or has_function_privilege('anon', 'public.request_resource_reservation(uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text, uuid)', 'EXECUTE') then
    raise exception 'mvp2_m6 Caso6: anon tiene acceso a reservaciones';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.reservation_conflicts where resource_id = v_house::uuid;
  delete from public.resource_reservations where resource_id = v_house::uuid;
  delete from public.resource_rights where resource_id = v_house::uuid;
  delete from public.resources where id = v_house::uuid;
  delete from public.context_invites where context_actor_id = v_ctx::uuid;
  delete from public.role_assignments where context_actor_id = v_ctx::uuid;
  delete from public.role_permissions rp using public.roles r where r.id = rp.role_id and r.context_actor_id = v_ctx::uuid;
  delete from public.roles where context_actor_id = v_ctx::uuid;
  delete from public.actor_memberships where context_actor_id = v_ctx::uuid;
  delete from public.actors where id = v_ctx::uuid;
  delete from public.person_profiles where actor_id in (v_a, v_b);
  delete from public.actors where id in (v_a, v_b);
  delete from auth.users where id in (v_auth_a, v_auth_b);

  raise notice '_smoke_mvp2_m6_reservations passed (6 casos, rights-based)';
end; $function$;

-- ── r2f: anon-check apunta a la firma 8-arg vigente
CREATE OR REPLACE FUNCTION public._smoke_r2f_reservations_dod()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  u_abuelo uuid; a_abuelo uuid;
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  u_isaac uuid; a_isaac uuid;
  u_moises uuid; a_moises uuid;
  u_out uuid; a_out uuid;
  v_ctx uuid; v_casa uuid; v_code text;
  v_result jsonb;
  v_res_david uuid; v_res_isaac uuid; v_res_david2 uuid;
  v_conflict public.reservation_conflicts%rowtype;
  v_starts timestamptz := '2026-07-10 16:00-06'::timestamptz;  -- viernes 4pm MX
  v_ends timestamptz := '2026-07-12 18:00-06'::timestamptz;    -- domingo 6pm MX
  v_caught boolean;
  v_fn text;
begin
  -- ═══ Setup: Familia Mizrahi + Casa Valle + rights + historial ═══
  select auth_id, actor_id into u_abuelo, a_abuelo from public._r2_make_person('Abuelo R2F', '+5210000060');
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2F', '+5210000061');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2F', '+5210000062');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2F', '+5210000063');
  select auth_id, actor_id into u_moises, a_moises from public._r2_make_person('Moisés R2F', '+5210000064');
  select auth_id, actor_id into u_out, a_out from public._r2_make_person('Outsider R2F', '+5210000065');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_ctx := (public.create_context('Familia Mizrahi', 'collective', 'family'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Casa Valle: Abuelo OWN 100% + Familia GOVERN + David USE + Isaac USE + Moisés VIEW
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_casa := (public.create_resource(a_abuelo, 'house', 'Casa Valle',
    p_estimated_value := 8000000, p_currency := 'MXN'))->>'resource_id';
  perform public.grant_right(v_casa::uuid, v_ctx::uuid, 'GOVERN');
  perform public.grant_right(v_casa::uuid, a_david, 'USE');
  perform public.grant_right(v_casa::uuid, a_isaac, 'USE');
  perform public.grant_right(v_casa::uuid, a_moises, 'VIEW');

  -- Historial: David con 2 reservaciones completed en los últimos 90 días, Isaac con 0
  insert into public.resource_reservations
    (resource_id, context_actor_id, requested_by_actor_id, reserved_for_actor_id, starts_at, ends_at, status)
  values
    (v_casa::uuid, v_ctx::uuid, a_david, a_david, now() - interval '60 days', now() - interval '58 days', 'completed'),
    (v_casa::uuid, v_ctx::uuid, a_david, a_david, now() - interval '30 days', now() - interval '28 days', 'completed');

  -- ═══ 1. David solicita Casa Valle (vie 2026-07-10 16:00 → dom 2026-07-12 18:00) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.request_resource_reservation(v_casa::uuid, v_ctx::uuid, v_starts, v_ends,
    p_client_id := 'r2f-david-jul10');
  v_res_david := (v_result->>'reservation_id')::uuid;
  if (v_result->'reservation'->>'status') <> 'requested' then
    raise exception 'R2F FAIL 1: solicitud de David no quedó requested';
  end if;
  -- priority_score de David = 2 (sus 2 usos recientes)
  if (v_result->'reservation'->>'priority_score')::numeric <> 2 then
    raise exception 'R2F FAIL 1: priority_score de David = % (esperaba 2)',
      v_result->'reservation'->>'priority_score';
  end if;

  -- Idempotencia: mismo client_id → misma reservation
  if (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid, v_starts, v_ends,
        p_client_id := 'r2f-david-jul10')->>'reservation_id')::uuid is distinct from v_res_david then
    raise exception 'R2F FAIL idempotencia: client_id repetido devolvió otra reservation';
  end if;

  -- ═══ 2. Isaac solicita el MISMO rango ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_result := public.request_resource_reservation(v_casa::uuid, v_ctx::uuid, v_starts, v_ends);
  v_res_isaac := (v_result->>'reservation_id')::uuid;
  -- priority_score de Isaac = 0 (sin usos recientes)
  if (v_result->'reservation'->>'priority_score')::numeric <> 0 then
    raise exception 'R2F FAIL 2: priority_score de Isaac = % (esperaba 0)',
      v_result->'reservation'->>'priority_score';
  end if;
  -- ═══ 3-4. Conflicto detectado ═══
  if (v_result->>'conflicts_detected')::integer < 1 then
    raise exception 'R2F FAIL 3: overlap no detectado';
  end if;

  select * into v_conflict from public.reservation_conflicts
   where resource_id = v_casa::uuid and resolution_status = 'open';
  if v_conflict.id is null then raise exception 'R2F FAIL 4: conflict row no existe'; end if;

  -- Idempotencia: detect repetido no duplica conflictos
  perform public.detect_reservation_conflicts(v_casa::uuid);
  if (select count(*) from public.reservation_conflicts where resource_id = v_casa::uuid) <> 1 then
    raise exception 'R2F FAIL idempotencia: detect duplicó conflictos';
  end if;

  -- ═══ 5-6. least_recent_use_wins → recommended_winner = Isaac ═══
  if v_conflict.recommended_winner_actor_id is distinct from a_isaac then
    raise exception 'R2F FAIL 6: recommended_winner debió ser Isaac (menor uso reciente)';
  end if;
  if v_conflict.metadata->>'priority_rule' <> 'least_recent_use_wins' then
    raise exception 'R2F FAIL 6: priority_rule no registrada en el conflicto';
  end if;

  -- ═══ Permiso: David (USE, no manager) NO puede resolver el conflicto ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_caught := false;
  begin
    perform public.resolve_reservation_conflict(v_conflict.id, v_res_david);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2F FAIL permisos: David (USE) resolvió el conflicto'; end if;

  -- ═══ 7-9. Abuelo (OWN + admin) resuelve a favor de Isaac ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_result := public.resolve_reservation_conflict(v_conflict.id, v_res_isaac);
  if (select status from public.resource_reservations where id = v_res_isaac) <> 'approved' then
    raise exception 'R2F FAIL 8: Isaac no quedó approved';
  end if;
  if (select status from public.resource_reservations where id = v_res_david) <> 'rejected' then
    raise exception 'R2F FAIL 9: David no quedó rejected';
  end if;

  -- Idempotencia: resolve repetido es no-op seguro
  v_result := public.resolve_reservation_conflict(v_conflict.id, v_res_isaac);
  if not coalesce((v_result->>'no_op')::boolean, false) then
    raise exception 'R2F FAIL idempotencia: resolve repetido no fue no-op';
  end if;

  -- ═══ 10. Isaac confirma su reservación ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_result := public.confirm_reservation(v_res_isaac);
  if v_result->>'status' <> 'confirmed' then
    raise exception 'R2F FAIL 10: Isaac no pudo confirmar';
  end if;
  -- Idempotencia: confirm repetido es no-op seguro
  v_result := public.confirm_reservation(v_res_isaac);
  if not coalesce((v_result->>'already_confirmed')::boolean, false) then
    raise exception 'R2F FAIL idempotencia: confirm repetido no fue no-op';
  end if;

  -- ═══ 11. Aprobar a David después debe fallar ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  -- (a) su reservación original (rejected) → no-op, NO pasa a approved
  v_result := public.approve_reservation(v_res_david);
  if not coalesce((v_result->>'no_op')::boolean, false)
     or (select status from public.resource_reservations where id = v_res_david) <> 'rejected' then
    raise exception 'R2F FAIL 11a: la reservación rejected de David cambió de status';
  end if;
  -- (b) una nueva solicitud de David para el mismo rango → aprobar explota por EXCLUDE
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_res_david2 := (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid, v_starts, v_ends))->>'reservation_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_caught := false;
  begin
    perform public.approve_reservation(v_res_david2::uuid);
  exception when exclusion_violation then v_caught := true;
  end;
  if not v_caught then
    raise exception 'R2F FAIL 11b: se aprobó una reservación traslapada con la confirmada de Isaac';
  end if;

  -- ═══ Resultados esperados ═══
  -- Isaac confirmed, David rejected, 1 conflicto resuelto con recomendación Isaac
  if (select status from public.resource_reservations where id = v_res_isaac) <> 'confirmed' then
    raise exception 'R2F FAIL resultado: Isaac no quedó confirmed';
  end if;
  if (select status from public.resource_reservations where id = v_res_david) <> 'rejected' then
    raise exception 'R2F FAIL resultado: David no quedó rejected';
  end if;
  -- (la nueva solicitud de David en 11b genera su propio conflicto abierto con Isaac;
  --  el conflicto ORIGINAL David-Isaac debe ser exactamente 1 y estar resuelto)
  if (select count(*) from public.reservation_conflicts
      where resource_id = v_casa::uuid
        and reservation_a_id in (v_res_david, v_res_isaac)
        and reservation_b_id in (v_res_david, v_res_isaac)) <> 1 then
    raise exception 'R2F FAIL resultado: debe haber exactamente 1 conflicto entre las solicitudes originales';
  end if;
  if (select resolution_status from public.reservation_conflicts
      where resource_id = v_casa::uuid
        and reservation_a_id in (v_res_david, v_res_isaac)
        and reservation_b_id in (v_res_david, v_res_isaac)) <> 'resolved' then
    raise exception 'R2F FAIL resultado: el conflicto original no quedó resuelto';
  end if;
  -- No existen dos reservaciones approved/confirmed traslapadas
  if exists (
    select 1 from public.resource_reservations a
    join public.resource_reservations b
      on b.resource_id = a.resource_id and b.id > a.id
     and tstzrange(a.starts_at, a.ends_at) && tstzrange(b.starts_at, b.ends_at)
    where a.resource_id = v_casa::uuid
      and a.status in ('approved', 'confirmed')
      and b.status in ('approved', 'confirmed')
  ) then
    raise exception 'R2F FAIL resultado: existen reservaciones approved/confirmed traslapadas';
  end if;

  -- ═══ 12. Moisés (VIEW, sin USE) no puede solicitar reserva ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  v_caught := false;
  begin
    perform public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
      v_starts + interval '7 days', v_ends + interval '7 days');
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2F FAIL 12: Moisés (solo VIEW) pudo reservar'; end if;

  -- José (miembro sin ningún right) tampoco puede
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_caught := false;
  begin
    perform public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
      v_starts + interval '7 days', v_ends + interval '7 days');
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2F FAIL 12: José (sin rights) pudo reservar'; end if;

  -- ═══ 13. No-miembro no puede solicitar reserva ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_caught := false;
  begin
    perform public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
      v_starts + interval '14 days', v_ends + interval '14 days');
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2F FAIL 13: no-miembro pudo reservar'; end if;

  -- ═══ Recurso archived no se puede reservar ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  perform public.archive_resource(v_casa::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_caught := false;
  begin
    perform public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
      v_starts + interval '21 days', v_ends + interval '21 days');
  exception when no_data_found then v_caught := true;
  end;
  if not v_caught then raise exception 'R2F FAIL: se pudo reservar un recurso archivado'; end if;

  -- ═══ 14. Anon bloqueado ═══
  foreach v_fn in array array[
    'public.request_resource_reservation(uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text, uuid)',
    'public.approve_reservation(uuid)',
    'public.resolve_reservation_conflict(uuid, uuid)',
    'public.confirm_reservation(uuid)',
    'public.detect_reservation_conflicts(uuid)'
  ] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') then
      raise exception 'R2F FAIL 14: anon puede ejecutar %', v_fn;
    end if;
  end loop;

  -- ═══ Cleanup ═══
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_abuelo, a_jose, a_david, a_isaac, a_moises, a_out],
    array[u_abuelo, u_jose, u_david, u_isaac, u_moises, u_out]);

  raise notice 'R.2F RESERVATIONS DoD: PASS (conflicto, least_recent_use_wins, Isaac confirmed, David rejected, permisos rights-based)';
end; $function$;

-- ── r2d: anon-check apunta a la firma 16-arg vigente (r5v3a)
CREATE OR REPLACE FUNCTION public._smoke_r2d_events_dod()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
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
    p_location_text := 'Por definir', p_starts_at := v_starts, p_ends_at := v_ends,
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
        p_location_text := 'Por definir', p_starts_at := v_starts, p_client_id := 'r2d-cena-miercoles')->>'event_id')::uuid
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
    'public.create_calendar_event(uuid, text, text, timestamptz, timestamptz, text, text, text, text, uuid, boolean, jsonb, text, boolean, integer, timestamptz)',
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
end; $function$;

-- ── r2g: anon-check apunta a la firma 9-arg vigente (r7_h_1)
CREATE OR REPLACE FUNCTION public._smoke_r2g_decisions_dod()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  u_abuelo uuid; a_abuelo uuid;
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  u_isaac uuid; a_isaac uuid;
  u_moises uuid; a_moises uuid;
  u_daniel uuid; a_daniel uuid;
  u_out uuid; a_out uuid;
  v_ctx uuid; v_casa uuid; v_code text;
  v_res_david uuid; v_res_isaac uuid;
  v_conflict_id uuid;
  v_decision uuid; v_decision2 uuid;
  v_result jsonb;
  v_starts timestamptz := '2026-07-10 16:00-06'::timestamptz;
  v_ends timestamptz := '2026-07-12 18:00-06'::timestamptz;
  v_caught boolean;
  v_fn text;
begin
  select auth_id, actor_id into u_abuelo, a_abuelo from public._r2_make_person('Abuelo R2G', '+5210000070');
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2G', '+5210000071');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2G', '+5210000072');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2G', '+5210000073');
  select auth_id, actor_id into u_moises, a_moises from public._r2_make_person('Moisés R2G', '+5210000074');
  select auth_id, actor_id into u_daniel, a_daniel from public._r2_make_person('Daniel R2G', '+5210000075');
  select auth_id, actor_id into u_out, a_out from public._r2_make_person('Outsider R2G', '+5210000076');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_ctx := (public.create_context('Familia Mizrahi', 'collective', 'family'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
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

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_casa := (public.create_resource(a_abuelo, 'house', 'Casa Valle'))->>'resource_id';
  perform public.grant_right(v_casa::uuid, v_ctx::uuid, 'GOVERN');
  perform public.grant_right(v_casa::uuid, a_david, 'USE');
  perform public.grant_right(v_casa::uuid, a_isaac, 'USE');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_res_david := (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid, v_starts, v_ends))->>'reservation_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_res_isaac := (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid, v_starts, v_ends))->>'reservation_id';

  select id into v_conflict_id from public.reservation_conflicts
   where resource_id = v_casa::uuid and resolution_status = 'open';
  if v_conflict_id is null then raise exception 'R2G FAIL setup: no existe el conflicto de R.2F'; end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_decision := (public.create_decision(v_ctx::uuid, 'reservation_dispute',
    '¿Quién debe recibir Casa Valle del 10 al 12 de julio?',
    p_payload := jsonb_build_object(
      'resolution_mode', 'community_vote',
      'reservation_conflict_id', v_conflict_id,
      'resource_id', v_casa,
      'reservation_a_id', v_res_david,
      'reservation_b_id', v_res_isaac,
      'options', jsonb_build_array('David', 'Isaac'),
      'option_reservations', jsonb_build_object('David', v_res_david, 'Isaac', v_res_isaac))
    ))->>'decision_id';
  if v_decision is null then raise exception 'R2G FAIL 1: decisión no creada'; end if;
  if (select status from public.decisions where id = v_decision::uuid) <> 'open' then
    raise exception 'R2G FAIL 2: la votación no quedó abierta';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.vote_decision(v_decision::uuid, 'approve', 'David');
  perform public.vote_decision(v_decision::uuid, 'approve', 'David');
  if (select count(*) from public.decision_votes where decision_id = v_decision::uuid) <> 1 then
    raise exception 'R2G FAIL idempotencia: votar dos veces creó dos votos';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.vote_decision(v_decision::uuid, 'approve', 'David');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.vote_decision(v_decision::uuid, 'approve', 'Isaac');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  perform public.vote_decision(v_decision::uuid, 'abstain');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_result := public.vote_decision(v_decision::uuid, 'approve', 'Isaac');
  if v_result->>'status' <> 'open' then
    raise exception 'R2G FAIL 7: la decisión cerró antes de que todos votaran (%)', v_result->>'status';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.vote_decision(v_decision::uuid, 'approve', 'David');
  if v_result->>'status' <> 'approved' then
    raise exception 'R2G FAIL 8: la decisión no cerró al votar todos (%)', v_result->>'status';
  end if;

  if (select (result->'option_tally'->>'David')::numeric from public.decisions where id = v_decision::uuid) <> 3 then
    raise exception 'R2G FAIL resultado: David debió tener 3 votos';
  end if;
  if (select (result->'option_tally'->>'Isaac')::numeric from public.decisions where id = v_decision::uuid) <> 2 then
    raise exception 'R2G FAIL resultado: Isaac debió tener 2 votos';
  end if;
  if (select result->>'winning_option' from public.decisions where id = v_decision::uuid) <> 'David' then
    raise exception 'R2G FAIL resultado: el ganador debió ser David';
  end if;
  if not exists (select 1 from public.decision_votes
                 where decision_id = v_decision::uuid and voter_actor_id = a_abuelo and vote = 'abstain') then
    raise exception 'R2G FAIL resultado: la abstención del Abuelo no quedó registrada';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_result := public.close_decision(v_decision::uuid);
  if not coalesce((v_result->>'already_closed')::boolean, false) then
    raise exception 'R2G FAIL 9: close sobre decisión cerrada no fue no-op';
  end if;
  v_result := public.close_decision(v_decision::uuid);
  if not coalesce((v_result->>'already_closed')::boolean, false) then
    raise exception 'R2G FAIL idempotencia: close repetido no fue no-op';
  end if;

  v_result := public.execute_decision(v_decision::uuid);
  if v_result->>'status' <> 'executed' then
    raise exception 'R2G FAIL 10: execute falló';
  end if;

  if (select resolution_status from public.reservation_conflicts where id = v_conflict_id) <> 'resolved' then
    raise exception 'R2G FAIL consecuencias: el conflicto no quedó resolved';
  end if;
  if (select source_decision_id from public.reservation_conflicts where id = v_conflict_id) is distinct from v_decision::uuid then
    raise exception 'R2G FAIL consecuencias: el conflicto no apunta a la decisión (provenance)';
  end if;
  if (select status from public.resource_reservations where id = v_res_david::uuid) <> 'approved' then
    raise exception 'R2G FAIL consecuencias: la reservación de David no quedó approved';
  end if;
  if (select source_decision_id from public.resource_reservations where id = v_res_david::uuid) is distinct from v_decision::uuid then
    raise exception 'R2G FAIL consecuencias: la reservación de David sin provenance de la decisión';
  end if;
  if (select status from public.resource_reservations where id = v_res_isaac::uuid) <> 'rejected' then
    raise exception 'R2G FAIL consecuencias: la reservación de Isaac no quedó rejected';
  end if;

  v_result := public.execute_decision(v_decision::uuid);
  if not coalesce((v_result->>'already_executed')::boolean, false) then
    raise exception 'R2G FAIL idempotencia: execute repetido no fue no-op';
  end if;
  if (select status from public.resource_reservations where id = v_res_david::uuid) <> 'approved'
     or (select status from public.resource_reservations where id = v_res_isaac::uuid) <> 'rejected'
     or (select resolution_status from public.reservation_conflicts where id = v_conflict_id) <> 'resolved' then
    raise exception 'R2G FAIL idempotencia: execute repetido alteró los efectos';
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'reservation.approved'
        and subject_id = v_res_david::uuid) <> 1 then
    raise exception 'R2G FAIL idempotencia: reservation.approved duplicada';
  end if;

  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'decision.created'
        and subject_id = v_decision::uuid) <> 1 then
    raise exception 'R2G FAIL activity: decision.created debe ser 1';
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'decision.vote_cast'
        and (payload->>'decision_id')::uuid = v_decision::uuid) <> 7 then
    raise exception 'R2G FAIL activity: decision.vote_cast debe ser 7 (6 votos + 1 actualización)';
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'decision.closed'
        and subject_id = v_decision::uuid) <> 1 then
    raise exception 'R2G FAIL activity: decision.closed debe ser 1';
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'decision.executed'
        and subject_id = v_decision::uuid) <> 1 then
    raise exception 'R2G FAIL activity: decision.executed debe ser 1';
  end if;
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'reservation.rejected'
        and subject_id = v_res_isaac::uuid) <> 1 then
    raise exception 'R2G FAIL activity: reservation.rejected debe ser 1';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_decision2 := (public.create_decision(v_ctx::uuid, 'generic', 'R2G decisión de permisos',
    p_payload := jsonb_build_object('options', jsonb_build_array('David', 'Isaac'))))->>'decision_id';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_caught := false;
  begin
    perform public.vote_decision(v_decision2::uuid, 'approve', 'David');
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2G FAIL permisos: no-miembro pudo votar'; end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  perform public.remove_member(v_ctx::uuid, a_daniel, 'prueba R2G');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  v_caught := false;
  begin
    perform public.vote_decision(v_decision2::uuid, 'approve', 'David');
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2G FAIL permisos: miembro removido pudo votar'; end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.vote_decision(v_decision2::uuid, 'approve', 'David');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_result := public.close_decision(v_decision2::uuid);
  if v_result->>'status' <> 'approved' or v_result->>'winning_option' <> 'David' then
    raise exception 'R2G FAIL close: cierre explícito no determinó al ganador (% / %)',
      v_result->>'status', v_result->>'winning_option';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_caught := false;
  begin
    perform public.close_decision(v_decision2::uuid);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2G FAIL permisos: member pudo cerrar decisión'; end if;

  foreach v_fn in array array[
    'public.create_decision(uuid, text, text, text, timestamptz, jsonb, text, text, text)',
    'public.vote_decision(uuid, text, text)',
    'public.close_decision(uuid)',
    'public.execute_decision(uuid, jsonb)'
  ] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') then
      raise exception 'R2G FAIL permisos: anon puede ejecutar %', v_fn;
    end if;
  end loop;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_abuelo, a_jose, a_david, a_isaac, a_moises, a_daniel, a_out],
    array[u_abuelo, u_jose, u_david, u_isaac, u_moises, u_daniel, u_out]);

  raise notice 'R.2G DECISIONS DoD (post-R.2Q): PASS';
end; $function$;

-- ── m9: Caso5 con handshake debtor-claim + creditor-confirm (r5z 20260610220000)
CREATE OR REPLACE FUNCTION public._smoke_mvp2_m9_money()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_auth_c uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_c uuid; v_ctx uuid;
  v_result jsonb; v_code text; v_batch uuid; v_item uuid;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke M9A', '+520000000019', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke M9B', '+520000000020', null);
  v_c := public._create_person_actor_for_auth_user(v_auth_c, 'Smoke M9C', '+520000000021', null);

  -- Setup: contexto con 3 miembros
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_ctx := (public.create_context('_smoke_m9 Cena', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Caso 1: A paga $900 de cena, split entre 3 → B y C deben $300 c/u a A
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.record_expense(v_ctx::uuid, 900, 'MXN', '_smoke_m9 Cena sushi');
  if (v_result->>'share_per_person')::numeric <> 300 then
    raise exception 'mvp2_m9 Caso1: split incorrecto (%)', v_result->>'share_per_person';
  end if;
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and obligation_type = 'expense_share'
        and creditor_actor_id = v_a and amount = 300) <> 2 then
    raise exception 'mvp2_m9 Caso1: obligations de split incorrectas';
  end if;

  -- Caso 2: B registra resultado de juego — B ganó 200, C perdió 200
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_result := public.record_game_result(v_ctx::uuid,
    jsonb_build_array(
      jsonb_build_object('actor_id', v_b, 'amount', 200),
      jsonb_build_object('actor_id', v_c, 'amount', -200)));
  if jsonb_array_length(v_result->'obligations') <> 1 then
    raise exception 'mvp2_m9 Caso2: game_debt no creada';
  end if;

  -- Caso 3: generate_settlement_batch (admin) — neteo greedy
  -- Estado: B debe 300 a A; C debe 300 a A + 200 a B
  -- Neto: A +600, B -100 (debe 300, le deben 200), C -500
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.generate_settlement_batch(v_ctx::uuid, 'MXN');
  v_batch := (v_result->>'batch_id')::uuid;
  if v_batch is null then raise exception 'mvp2_m9 Caso3: batch no generado'; end if;
  -- el neteo correcto: C paga 500 (a A), B paga 100 (a A) — exactamente 2 transferencias
  if jsonb_array_length(v_result->'items') <> 2 then
    raise exception 'mvp2_m9 Caso3: settlement no optimizado (% items)', jsonb_array_length(v_result->'items');
  end if;
  -- total a recibir por A = 600
  if (select sum((i->>'amount')::numeric) from jsonb_array_elements(v_result->'items') i
      where (i->>'to')::uuid = v_a) <> 600 then
    raise exception 'mvp2_m9 Caso3: neteo incorrecto para A';
  end if;

  -- Caso 4: member sin money.settle NO puede generar batch
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  declare v_caught boolean := false;
  begin
    begin
      perform public.generate_settlement_batch(v_ctx::uuid, 'MXN');
    exception when insufficient_privilege then v_caught := true;
    end;
    if not v_caught then raise exception 'mvp2_m9 Caso4: member genero batch sin autoridad'; end if;
  end;

  -- Caso 5: mark_settlement_paid por el deudor → transaction + obligations cerradas
  select id into v_item from public.settlement_items
   where settlement_batch_id = v_batch and from_actor_id = v_c limit 1;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
  v_result := public.mark_settlement_paid(v_item);
  -- R.5Z handshake (20260610220000): el deudor solo CLAIMA el pago
  if v_result->>'status' is distinct from 'pending_confirmation' then
    raise exception 'mvp2_m9 Caso5: el claim del deudor no quedó pending_confirmation (%)', v_result;
  end if;
  -- el acreedor confirma → ahí se crea la transaction
  perform set_config('request.jwt.claims', jsonb_build_object('sub',
    (select pp.auth_user_id from public.person_profiles pp
      where pp.actor_id = (select to_actor_id from public.settlement_items where id = v_item))::text)::text, true);
  v_result := public.confirm_settlement_paid(v_item);
  if (v_result->>'transaction_id') is null then
    raise exception 'mvp2_m9 Caso5: settlement payment no creó transaction';
  end if;
  -- idempotente
  v_result := public.mark_settlement_paid(v_item);
  if not (v_result->>'already_paid')::boolean then
    raise exception 'mvp2_m9 Caso5: mark_settlement_paid no es idempotente';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.settlement_items where settlement_batch_id in
    (select id from public.settlement_batches where context_actor_id = v_ctx::uuid);
  delete from public.settlement_batches where context_actor_id = v_ctx::uuid;
  delete from public.money_splits where transaction_id in
    (select id from public.money_transactions where context_actor_id = v_ctx::uuid);
  delete from public.money_transactions where context_actor_id = v_ctx::uuid;
  delete from public.obligations where context_actor_id = v_ctx::uuid;
  delete from public.context_invites where context_actor_id = v_ctx::uuid;
  delete from public.role_assignments where context_actor_id = v_ctx::uuid;
  delete from public.role_permissions rp using public.roles r where r.id = rp.role_id and r.context_actor_id = v_ctx::uuid;
  delete from public.roles where context_actor_id = v_ctx::uuid;
  delete from public.actor_memberships where context_actor_id = v_ctx::uuid;
  delete from public.actors where id = v_ctx::uuid;
  delete from public.person_profiles where actor_id in (v_a, v_b, v_c);
  delete from public.actors where id in (v_a, v_b, v_c);
  delete from auth.users where id in (v_auth_a, v_auth_b, v_auth_c);

  raise notice '_smoke_mvp2_m9_money passed (5 casos)';
end; $function$;

-- ── r2n: handshake debtor-claim + creditor-confirm en pasos 4/5
CREATE OR REPLACE FUNCTION public._smoke_r2n_live_settlement()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  u_ana uuid := gen_random_uuid(); u_beto uuid := gen_random_uuid(); u_cata uuid := gen_random_uuid();
  a_ana uuid; a_beto uuid; a_cata uuid;
  v_ctx uuid; v_code text; v_batch uuid; v_result jsonb;
  v_item record;
  v_balance_ana numeric;
  r record;
begin
  -- Personas (vía trigger real de auth)
  for r in select * from (values ('Ana R2N', u_ana), ('Beto R2N', u_beto), ('Cata R2N', u_cata)) t(who, uid) loop
    insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (r.uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            lower(split_part(r.who, ' ', 1)) || '.' || substr(r.uid::text, 1, 8) || '@r2n.test',
            '{"provider": "email", "providers": ["email"]}'::jsonb,
            jsonb_build_object('full_name', r.who), now(), now());
  end loop;
  select actor_id into a_ana from public.person_profiles where auth_user_id = u_ana;
  select actor_id into a_beto from public.person_profiles where auth_user_id = u_beto;
  select actor_id into a_cata from public.person_profiles where auth_user_id = u_cata;

  -- Contexto: Ana founder + Beto y Cata
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_ana::text)::text, true);
  v_ctx := ((public.create_context('Roomies R2N', 'collective', 'friend_group'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_beto::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_cata::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- ═══ 1. Gasto inicial: Ana pagó 300, split 3 → Beto y Cata deben 100 c/u ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_ana::text)::text, true);
  perform public.record_expense(v_ctx, 300, 'MXN', 'Súper',
    p_split_with := array[a_ana, a_beto, a_cata], p_client_id := 'r2n-super');

  -- ═══ 2. Generar el batch → NOVACIÓN ═══
  v_result := public.generate_settlement_batch(v_ctx, 'MXN');
  v_batch := (v_result->>'batch_id')::uuid;
  if v_batch is null then raise exception 'R2N FAIL: batch no generado'; end if;

  -- Las originales quedaron novadas (settled) y existen ious abiertos 1:1 con items
  if exists (select 1 from public.obligations
              where context_actor_id = v_ctx and obligation_type = 'expense_share' and status = 'open') then
    raise exception 'R2N FAIL: las obligations origen no se novaron al generar el batch';
  end if;
  if (select count(*) from public.obligations
       where context_actor_id = v_ctx and obligation_type = 'iou' and status = 'open') <> 2 then
    raise exception 'R2N FAIL: esperaba 2 ious abiertos tras la novación';
  end if;
  if (select count(*) from public.settlement_items
       where settlement_batch_id = v_batch and status = 'pending') <> 2 then
    raise exception 'R2N FAIL: esperaba 2 items pendientes';
  end if;
  -- El balance de Ana (suma de ious a su favor) sigue siendo 200
  select coalesce(sum(amount), 0) into v_balance_ana from public.obligations
   where context_actor_id = v_ctx and status = 'open' and creditor_actor_id = a_ana;
  if v_balance_ana <> 200 then
    raise exception 'R2N FAIL: balance de Ana tras novación debió ser 200, fue %', v_balance_ana;
  end if;

  -- ═══ 3. NUEVO gasto con el batch vivo → el trigger recalcula solo ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_beto::text)::text, true);
  perform public.record_expense(v_ctx, 60, 'MXN', 'Cafés',
    p_split_with := array[a_ana, a_beto, a_cata], p_client_id := 'r2n-cafes');

  -- Sin llamar a generate: los items pendientes deben reflejar los netos nuevos
  -- Netos: Ana +200-20=+180 · Beto -100+40=-60 · Cata -100-20=-120
  if (select coalesce(sum(amount), 0) from public.settlement_items
       where settlement_batch_id = v_batch and status = 'pending') <> 180 then
    raise exception 'R2N FAIL: el trigger no recalculó el neteo (pendiente: %)',
      (select coalesce(sum(amount), 0) from public.settlement_items
        where settlement_batch_id = v_batch and status = 'pending');
  end if;
  if (select coalesce(sum(amount), 0) from public.settlement_items
       where settlement_batch_id = v_batch and status = 'pending' and from_actor_id = a_cata) <> 120 then
    raise exception 'R2N FAIL: el neto de Cata debió ser 120';
  end if;

  -- ═══ 4. Pago parcial → el balance baja AL INSTANTE ═══
  select * into v_item from public.settlement_items
   where settlement_batch_id = v_batch and status = 'pending' and from_actor_id = a_cata limit 1;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_cata::text)::text, true);
  v_result := public.mark_settlement_paid(v_item.id);
  -- R.5Z handshake: el acreedor confirma la recepción → se aplican los side effects
  perform set_config('request.jwt.claims', jsonb_build_object('sub',
    (select pp.auth_user_id from public.person_profiles pp
      where pp.actor_id = v_item.to_actor_id)::text)::text, true);
  v_result := public.confirm_settlement_paid(v_item.id);

  -- El iou de Cata quedó cerrado → su deuda abierta es 0
  if (select coalesce(sum(amount), 0) from public.obligations
       where context_actor_id = v_ctx and status = 'open' and debtor_actor_id = a_cata) <> 0 then
    raise exception 'R2N FAIL: el pago de Cata no cerró su iou en tiempo real';
  end if;
  -- Y el balance global abierto del contexto bajó a 60 (solo Beto debe)
  if (select coalesce(sum(amount), 0) from public.obligations
       where context_actor_id = v_ctx and status = 'open') <> 60 then
    raise exception 'R2N FAIL: tras el pago de Cata deberían quedar 60 abiertos';
  end if;

  -- Idempotencia del pago (se conserva de R.2I; item paid → already_paid)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_cata::text)::text, true);
  v_result := public.mark_settlement_paid(v_item.id);
  if not coalesce((v_result->>'already_paid')::boolean, false) then
    raise exception 'R2N FAIL: mark_settlement_paid no es idempotente';
  end if;

  -- ═══ 5. Último pago → batch finalized + cero deudas abiertas ═══
  select * into v_item from public.settlement_items
   where settlement_batch_id = v_batch and status = 'pending' limit 1;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_beto::text)::text, true);
  v_result := public.mark_settlement_paid(v_item.id);
  -- R.5Z handshake: la finalización del batch la reporta la confirmación del acreedor
  perform set_config('request.jwt.claims', jsonb_build_object('sub',
    (select pp.auth_user_id from public.person_profiles pp
      where pp.actor_id = v_item.to_actor_id)::text)::text, true);
  v_result := public.confirm_settlement_paid(v_item.id);
  if not coalesce((v_result->>'batch_finalized')::boolean, false) then
    raise exception 'R2N FAIL: el último pago no finalizó el batch';
  end if;
  if exists (select 1 from public.obligations where context_actor_id = v_ctx and status = 'open') then
    raise exception 'R2N FAIL: quedaron deudas abiertas tras pagar todo';
  end if;
  if (select status from public.settlement_batches where id = v_batch) <> 'finalized' then
    raise exception 'R2N FAIL: el batch no quedó finalized';
  end if;

  -- ═══ 6. Gasto posterior SIN batch draft → el trigger no crea batches solos ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_ana::text)::text, true);
  perform public.record_expense(v_ctx, 90, 'MXN', 'Tacos',
    p_split_with := array[a_ana, a_beto, a_cata], p_client_id := 'r2n-tacos');
  if exists (select 1 from public.settlement_batches
              where context_actor_id = v_ctx and status = 'draft') then
    raise exception 'R2N FAIL: el trigger creó un batch sin que nadie lo pidiera';
  end if;
  -- y las deudas nuevas siguen abiertas como expense_share normales
  if (select count(*) from public.obligations
       where context_actor_id = v_ctx and status = 'open' and obligation_type = 'expense_share') <> 2 then
    raise exception 'R2N FAIL: las deudas post-settlement no quedaron abiertas normales';
  end if;

  -- ═══ Cleanup ═══
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx, array[a_ana, a_beto, a_cata], array[u_ana, u_beto, u_cata]);

  raise notice 'R.2N LIVE SETTLEMENT: PASS — novación, recálculo automático por trigger, balance en tiempo real y finalización correcta.';
end; $function$;

-- ── viaje: handshake en el loop de pagos
CREATE OR REPLACE FUNCTION public._smoke_r2_viaje()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  a_jose uuid; a_david uuid; a_isaac uuid;
  u_jose uuid; u_david uuid; u_isaac uuid;
  v_ctx uuid; v_result jsonb; v_batch uuid;
  r record;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José', '+5210000010');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David', '+5210000011');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac', '+5210000012');

  -- Contexto viaje (subtype trip)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Viaje Vegas 2026', 'collective', 'trip'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_david);
  perform public.invite_member(v_ctx::uuid, a_isaac);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);

  -- Recurso del viaje: hotel booking + evento
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.create_resource(v_ctx::uuid, 'trip_booking', 'Hotel Bellagio 3 noches');
  perform public.create_calendar_event(v_ctx::uuid, 'Viaje a Vegas', 'trip',
    p_location_text := 'Por definir', p_starts_at := now() + interval '30 days', p_ends_at := now() + interval '33 days');

  -- Gastos: José paga hotel $3000 (split 3), David paga cena $900 (split 3)
  v_result := public.record_expense(v_ctx::uuid, 3000, 'USD', 'Hotel');
  if (v_result->>'share_per_person')::numeric <> 1000 then
    raise exception 'VIAJE FAIL: split hotel incorrecto';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.record_expense(v_ctx::uuid, 900, 'USD', 'Cena');

  -- Settlement: neto José +1700, David -400, Isaac -1300 → 2 transferencias
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.generate_settlement_batch(v_ctx::uuid, 'USD');
  v_batch := (v_result->>'batch_id')::uuid;
  if jsonb_array_length(v_result->'items') <> 2 then
    raise exception 'VIAJE FAIL: settlement no optimizado (% items, esperaba 2)',
      jsonb_array_length(v_result->'items');
  end if;
  -- José debe recibir exactamente 1700
  if (select sum((i->>'amount')::numeric) from jsonb_array_elements(v_result->'items') i
      where (i->>'to')::uuid = a_jose) <> 1700 then
    raise exception 'VIAJE FAIL: neteo de José incorrecto';
  end if;

  -- Pagar todo
  for r in select id, from_actor_id from public.settlement_items where settlement_batch_id = v_batch loop
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', (select pp.auth_user_id from public.person_profiles pp where pp.actor_id = r.from_actor_id)::text)::text, true);
    perform public.mark_settlement_paid(r.id);
    -- R.5Z handshake (20260610220000): el acreedor confirma la recepción
    perform set_config('request.jwt.claims', jsonb_build_object('sub',
      (select pp.auth_user_id from public.person_profiles pp
        where pp.actor_id = (select to_actor_id from public.settlement_items where id = r.id))::text)::text, true);
    perform public.confirm_settlement_paid(r.id);
  end loop;

  if exists (select 1 from public.obligations where context_actor_id = v_ctx::uuid and status = 'open') then
    raise exception 'VIAJE FAIL: obligations abiertas post-settlement';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_jose, a_david, a_isaac], array[u_jose, u_david, u_isaac]);

  raise notice 'R.2 VIAJE: PASS';
end; $function$;

-- ── negocio: handshake en el loop de pagos
CREATE OR REPLACE FUNCTION public._smoke_r2_negocio_socios()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  a_jose uuid; a_marco uuid;
  u_jose uuid; u_marco uuid;
  v_ctx uuid; v_result jsonb; v_decision uuid; v_batch uuid;
  r record;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José', '+5210000013');
  select auth_id, actor_id into u_marco, a_marco from public._r2_make_person('Marco', '+5210000014');

  -- ═══ Contexto legal_entity (company) — ambos socios admin ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Quimibond SA', 'legal_entity', 'company'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_marco);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_marco::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  -- José (admin) da rol admin a Marco — socios en igualdad
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.assign_role(v_ctx::uuid, a_marco, 'admin');

  -- Marco ahora tiene autoridad de admin
  if not public.has_actor_authority(v_ctx::uuid, a_marco, 'money.settle') then
    raise exception 'NEGOCIO FAIL: Marco no tiene autoridad de admin';
  end if;

  -- ═══ Recursos del negocio: contrato + relación shareholder via rights ═══
  perform public.create_resource(v_ctx::uuid, 'contract', 'Contrato Cliente Pemex',
    p_estimated_value := 500000, p_currency := 'MXN');
  -- Equity: 50/50 registrado como rights OWN sobre el "cap table" (resource equity del negocio)
  declare v_equity uuid;
  begin
    v_equity := (public.create_resource(v_ctx::uuid, 'other', 'Capital Social Quimibond'))->>'resource_id';
    perform public.grant_right(v_equity::uuid, a_jose, 'OWN', 50);
    perform public.grant_right(v_equity::uuid, a_marco, 'OWN', 50);
    v_result := public.resource_detail(v_equity::uuid);
    if (select count(*) from jsonb_array_elements(v_result->'rights') rt
        where rt->>'right_kind' = 'OWN' and (rt->>'percent')::numeric = 50) <> 2 then
      raise exception 'NEGOCIO FAIL: equity 50/50 no registrada';
    end if;
  end;

  -- ═══ Decisión de negocio: compra de maquinaria (requiere ambos) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_marco::text)::text, true);
  v_decision := (public.create_decision(v_ctx::uuid, 'expense_approval',
    'Comprar reactor químico $250,000',
    p_payload := '{"amount": 250000, "currency": "MXN"}'::jsonb))->>'decision_id';
  perform public.vote_decision(v_decision::uuid, 'approve');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.vote_decision(v_decision::uuid, 'approve');
  if v_result->>'status' <> 'approved' then
    raise exception 'NEGOCIO FAIL: decisión no aprobada (%)', v_result->>'status';
  end if;
  perform public.execute_decision(v_decision::uuid, '{"po_number": "PO-2026-001"}'::jsonb);

  -- ═══ Money: Marco paga inventario $10,000 → José debe $5,000 ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_marco::text)::text, true);
  v_result := public.record_expense(v_ctx::uuid, 10000, 'MXN', 'Inventario materia prima');
  if (v_result->>'share_per_person')::numeric <> 5000 then
    raise exception 'NEGOCIO FAIL: split incorrecto';
  end if;

  -- Settlement entre socios
  v_result := public.generate_settlement_batch(v_ctx::uuid, 'MXN');
  v_batch := (v_result->>'batch_id')::uuid;
  if jsonb_array_length(v_result->'items') <> 1 then
    raise exception 'NEGOCIO FAIL: settlement debió ser 1 transferencia';
  end if;
  -- José paga sus 5000 a Marco
  for r in select id, from_actor_id from public.settlement_items where settlement_batch_id = v_batch loop
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', (select pp.auth_user_id from public.person_profiles pp where pp.actor_id = r.from_actor_id)::text)::text, true);
    perform public.mark_settlement_paid(r.id);
    -- R.5Z handshake (20260610220000): el acreedor confirma la recepción
    perform set_config('request.jwt.claims', jsonb_build_object('sub',
      (select pp.auth_user_id from public.person_profiles pp
        where pp.actor_id = (select to_actor_id from public.settlement_items where id = r.id))::text)::text, true);
    perform public.confirm_settlement_paid(r.id);
  end loop;

  if exists (select 1 from public.obligations where context_actor_id = v_ctx::uuid and status = 'open') then
    raise exception 'NEGOCIO FAIL: obligations abiertas post-settlement';
  end if;

  -- context_summary refleja el negocio completo
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.context_summary(v_ctx::uuid);
  if (v_result->>'members_count')::integer <> 2
     or (v_result->>'resources_count')::integer <> 2
     or (v_result->>'open_obligations')::integer <> 0 then
    raise exception 'NEGOCIO FAIL: summary incorrecto (members=%, resources=%, obligations=%)',
      v_result->>'members_count', v_result->>'resources_count', v_result->>'open_obligations';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_jose, a_marco], array[u_jose, u_marco]);

  raise notice 'R.2 NEGOCIO ENTRE SOCIOS: PASS';
end; $function$;

-- ── contract: regla con event_type (sin doble eval R.6.B) + handshake admin-confirm
CREATE OR REPLACE FUNCTION public._smoke_mvp2_contract()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_auth_linda uuid := gen_random_uuid();
  v_jose uuid; v_linda uuid; v_ctx uuid;
  v_result jsonb; v_code text; v_event uuid; v_next uuid;
  v_batch uuid; v_summary jsonb;
  v_total_closed integer := 0;
  r record;
begin
  -- ═══ 1-2. Identity + contexto ═══
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, 'Jose Contract', '+520000000022', null);
  v_linda := public._create_person_actor_for_auth_user(v_auth_linda, 'Linda Contract', '+520000000023', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_ctx := (public.create_context('_contract Cena de los Jueves', 'collective', 'friend_group'))->>'context_actor_id';

  -- ═══ 3. Linda se une ═══
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_linda::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- ═══ 4. Regla de multa ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  perform public.create_rule(v_ctx::uuid, '_contract Multa por tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": "and", "conditions": [
      {"op": "=", "field": "event_type", "value": "dinner"},
      {"op": ">", "field": "minutes_late", "value": 15}]}'::jsonb,
    p_consequences := '[{"type": "fine", "amount": 100, "currency": "MXN"}]'::jsonb);

  -- ═══ 5. Cena recurrente ═══
  v_event := (public.create_calendar_event(v_ctx::uuid, '_contract Cena Jueves', 'dinner',
    p_location_text := 'Por definir', p_starts_at := now() - interval '30 minutes',
    p_recurrence_rule := 'weekly', p_host_actor_id := v_jose))->>'event_id';

  -- ═══ 6. Linda check-in tarde → multa ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_linda::text)::text, true);
  v_result := public.check_in_participant(v_event::uuid);
  if (v_result->'rules'->>'rules_matched')::integer < 1 then
    raise exception 'contract: multa automática por tarde no se generó';
  end if;

  -- ═══ 7. Gasto con split ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_result := public.record_expense(v_ctx::uuid, 600, 'MXN', '_contract Cena sushi', p_event_id := v_event::uuid);
  if (v_result->>'share_per_person')::numeric <> 300 then
    raise exception 'contract: split de gasto incorrecto';
  end if;

  -- ═══ 8. Cierre + recurrencia + host rotation ═══
  v_result := public.close_event(v_event::uuid);
  v_next := (v_result->>'next_event_id')::uuid;
  if v_next is null or (v_result->>'next_host_actor_id')::uuid is distinct from v_linda then
    raise exception 'contract: recurrencia/rotación de host falló';
  end if;

  -- ═══ 9. Settlement ═══
  v_result := public.generate_settlement_batch(v_ctx::uuid, 'MXN');
  v_batch := (v_result->>'batch_id')::uuid;
  if v_batch is null then raise exception 'contract: settlement batch no generado'; end if;
  if (select sum((i->>'amount')::numeric) from jsonb_array_elements(v_result->'items') i
      where (i->>'from')::uuid = v_linda) <> 400 then
    raise exception 'contract: neteo de Linda incorrecto (esperaba 400)';
  end if;

  -- ═══ 10. Linda paga TODOS sus items (R.2-3: el batch cierra al completarse) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_linda::text)::text, true);
  for r in select id from public.settlement_items
            where settlement_batch_id = v_batch and from_actor_id = v_linda loop
    v_result := public.mark_settlement_paid(r.id);
    -- R.5Z handshake: José (acreedor/admin) confirma cada pago; los cierres
    -- los reporta la confirmación
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
    v_result := public.confirm_settlement_paid(r.id);
    v_total_closed := v_total_closed + coalesce((v_result->>'obligations_closed')::integer, 0);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_linda::text)::text, true);
  end loop;
  if v_total_closed < 2 then
    raise exception 'contract: obligations no cerradas al finalizar batch (cerradas: %)', v_total_closed;
  end if;
  if exists (select 1 from public.obligations where context_actor_id = v_ctx::uuid and status = 'open') then
    raise exception 'contract: quedaron obligations abiertas';
  end if;

  -- ═══ 11. context_summary refleja todo ═══
  v_summary := public.context_summary(v_ctx::uuid);
  if jsonb_array_length(v_summary->'members') <> 2 then
    raise exception 'contract: summary.members incorrecto';
  end if;
  if jsonb_array_length(v_summary->'upcoming_events') < 1 then
    raise exception 'contract: summary.upcoming_events no muestra la siguiente cena';
  end if;
  if jsonb_array_length(v_summary->'active_rules') <> 1 then
    raise exception 'contract: summary.active_rules incorrecto';
  end if;
  if (v_summary->>'open_obligations')::integer <> 0 then
    raise exception 'contract: summary.open_obligations debió ser 0';
  end if;

  -- ═══ 12. context_candidates ═══
  v_result := public.context_candidates();
  if not exists (select 1 from jsonb_array_elements(v_result->'contexts') c
                 where (c->>'context_actor_id')::uuid = v_ctx::uuid) then
    raise exception 'contract: context_candidates no muestra el contexto';
  end if;

  -- ═══ Cleanup ═══
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[v_jose, v_linda], array[v_auth_jose, v_auth_linda]);

  raise notice '_smoke_mvp2_contract passed (cena semanal end-to-end con semántica de batch R.2-3)';
end; $function$;

-- ── r2r money: handshake claim + confirm por admin
CREATE OR REPLACE FUNCTION public._smoke_r2r_money_obligation()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  u_a uuid := gen_random_uuid(); u_b uuid := gen_random_uuid();
  a_a uuid; a_b uuid; v_ctx uuid; v_code text;
  v_ob uuid; v_result jsonb; v_item record; v_detail jsonb;
begin
  a_a := public._create_person_actor_for_auth_user(u_a, 'R2R MoneyA', '+520000000301', null);
  a_b := public._create_person_actor_for_auth_user(u_b, 'R2R MoneyB', '+520000000302', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := ((public.create_context('_smoke_r2r Money', 'collective', 'friend_group'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Founder multa a B con $500
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ob := ((public.record_fine(v_ctx, a_b, 500, 'MXN', 'llegó tarde'))->>'obligation_id')::uuid;

  -- La multa nace money/open
  v_detail := public.obligation_detail(v_ob);
  if v_detail->>'kind' <> 'money' then raise exception 'R2R money: kind debió ser money (% )', v_detail->>'kind'; end if;
  if v_detail->>'status' <> 'open' then raise exception 'R2R money: status inicial debió ser open'; end if;
  if (v_detail->>'amount')::numeric <> 500 then raise exception 'R2R money: amount debió ser 500'; end if;

  -- Liquidar: generar batch (nova la multa en iou) + pagar
  v_result := public.generate_settlement_batch(v_ctx, 'MXN');
  select * into v_item from public.settlement_items
   where settlement_batch_id = (v_result->>'batch_id')::uuid and status = 'pending' limit 1;
  if v_item.id is null then raise exception 'R2R money: no se generó item de settlement'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  v_result := public.mark_settlement_paid(v_item.id);
  -- R.5Z handshake: A (admin del contexto) confirma la recepción
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_result := public.confirm_settlement_paid(v_item.id);

  -- No quedan deudas abiertas (la multa quedó settled vía novación)
  if exists (select 1 from public.obligations where context_actor_id = v_ctx and status = 'open') then
    raise exception 'R2R money: la multa no se liquidó (quedaron obligations open)';
  end if;
  if (select status from public.obligations where id = v_ob) <> 'settled' then
    raise exception 'R2R money: la multa original no quedó settled';
  end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx, array[a_a, a_b], array[u_a, u_b]);
  raise notice '_smoke_r2r_money_obligation passed';
end; $function$;

-- ── r2e: idempotencia alineada a la dedup R.6.A (resultado vacío, sin filas nuevas)
CREATE OR REPLACE FUNCTION public._smoke_r2e_rules_dod()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
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
    p_location_text := 'Por definir', p_starts_at := v_starts, p_ends_at := v_starts + interval '3 hours',
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

  -- R.6.A (20260608105005): la re-evaluación con la misma idempotency_key se
  -- dedupea ANTES de tocar consecuencias → resultado vacío y cero filas nuevas.
  v_result := public.evaluate_rules_for_event(v_ctx::uuid, 'event.checked_in', a_moises, v_payload, v_event::uuid);
  if (v_result->>'rules_matched')::integer <> 0
     or jsonb_array_length(v_result->'obligations_created') <> 0 then
    raise exception 'R2E FAIL 4: la re-evaluación de Moisés no fue dedupeada (R.6.A): %', v_result;
  end if;
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and debtor_actor_id = a_moises) <> 1 then
    raise exception 'R2E FAIL 4: la re-evaluación duplicó la obligation de Moisés';
  end if;

  v_result := public.evaluate_rules_for_event(v_ctx::uuid, 'event.participation_cancelled', a_daniel,
    jsonb_build_object('same_day_cancellation', true, 'event_type', 'dinner'), v_event::uuid);
  if (v_result->>'rules_matched')::integer <> 0
     or jsonb_array_length(v_result->'obligations_created') <> 0 then
    raise exception 'R2E FAIL 4: la re-evaluación de Daniel no fue dedupeada (R.6.A): %', v_result;
  end if;
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and debtor_actor_id = a_daniel) <> 1 then
    raise exception 'R2E FAIL 4: la re-evaluación duplicó la obligation de Daniel';
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
  -- R.6.A: las re-evaluaciones dedupeadas NO insertan filas nuevas
  if (select count(*) from public.rule_evaluations
      where context_actor_id = v_ctx::uuid and outcome = 'matched') <> 2 then
    raise exception 'R2E FAIL evaluaciones: esperaba 2 matched (Moisés + Daniel; re-evals dedupeadas)';
  end if;
  if (select count(*) from public.rule_evaluations
      where context_actor_id = v_ctx::uuid and outcome = 'not_matched') <> 2 then
    raise exception 'R2E FAIL evaluaciones: esperaba 2 not_matched (David + Isaac)';
  end if;

  -- activity_events: rule.evaluated, obligation.created, fine.created
  if (select count(*) from public.activity_events
      where context_actor_id = v_ctx::uuid and event_type = 'rule.evaluated') <> 4 then
    raise exception 'R2E FAIL activity: rule.evaluated debe ser 4 (2 matched + 2 not_matched; re-evals dedupeadas R.6.A)';
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
end; $function$;

-- ── r2m3: aserciones al catálogo de acciones vigente (r5a_b5a)
CREATE OR REPLACE FUNCTION public._smoke_r2m3_available_actions()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  u_jose uuid; a_jose uuid;
  v_ctx uuid;
  v_casa uuid; v_cuenta uuid; v_acciones uuid; v_contrato uuid; v_vehiculo uuid; v_trust uuid;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2M3', '+5210000061');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Patrimonio R2M3', 'collective', 'family'))->>'context_actor_id';

  -- Un recurso de cada tipo, propiedad del contexto (José es founder/admin → OWN efectivo)
  v_casa     := (public.create_resource(v_ctx::uuid, 'house', 'Casa Valle'))->>'resource_id';
  v_cuenta   := (public.create_resource(v_ctx::uuid, 'bank_account', 'Cuenta del Viaje'))->>'resource_id';
  v_acciones := (public.create_resource(v_ctx::uuid, 'security', 'Acciones Quimibond'))->>'resource_id';
  v_contrato := (public.create_resource(v_ctx::uuid, 'contract', 'Contrato Arrendamiento'))->>'resource_id';
  v_vehiculo := (public.create_resource(v_ctx::uuid, 'vehicle', 'Vehículo Familiar'))->>'resource_id';
  v_trust    := (public.create_resource(v_ctx::uuid, 'trust_asset', 'Activo del Trust'))->>'resource_id';

  -- ════════════ Casa Valle: reservable, NO monetary ════════════
  if not public.resource_can(v_casa::uuid, 'reservable') then raise exception 'R2M3 FAIL casa: reservable debe ser true'; end if;
  if public.resource_can(v_casa::uuid, 'monetary') then raise exception 'R2M3 FAIL casa: monetary debe ser false'; end if;
  if not public._r2m3_has_action(v_casa::uuid, 'reserve_resource') then raise exception 'R2M3 FAIL casa: falta reserve_resource'; end if;
  if not public._r2m3_has_action(v_casa::uuid, 'view_reservations') then raise exception 'R2M3 FAIL casa: falta view_reservations'; end if;
  if public._r2m3_has_action(v_casa::uuid, 'record_expense') then raise exception 'R2M3 FAIL casa: NO debe ofrecer record_expense'; end if;

  -- ════════════ Cuenta del Viaje: monetary, NO reservable ════════════
  if not public.resource_can(v_cuenta::uuid, 'monetary') then raise exception 'R2M3 FAIL cuenta: monetary debe ser true'; end if;
  if public.resource_can(v_cuenta::uuid, 'reservable') then raise exception 'R2M3 FAIL cuenta: reservable debe ser false'; end if;
  -- r5a_b5a/F.2X: las acciones money de recurso son view_transactions /
  -- export_statement / void_transaction (record_expense vive a nivel contexto)
  if not public._r2m3_has_action(v_cuenta::uuid, 'view_transactions') then raise exception 'R2M3 FAIL cuenta: falta view_transactions'; end if;
  if not public._r2m3_has_action(v_cuenta::uuid, 'export_statement') then raise exception 'R2M3 FAIL cuenta: falta export_statement'; end if;
  if not public._r2m3_has_action(v_cuenta::uuid, 'void_transaction') then raise exception 'R2M3 FAIL cuenta: falta void_transaction'; end if;
  if public._r2m3_has_action(v_cuenta::uuid, 'reserve_resource') then raise exception 'R2M3 FAIL cuenta: NO debe ofrecer reserve_resource'; end if;

  -- ════════════ Acciones Quimibond (security): beneficiary + ownership, NO reservable/monetary ════════════
  if not public.resource_can(v_acciones::uuid, 'beneficiary_supported') then raise exception 'R2M3 FAIL acciones: beneficiary_supported true'; end if;
  if not public.resource_can(v_acciones::uuid, 'ownership_trackable') then raise exception 'R2M3 FAIL acciones: ownership_trackable true'; end if;
  if public.resource_can(v_acciones::uuid, 'reservable') then raise exception 'R2M3 FAIL acciones: reservable false'; end if;
  if public.resource_can(v_acciones::uuid, 'monetary') then raise exception 'R2M3 FAIL acciones: monetary false'; end if;
  if not public._r2m3_has_action(v_acciones::uuid, 'view_beneficiaries') then raise exception 'R2M3 FAIL acciones: falta view_beneficiaries'; end if;
  if not public._r2m3_has_action(v_acciones::uuid, 'transfer_interest') then raise exception 'R2M3 FAIL acciones: falta transfer_interest'; end if;
  if public._r2m3_has_action(v_acciones::uuid, 'reserve_resource') then raise exception 'R2M3 FAIL acciones: NO reserve_resource'; end if;
  if public._r2m3_has_action(v_acciones::uuid, 'record_expense') then raise exception 'R2M3 FAIL acciones: NO record_expense'; end if;

  -- ════════════ Contrato: documentable + approval_required ════════════
  if not public.resource_can(v_contrato::uuid, 'documentable') then raise exception 'R2M3 FAIL contrato: documentable true'; end if;
  if not public.resource_can(v_contrato::uuid, 'approval_required') then raise exception 'R2M3 FAIL contrato: approval_required true'; end if;
  if not public._r2m3_has_action(v_contrato::uuid, 'view_document') then raise exception 'R2M3 FAIL contrato: falta view_document'; end if;
  if not public._r2m3_has_action(v_contrato::uuid, 'review_document') then raise exception 'R2M3 FAIL contrato: falta review_document'; end if;
  if public._r2m3_has_action(v_contrato::uuid, 'reserve_resource') then raise exception 'R2M3 FAIL contrato: NO reserve_resource'; end if;

  -- ════════════ Vehículo: reservable + maintainable ════════════
  if not public.resource_can(v_vehiculo::uuid, 'reservable') then raise exception 'R2M3 FAIL vehiculo: reservable true'; end if;
  if not public.resource_can(v_vehiculo::uuid, 'maintainable') then raise exception 'R2M3 FAIL vehiculo: maintainable true'; end if;
  if not public._r2m3_has_action(v_vehiculo::uuid, 'reserve_resource') then raise exception 'R2M3 FAIL vehiculo: falta reserve_resource'; end if;
  if not public._r2m3_has_action(v_vehiculo::uuid, 'view_maintenance') then raise exception 'R2M3 FAIL vehiculo: falta view_maintenance'; end if;

  -- ════════════ Trust Asset: beneficiary + auditable ════════════
  if not public.resource_can(v_trust::uuid, 'beneficiary_supported') then raise exception 'R2M3 FAIL trust: beneficiary_supported true'; end if;
  if not public.resource_can(v_trust::uuid, 'auditable') then raise exception 'R2M3 FAIL trust: auditable true'; end if;
  if not public._r2m3_has_action(v_trust::uuid, 'view_beneficiaries') then raise exception 'R2M3 FAIL trust: falta view_beneficiaries'; end if;
  if not public._r2m3_has_action(v_trust::uuid, 'view_audit') then raise exception 'R2M3 FAIL trust: falta view_audit'; end if;

  -- grant_right disponible en todos (José administra el contexto dueño)
  if not public._r2m3_has_action(v_casa::uuid, 'grant_right') then raise exception 'R2M3 FAIL: falta grant_right'; end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose], array[u_jose]);

  raise notice 'R.2M-3 AVAILABLE ACTIONS: PASS (casa/cuenta/acciones/contrato/vehículo/trust con affordances correctos)';
end; $function$;

-- ── r2s: alias action==action_key (r7_h_2) en vez de ausencia
CREATE OR REPLACE FUNCTION public._smoke_r2s_fix_available_actions_contract()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  u_isaac uuid; a_isaac uuid;
  v_ctx uuid; v_casa uuid; v_cuenta uuid; v_acciones uuid;
  v_legacy jsonb; v_aware jsonb; v_detail jsonb;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2Sfix', '+5210000131');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2Sfix', '+5210000132');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2Sfix', '+5210000133');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Patrimonio R2Sfix', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_david);
  perform public.invite_member(v_ctx::uuid, a_isaac);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_casa     := (public.create_resource(v_ctx::uuid, 'house', 'Casa Valle'))->>'resource_id';
  v_cuenta   := (public.create_resource(v_ctx::uuid, 'bank_account', 'Cuenta del Viaje'))->>'resource_id';
  v_acciones := (public.create_resource(v_ctx::uuid, 'security', 'Acciones Quimibond'))->>'resource_id';
  perform public.grant_right(v_casa::uuid, a_david, 'USE');   -- David: USE explícito
  perform public.grant_right(v_casa::uuid, a_isaac, 'VIEW');  -- Isaac: solo VIEW

  -- ═══ 1. Firma actor-aware existe (2 args) ═══
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'resource_available_actions' and p.pronargs = 2
  ) then raise exception 'R2S-FIX FAIL 1: no existe la firma actor-aware (2 args)'; end if;

  -- ═══ 2. La firma legacy delega a la actor-aware ═══
  v_legacy := public.resource_available_actions(v_casa::uuid);
  v_aware  := public.resource_available_actions(v_casa::uuid, a_jose);
  if v_legacy is distinct from v_aware then
    raise exception 'R2S-FIX FAIL 2: la firma legacy no delega a la actor-aware';
  end if;

  -- ═══ 3. Casa Valle: actor con USE ve reserve; actor VIEW no ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_aware := public.resource_available_actions(v_casa::uuid, a_david);
  if not exists (select 1 from jsonb_array_elements(v_aware) e
                 where e->>'action_key' = 'reserve_resource' and (e->>'enabled')::boolean) then
    raise exception 'R2S-FIX FAIL 3: David (USE) no ve reserve_resource enabled';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_aware := public.resource_available_actions(v_casa::uuid, a_isaac);
  if exists (select 1 from jsonb_array_elements(v_aware) e where e->>'action_key' = 'reserve_resource') then
    raise exception 'R2S-FIX FAIL 3: Isaac (solo VIEW) NO debería ver reserve_resource';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  -- ═══ 4. Cuenta bancaria nunca muestra reserve ═══
  if exists (select 1 from jsonb_array_elements(public.resource_available_actions(v_cuenta::uuid)) e
             where e->>'action_key' = 'reserve_resource') then
    raise exception 'R2S-FIX FAIL 4: la cuenta bancaria muestra reserve_resource';
  end if;

  -- ═══ 5. Security nunca muestra reserve; sí beneficiary/ownership ═══
  v_aware := public.resource_available_actions(v_acciones::uuid);
  if exists (select 1 from jsonb_array_elements(v_aware) e where e->>'action_key' = 'reserve_resource') then
    raise exception 'R2S-FIX FAIL 5: security muestra reserve_resource';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_aware) e where e->>'action_key' = 'view_beneficiaries') then
    raise exception 'R2S-FIX FAIL 5: security no muestra view_beneficiaries';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_aware) e where e->>'action_key' = 'view_ownership') then
    raise exception 'R2S-FIX FAIL 5: security no muestra view_ownership';
  end if;

  -- ═══ 6. resource_detail usa el shape canónico (7 campos) + why_visible ═══
  v_detail := public.resource_detail(v_casa::uuid);
  if jsonb_typeof(v_detail->'available_actions') <> 'array'
     or jsonb_typeof(v_detail->'why_visible') <> 'array'
     or jsonb_typeof(v_detail->'capabilities') <> 'array' then
    raise exception 'R2S-FIX FAIL 6: resource_detail no trae el contrato completo';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_detail->'available_actions') e
    where not (e ? 'action_key' and e ? 'label' and e ? 'section' and e ? 'enabled'
               and e ? 'reason' and e ? 'required_rights' and e ? 'required_capabilities')
  ) then raise exception 'R2S-FIX FAIL 6: un action object no tiene la forma canónica de 7 campos'; end if;

  -- ═══ 7. No hay dos shapes: ningún action usa la key legacy 'action' ═══
  -- r7_h_2 (20260608235501) reintrodujo 'action' como ALIAS deliberado de
  -- action_key (backcompat de clientes). El contrato ahora exige consistencia.
  if exists (
    select 1 from jsonb_array_elements(v_detail->'available_actions') e
    where (e ? 'action') and e->>'action' is distinct from e->>'action_key'
  ) then raise exception 'R2S-FIX FAIL 7: alias legacy action ≠ action_key'; end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose, a_david, a_isaac], array[u_jose, u_david, u_isaac]);

  raise notice 'R.2S-FIX CANONICAL AVAILABLE ACTIONS: PASS (actor-aware + legacy delega + casa/cuenta/security + shape único action_key)';
end; $function$;

-- ── r8_a: insert de resource condicional al drift context_actor_id + obligation_type valido (contribution)
CREATE OR REPLACE FUNCTION public._smoke_r8_a_pool_account_lifecycle()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_parent_actor uuid;
  v_creator_actor uuid;
  v_pool_actor uuid;
  v_pool_account uuid;
  v_basis_cash uuid;
  v_basis_asset uuid;
  v_basis_stake uuid;
  v_resource uuid;
  v_obligation_id uuid;
  v_count int;
begin
  -- Crear actors de prueba (sin auth.uid, directos en tabla)
  insert into public.actors (actor_kind, actor_subtype, display_name)
  values ('collective', 'friend_group', '_smoke_r8a parent')
  returning id into v_parent_actor;

  insert into public.actors (actor_kind, actor_subtype, display_name)
  values ('person', 'person', '_smoke_r8a creator')
  returning id into v_creator_actor;

  -- 1. Crear pool actor (subtype='pool' debe pasar el CHECK ampliado)
  insert into public.actors (actor_kind, actor_subtype, display_name)
  values ('collective', 'pool', '_smoke_r8a Bote Test')
  returning id into v_pool_actor;

  -- 2. Crear pool_accounts row
  insert into public.pool_accounts (
    pool_actor_id, parent_context_actor_id, policy_key, policy_config,
    display_name, currency, created_by_actor_id
  )
  values (
    v_pool_actor, v_parent_actor, 'winner_takes_all',
    '{"stake_per_player": 200}'::jsonb,
    'Bote Test', 'MXN', v_creator_actor
  )
  returning id into v_pool_account;

  -- 3. Insertar basis entries: cash + asset + pending_stake
  -- 3a. asset requiere asset_resource_id → primero creo un resource dummy
  -- resources.context_actor_id existe en la BD viva (drift nunca aterrizado en
  -- disco) pero NO en el replay de la cadena. Insert condicional para que el
  -- smoke pase en ambos mundos sin tocar el schema.
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'resources'
                and column_name = 'context_actor_id') then
    execute 'insert into public.resources (
        context_actor_id, resource_type, display_name, canonical_owner_actor_id,
        estimated_value, currency, created_by_actor_id)
      values ($1, ''other'', ''_smoke_r8a Terreno'', $2, 5000000, ''MXN'', $2)
      returning id'
      into v_resource using v_parent_actor, v_creator_actor;
  else
    insert into public.resources (
      resource_type, display_name, canonical_owner_actor_id,
      estimated_value, currency, created_by_actor_id
    )
    values ('other', '_smoke_r8a Terreno', v_creator_actor,
            5000000, 'MXN', v_creator_actor)
    returning id into v_resource;
  end if;

  insert into public.pool_basis_entries (
    pool_account_id, contributor_actor_id, basis_kind, basis_amount, currency
  )
  values (v_pool_account, v_creator_actor, 'cash', 1000, 'MXN')
  returning id into v_basis_cash;

  insert into public.pool_basis_entries (
    pool_account_id, contributor_actor_id, basis_kind, basis_amount,
    asset_resource_id, valuation_method
  )
  values (v_pool_account, v_creator_actor, 'asset', 5000000, v_resource, 'manual')
  returning id into v_basis_asset;

  insert into public.pool_basis_entries (
    pool_account_id, contributor_actor_id, basis_kind, basis_amount, currency
  )
  values (v_pool_account, v_creator_actor, 'pending_stake', 200, 'MXN')
  returning id into v_basis_stake;

  select count(*) into v_count from public.pool_basis_entries
   where pool_account_id = v_pool_account;
  if v_count <> 3 then
    raise exception 'R.8.A: esperaba 3 basis entries, encontré %', v_count;
  end if;

  -- 4. Insertar obligation con status='pending_pool' (status nuevo)
  insert into public.obligations (
    context_actor_id, debtor_actor_id, creditor_actor_id,
    obligation_type, obligation_kind, status, amount, currency
  )
  -- R.9.G: el CHECK de obligation_type en disco nunca incluyó 'pool_stake'
  -- (R.8.A solo extendió el CHECK de status). El flujo real (contribute_to_pool,
  -- R.8.B) usa obligation_type='contribution' con status='pending_pool' — el
  -- smoke verifica el STATUS nuevo, no el type.
  values (
    v_parent_actor, v_creator_actor, v_pool_actor,
    'contribution', 'money', 'pending_pool', 200, 'MXN'
  )
  returning id into v_obligation_id;

  if (select status from public.obligations where id = v_obligation_id) <> 'pending_pool' then
    raise exception 'R.8.A: status pending_pool no quedó persistido';
  end if;

  -- 5. Settlement batcher (R.2N) ignora pending_pool: count obligations open en el contexto
  --    debe quedar en 0 a pesar de tener la obligación pending_pool encima.
  select count(*) into v_count from public.obligations
   where context_actor_id = v_parent_actor and status = 'open';
  if v_count <> 0 then
    raise exception 'R.8.A: pending_pool no debió contar como open (encontré %)', v_count;
  end if;

  -- 6. CHECK rejections defensivos
  begin
    insert into public.pool_accounts (
      pool_actor_id, parent_context_actor_id, policy_key, display_name
    )
    values (v_pool_actor, v_parent_actor, 'invalid_policy', 'should fail');
    raise exception 'R.8.A: policy_key inválida debió fallar el CHECK';
  exception when check_violation then null;
  end;

  begin
    insert into public.pool_basis_entries (
      pool_account_id, contributor_actor_id, basis_kind, basis_amount
    )
    values (v_pool_account, v_creator_actor, 'asset', 100);  -- falta asset_resource_id
    raise exception 'R.8.A: asset sin resource_id debió fallar el CHECK';
  exception when check_violation then null;
  end;

  begin
    insert into public.pool_basis_entries (
      pool_account_id, contributor_actor_id, basis_kind, basis_amount
    )
    values (v_pool_account, v_creator_actor, 'cash', 100);  -- falta currency
    raise exception 'R.8.A: cash sin currency debió fallar el CHECK';
  exception when check_violation then null;
  end;

  begin
    insert into public.pool_basis_entries (
      pool_account_id, contributor_actor_id, basis_kind, basis_amount, currency
    )
    values (v_pool_account, v_creator_actor, 'cash', -50, 'MXN');  -- negativo
    raise exception 'R.8.A: basis_amount negativo debió fallar el CHECK';
  exception when check_violation then null;
  end;

  -- 7. Cleanup (orden inverso por FKs)
  delete from public.obligations where id = v_obligation_id;
  delete from public.pool_basis_entries where pool_account_id = v_pool_account;
  delete from public.pool_accounts where id = v_pool_account;
  delete from public.resources where id = v_resource;
  delete from public.actors where id = v_pool_actor;
  delete from public.actors where id = v_creator_actor;
  delete from public.actors where id = v_parent_actor;

  raise notice '_smoke_r8_a_pool_account_lifecycle passed';
end; $function$;

-- ── _r2_cleanup_context: limpieza de pools R.8
CREATE OR REPLACE FUNCTION public._r2_cleanup_context(p_ctx uuid, p_actors uuid[], p_auths uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
begin
  -- R.8 pools: basis entries (FK a money_transactions) + accounts PRIMERO;
  -- sin esto, pool_basis_entries_money_transaction_id_fkey y
  -- actors_created_by_actor_id_fkey revientan el cleanup de los smokes R.8.
  delete from public.pool_basis_entries where pool_account_id in
    (select id from public.pool_accounts where parent_context_actor_id = p_ctx);
  delete from public.pool_accounts where parent_context_actor_id = p_ctx;

  delete from public.settlement_items where settlement_batch_id in
    (select id from public.settlement_batches where context_actor_id = p_ctx);
  delete from public.settlement_batches where context_actor_id = p_ctx;
  delete from public.money_splits where transaction_id in
    (select id from public.money_transactions where context_actor_id = p_ctx);
  delete from public.money_transactions where context_actor_id = p_ctx;
  delete from public.rule_evaluations where context_actor_id = p_ctx;
  delete from public.obligations where context_actor_id = p_ctx;
  delete from public.rules where context_actor_id = p_ctx;
  delete from public.event_participants where event_id in
    (select id from public.calendar_events where context_actor_id = p_ctx);
  delete from public.calendar_events where context_actor_id = p_ctx;

  -- R.2-6: rights y resources sin asumir canonical — por holder (ctx o personas),
  -- por canonical (ctx o personas), o por creador (ctx o personas)
  delete from public.reservation_conflicts where resource_id in
    (select id from public.resources
      where canonical_owner_actor_id = p_ctx or canonical_owner_actor_id = any(p_actors)
         or created_by_actor_id = p_ctx or created_by_actor_id = any(p_actors));
  delete from public.resource_reservations where context_actor_id = p_ctx;
  delete from public.decision_votes where decision_id in
    (select id from public.decisions where context_actor_id = p_ctx);
  delete from public.decisions where context_actor_id = p_ctx;
  delete from public.documents where context_actor_id = p_ctx;

  delete from public.resource_rights
   where holder_actor_id = p_ctx or holder_actor_id = any(p_actors)
      or resource_id in (
        select id from public.resources
         where canonical_owner_actor_id = p_ctx or canonical_owner_actor_id = any(p_actors)
            or created_by_actor_id = p_ctx or created_by_actor_id = any(p_actors));

  delete from public.resources
   where canonical_owner_actor_id = p_ctx or canonical_owner_actor_id = any(p_actors)
      or created_by_actor_id = p_ctx or created_by_actor_id = any(p_actors);

  -- R.8 pools: los pool actors del contexto salen después de obligations/money
  delete from public.actors a
   where a.actor_kind = 'collective' and a.actor_subtype = 'pool'
     and (a.created_by_actor_id = p_ctx or a.created_by_actor_id = any(p_actors)
          or (a.metadata->>'parent_context_actor_id')::uuid = p_ctx);

  delete from public.context_invites where context_actor_id = p_ctx;
  delete from public.role_assignments where context_actor_id = p_ctx;
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id = p_ctx;
  delete from public.roles where context_actor_id = p_ctx;
  delete from public.actor_memberships where context_actor_id = p_ctx;
  delete from public.actors where id = p_ctx;
  delete from public.person_profiles where actor_id = any(p_actors);
  delete from public.actors where id = any(p_actors);
  delete from auth.users where id = any(p_auths);
end; $function$;
