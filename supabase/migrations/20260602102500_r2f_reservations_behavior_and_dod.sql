-- ============================================================================
-- R.2F — RESERVATIONS DoD: rights-based + prioridad 90 días + confirm + caso exacto
-- ============================================================================
-- Caso: Familia Mizrahi / Casa Valle. David (USE, 2 usos recientes) e Isaac
-- (USE, 0 usos) piden el mismo fin de semana → conflicto → least_recent_use_wins
-- recomienda a Isaac → Abuelo resuelve → Isaac confirmed, David rejected.
--
-- Gaps corregidos (solo RPCs, cero schema — doctrina R.2):
--   1. request_resource_reservation: autorización RIGHTS-BASED — USE/MANAGE/OWN
--      permite reservar; VIEW no; no-miembro sin rights no (antes bastaba ser
--      miembro con reservations.request).
--   2. priority_score: confirmed/completed en los últimos 90 días (antes solo
--      completed en 30 días). Regla registrada: least_recent_use_wins.
--   3. approve/resolve: MANAGE/OWN/GOVERN sobre el recurso o founder/admin
--      (antes solo rol reservations.manage).
--   4. confirm_reservation: NUEVO — approved → confirmed (self o manager),
--      repetido es no-op seguro.
--   5. Smoke M.6 actualizado: B recibe USE right (la doctrina rights-based
--      exige rights explícitos para reservar).
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. request_resource_reservation: rights-based + prioridad 90 días
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.request_resource_reservation(
  p_resource_id uuid,
  p_context_actor_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_reserved_for_actor_id uuid default null,
  p_metadata jsonb default '{}'::jsonb,
  p_client_id text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_target uuid;
  v_id uuid;
  v_existing uuid;
  v_conflicts integer;
  v_recent_use integer;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  v_target := coalesce(p_reserved_for_actor_id, v_caller);

  if not exists (select 1 from public.resources where id = p_resource_id and archived_at is null) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;

  -- R.2F: los rights explican quién puede reservar — USE/MANAGE/OWN (VIEW no).
  -- También puede reservar quien ejerce los rights de un holder colectivo
  -- (ej. admin del contexto dueño, vía resources.manage).
  if not (
    public.actor_has_right(v_caller, p_resource_id, 'USE')
    or public.actor_has_right(v_caller, p_resource_id, 'MANAGE')
    or public.actor_has_right(v_caller, p_resource_id, 'OWN')
    or exists (
      select 1 from public.resource_rights rr
      where rr.resource_id = p_resource_id
        and rr.right_kind in ('USE', 'MANAGE', 'OWN', 'GOVERN')
        and rr.revoked_at is null and rr.expired_at is null
        and (rr.starts_at is null or rr.starts_at <= now())
        and (rr.ends_at is null or rr.ends_at > now())
        and public.has_actor_authority(rr.holder_actor_id, v_caller, 'resources.manage'))
  ) then
    raise exception 'reserving requires USE, MANAGE or OWN right on resource %', p_resource_id using errcode = '42501';
  end if;

  -- idempotencia por client_id
  if p_client_id is not null then
    select id into v_existing from public.resource_reservations
     where requested_by_actor_id = v_caller and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('reservation_id', v_existing,
        'reservation', (select to_jsonb(r) from public.resource_reservations r where r.id = v_existing));
    end if;
  end if;

  -- R.2F priority (least_recent_use_wins): uso confirmado/completado del recurso
  -- en los últimos 90 días — menos uso = mejor prioridad
  select count(*) into v_recent_use from public.resource_reservations rr
   where rr.resource_id = p_resource_id
     and rr.reserved_for_actor_id = v_target
     and rr.status in ('confirmed', 'completed')
     and rr.starts_at > now() - interval '90 days';

  insert into public.resource_reservations
    (resource_id, context_actor_id, requested_by_actor_id, reserved_for_actor_id,
     starts_at, ends_at, metadata, client_id, priority_score)
  values
    (p_resource_id, p_context_actor_id, v_caller, v_target,
     p_starts_at, p_ends_at,
     coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object(
       'priority_rule', 'least_recent_use_wins', 'recent_use_count', v_recent_use),
     p_client_id, v_recent_use)
  returning id into v_id;

  -- detección inmediata de conflictos
  select count(*) into v_conflicts from public.detect_reservation_conflicts(p_resource_id);

  perform public._emit_activity(p_context_actor_id, v_caller, 'reservation.requested', 'reservation', v_id,
    jsonb_build_object('resource_id', p_resource_id, 'starts_at', p_starts_at, 'ends_at', p_ends_at,
                       'conflicts_detected', v_conflicts, 'priority_score', v_recent_use),
    p_resource_id := p_resource_id);

  return jsonb_build_object('reservation_id', v_id, 'conflicts_detected', v_conflicts,
    'reservation', (select to_jsonb(r) from public.resource_reservations r where r.id = v_id));
end; $$;

revoke all on function public.request_resource_reservation(uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text) from public, anon;
grant execute on function public.request_resource_reservation(uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. detect_reservation_conflicts: metadata con regla de prioridad y scores
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.detect_reservation_conflicts(p_resource_id uuid)
returns setof public.reservation_conflicts
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.reservation_conflicts
    (resource_id, reservation_a_id, reservation_b_id, conflict_type, recommended_winner_actor_id, metadata)
  select p_resource_id,
         least(a.id, b.id), greatest(a.id, b.id), 'overlap',
         -- least_recent_use_wins: menor priority_score (= menor uso reciente) gana
         case when coalesce(a.priority_score, 0) <= coalesce(b.priority_score, 0)
              then a.reserved_for_actor_id
              else b.reserved_for_actor_id
         end,
         jsonb_build_object('detected_at', now(),
                            'priority_rule', 'least_recent_use_wins',
                            'scores', jsonb_build_object(
                              a.reserved_for_actor_id::text, coalesce(a.priority_score, 0),
                              b.reserved_for_actor_id::text, coalesce(b.priority_score, 0)))
    from public.resource_reservations a
    join public.resource_reservations b
      on b.resource_id = a.resource_id
     and b.id > a.id
     and tstzrange(a.starts_at, a.ends_at) && tstzrange(b.starts_at, b.ends_at)
   where a.resource_id = p_resource_id
     and a.status in ('requested', 'approved', 'confirmed')
     and b.status in ('requested', 'approved', 'confirmed')
  on conflict (reservation_a_id, reservation_b_id) do nothing;

  return query
    select * from public.reservation_conflicts
    where resource_id = p_resource_id and resolution_status = 'open';
end; $$;

revoke all on function public.detect_reservation_conflicts(uuid) from public, anon;
grant execute on function public.detect_reservation_conflicts(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Helper de autorización de manejo de reservaciones (R.2F)
-- ────────────────────────────────────────────────────────────────────────────
-- MANAGE/OWN/GOVERN sobre el recurso, o founder/admin (reservations.manage)
create or replace function public._can_manage_reservations(p_actor_id uuid, p_resource_id uuid, p_context_actor_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.actor_has_right(p_actor_id, p_resource_id, 'MANAGE')
      or public.actor_has_right(p_actor_id, p_resource_id, 'OWN')
      or public.actor_has_right(p_actor_id, p_resource_id, 'GOVERN')
      or public.has_actor_authority(p_context_actor_id, p_actor_id, 'reservations.manage');
$$;

revoke all on function public._can_manage_reservations(uuid, uuid, uuid) from public, anon;
grant execute on function public._can_manage_reservations(uuid, uuid, uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. approve_reservation: autorización rights-based o admin
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.approve_reservation(p_reservation_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_r public.resource_reservations%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_r from public.resource_reservations where id = p_reservation_id for update;
  if v_r.id is null then raise exception 'reservation not found' using errcode = 'P0002'; end if;

  -- R.2F: MANAGE/OWN/GOVERN sobre el recurso, o founder/admin
  if not public._can_manage_reservations(v_caller, v_r.resource_id, v_r.context_actor_id) then
    raise exception 'not authorized to approve reservations' using errcode = '42501';
  end if;
  if v_r.status <> 'requested' then
    return jsonb_build_object('reservation_id', p_reservation_id, 'status', v_r.status, 'no_op', true);
  end if;

  -- el EXCLUDE constraint lanza exclusion_violation (23P01) si traslapa
  update public.resource_reservations set status = 'approved' where id = p_reservation_id;

  perform public._emit_activity(v_r.context_actor_id, v_caller, 'reservation.approved', 'reservation', p_reservation_id,
    '{}'::jsonb, p_resource_id := v_r.resource_id);

  return jsonb_build_object('reservation_id', p_reservation_id, 'status', 'approved');
end; $$;

revoke all on function public.approve_reservation(uuid) from public, anon;
grant execute on function public.approve_reservation(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. resolve_reservation_conflict: autorización rights-based o admin
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.resolve_reservation_conflict(
  p_conflict_id uuid,
  p_winner_reservation_id uuid
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_c public.reservation_conflicts%rowtype;
  v_loser uuid;
  v_ctx uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_c from public.reservation_conflicts where id = p_conflict_id for update;
  if v_c.id is null then raise exception 'conflict not found' using errcode = 'P0002'; end if;
  if p_winner_reservation_id not in (v_c.reservation_a_id, v_c.reservation_b_id) then
    raise exception 'winner must be one of the conflicting reservations' using errcode = '22023';
  end if;

  select context_actor_id into v_ctx from public.resource_reservations where id = p_winner_reservation_id;

  -- R.2F: MANAGE/OWN/GOVERN sobre el recurso, o founder/admin
  if not public._can_manage_reservations(v_caller, v_c.resource_id, v_ctx) then
    raise exception 'not authorized to resolve conflicts' using errcode = '42501';
  end if;
  if v_c.resolution_status <> 'open' then
    return jsonb_build_object('conflict_id', p_conflict_id, 'no_op', true);
  end if;

  v_loser := case when p_winner_reservation_id = v_c.reservation_a_id
                  then v_c.reservation_b_id else v_c.reservation_a_id end;

  -- perdedor rejected ANTES de aprobar al ganador (libera el rango para el EXCLUDE)
  update public.resource_reservations set status = 'rejected',
         metadata = metadata || jsonb_build_object('rejected_by_conflict', p_conflict_id)
   where id = v_loser and status in ('requested', 'approved');

  update public.resource_reservations set status = 'approved'
   where id = p_winner_reservation_id and status = 'requested';

  update public.reservation_conflicts
     set resolution_status = 'resolved', resolved_at = now(),
         metadata = metadata || jsonb_build_object('winner', p_winner_reservation_id, 'resolved_by', v_caller)
   where id = p_conflict_id;

  perform public._emit_activity(v_ctx, v_caller, 'reservation.conflict_resolved', 'reservation_conflict', p_conflict_id,
    jsonb_build_object('winner', p_winner_reservation_id, 'loser', v_loser),
    p_resource_id := v_c.resource_id);

  return jsonb_build_object('conflict_id', p_conflict_id, 'winner', p_winner_reservation_id, 'loser', v_loser);
end; $$;

revoke all on function public.resolve_reservation_conflict(uuid, uuid) from public, anon;
grant execute on function public.resolve_reservation_conflict(uuid, uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 6. confirm_reservation: NUEVO — approved → confirmed
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.confirm_reservation(p_reservation_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_r public.resource_reservations%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_r from public.resource_reservations where id = p_reservation_id for update;
  if v_r.id is null then raise exception 'reservation not found' using errcode = 'P0002'; end if;

  -- self (el beneficiario o quien la solicitó) o manager del recurso
  if v_caller not in (v_r.reserved_for_actor_id, v_r.requested_by_actor_id)
     and not public._can_manage_reservations(v_caller, v_r.resource_id, v_r.context_actor_id) then
    raise exception 'not authorized to confirm this reservation' using errcode = '42501';
  end if;

  -- R.2F idempotencia: confirm repetido es no-op seguro
  if v_r.status = 'confirmed' then
    return jsonb_build_object('reservation_id', p_reservation_id, 'status', 'confirmed', 'already_confirmed', true);
  end if;
  if v_r.status <> 'approved' then
    raise exception 'only approved reservations can be confirmed (current: %)', v_r.status using errcode = '22023';
  end if;

  update public.resource_reservations set status = 'confirmed' where id = p_reservation_id;

  perform public._emit_activity(v_r.context_actor_id, v_caller, 'reservation.confirmed', 'reservation', p_reservation_id,
    jsonb_build_object('resource_id', v_r.resource_id, 'starts_at', v_r.starts_at, 'ends_at', v_r.ends_at),
    p_resource_id := v_r.resource_id);

  return jsonb_build_object('reservation_id', p_reservation_id, 'status', 'confirmed');
end; $$;

revoke all on function public.confirm_reservation(uuid) from public, anon;
grant execute on function public.confirm_reservation(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 7. Smoke M.6 actualizado: rights-based exige que B tenga USE
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_m6_reservations()
returns void
language plpgsql security definer set search_path = public, auth
as $$
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
     or has_function_privilege('anon', 'public.request_resource_reservation(uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text)', 'EXECUTE') then
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
end; $$;

revoke all on function public._smoke_mvp2_m6_reservations() from public, anon, authenticated;

comment on function public._smoke_mvp2_m6_reservations() is 'Smoke MVP2 M.6: reservaciones rights-based, conflictos, resolución, EXCLUDE constraint.';

-- ────────────────────────────────────────────────────────────────────────────
-- 8. Smoke R.2F — caso exacto del founder
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2f_reservations_dod()
returns void
language plpgsql security definer set search_path = public, auth
as $$
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
    'public.request_resource_reservation(uuid, uuid, timestamptz, timestamptz, uuid, jsonb, text)',
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
end; $$;

revoke all on function public._smoke_r2f_reservations_dod() from public, anon, authenticated;

comment on function public._smoke_r2f_reservations_dod() is
  'R.2F DoD exacto: Casa Valle → David (2 usos) vs Isaac (0 usos) mismo finde → conflicto → least_recent_use_wins → Isaac confirmed, David rejected → VIEW/no-miembro/archived/anon bloqueados → idempotencia.';

-- Wrapper para CI (descubre funciones _smoke_mvp2_%)
create or replace function public._smoke_mvp2_r2f_reservations_dod()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._smoke_r2f_reservations_dod();
end; $$;

revoke all on function public._smoke_mvp2_r2f_reservations_dod() from public, anon, authenticated;

comment on function public._smoke_mvp2_r2f_reservations_dod() is
  'Wrapper CI del smoke R.2F (_smoke_r2f_reservations_dod).';
