-- ============================================================================
-- R.2T — Reservation ≠ Event SMOKES
-- ============================================================================
-- Cinco smokes blindan la doctrina (ver Plans/Active/doctrine_r2t_reservation_vs_event.md):
--
--   1. _smoke_r2t_event_without_reservation        — Event existe sin reservations.
--   2. _smoke_r2t_reservation_without_event        — Reservation existe sin event.
--   3. _smoke_r2t_event_with_reservations          — Mundial: event + 4 reservations
--                                                    con source_event_id cargado.
--   4. _smoke_r2t_reservation_conflict_world_cup   — Overlap entre las 4 produce
--                                                    >=1 reservation_conflict.
--   5. _smoke_r2t_decision_resolves_conflict       — Decision resuelve el conflict.
--
-- NO valida cupos/seats (R.2T-CAPACITY, fuera de scope).
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Event sin Reservation
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2t_event_without_reservation()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u uuid; a uuid;
  v_ctx uuid;
  v_event uuid;
  v_count int;
begin
  select auth_id, actor_id into u, a from public._r2_make_person('R2T evt-only', '+5210000201');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u::text)::text, true);

  v_ctx := (public.create_context('R2T Familia EvtOnly', 'collective', 'family'))->>'context_actor_id';

  v_event := (public.create_calendar_event(
    p_context_actor_id := v_ctx,
    p_title := 'Comida Miércoles',
    p_event_type := 'dinner',
    p_starts_at := now() + interval '7 days',
    p_ends_at := now() + interval '7 days' + interval '2 hours',
    p_invite_all_members := false))->>'event_id';

  if v_event is null then
    raise exception 'R2T smoke 1: create_calendar_event no devolvió event_id';
  end if;

  -- Asserts: NO existen reservations apuntando al event.
  select count(*) into v_count
    from public.resource_reservations
    where source_event_id = v_event::uuid;
  if v_count <> 0 then
    raise exception 'R2T smoke 1: event sin reservation tiene % filas en resource_reservations', v_count;
  end if;

  raise notice 'R2T smoke 1 OK: event % existe sin reservations', v_event;
end; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Reservation sin Event
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2t_reservation_without_event()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u uuid; a uuid;
  v_ctx uuid;
  v_casa uuid;
  v_resv uuid;
  v_source uuid;
begin
  select auth_id, actor_id into u, a from public._r2_make_person('R2T resv-only', '+5210000202');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u::text)::text, true);

  v_ctx := (public.create_context('R2T Familia ResvOnly', 'collective', 'family'))->>'context_actor_id';
  v_casa := (public.create_resource(v_ctx, 'house', 'Casa Valle R2T'))->>'resource_id';

  -- Reservation sin source_event_id.
  v_resv := (public.request_resource_reservation(
    p_resource_id := v_casa,
    p_context_actor_id := v_ctx,
    p_starts_at := now() + interval '10 days',
    p_ends_at := now() + interval '12 days'))->>'reservation_id';

  if v_resv is null then
    raise exception 'R2T smoke 2: request_resource_reservation no devolvió reservation_id';
  end if;

  select source_event_id into v_source
    from public.resource_reservations where id = v_resv::uuid;

  if v_source is not null then
    raise exception 'R2T smoke 2: reservation sin event tiene source_event_id = %', v_source;
  end if;

  raise notice 'R2T smoke 2 OK: reservation % existe sin event', v_resv;
end; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Mundial: Event con Reservations asociadas
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2t_event_with_reservations()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_papa uuid; a_papa uuid;
  u_abu uuid;  a_abu uuid;
  u_pepe uuid; a_pepe uuid;
  v_ctx uuid;
  v_palco uuid;
  v_event uuid;
  v_starts timestamptz := now() + interval '30 days';
  v_ends   timestamptz := now() + interval '30 days' + interval '3 hours';
  v_count int;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('R2T José', '+5210000211');
  select auth_id, actor_id into u_papa, a_papa from public._r2_make_person('R2T Papá', '+5210000212');
  select auth_id, actor_id into u_abu,  a_abu  from public._r2_make_person('R2T Abuelo', '+5210000213');
  select auth_id, actor_id into u_pepe, a_pepe from public._r2_make_person('R2T Pepe', '+5210000214');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('R2T Mizrahi Mundial', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx, a_papa);
  perform public.invite_member(v_ctx, a_abu);
  perform public.invite_member(v_ctx, a_pepe);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  perform public.accept_invitation(v_ctx);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abu::text)::text, true);
  perform public.accept_invitation(v_ctx);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_pepe::text)::text, true);
  perform public.accept_invitation(v_ctx);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_palco := (public.create_resource(v_ctx, 'house', 'Palco Azteca R2T'))->>'resource_id';
  perform public.grant_right(v_palco, v_ctx, 'MANAGE');
  perform public.grant_right(v_palco, a_papa, 'USE');
  perform public.grant_right(v_palco, a_abu, 'USE');
  perform public.grant_right(v_palco, a_pepe, 'USE');

  -- Event: México vs Brasil.
  v_event := (public.create_calendar_event(
    p_context_actor_id := v_ctx,
    p_title := 'México vs Brasil',
    p_event_type := 'community_event',
    p_starts_at := v_starts,
    p_ends_at := v_ends,
    p_invite_all_members := true))->>'event_id';

  -- 4 reservations sobre el palco, todas referenciando el event.
  perform public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_jose,
    p_metadata := jsonb_build_object('seats', 1),
    p_source_event_id := v_event::uuid);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  perform public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_papa,
    p_metadata := jsonb_build_object('seats', 2),
    p_source_event_id := v_event::uuid);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abu::text)::text, true);
  perform public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_abu,
    p_metadata := jsonb_build_object('seats', 2),
    p_source_event_id := v_event::uuid);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_pepe::text)::text, true);
  perform public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_pepe,
    p_metadata := jsonb_build_object('seats', 2),
    p_source_event_id := v_event::uuid);

  -- Asserts.
  select count(*) into v_count
    from public.resource_reservations
    where source_event_id = v_event::uuid;
  if v_count <> 4 then
    raise exception 'R2T smoke 3: esperaba 4 reservations con source_event_id, got %', v_count;
  end if;

  -- Event NO contiene reservations (no hay columna ni tabla de junction).
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='calendar_events' and column_name='reservation_ids'
  ) then
    raise exception 'R2T smoke 3: calendar_events tiene columna reservation_ids (violación doctrinal)';
  end if;

  raise notice 'R2T smoke 3 OK: event % con 4 reservations vía source_event_id', v_event;
end; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Conflict detectado (overlap, no capacity)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2t_reservation_conflict_world_cup()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_papa uuid; a_papa uuid;
  v_ctx uuid;
  v_palco uuid;
  v_event uuid;
  v_starts timestamptz := now() + interval '40 days';
  v_ends   timestamptz := now() + interval '40 days' + interval '3 hours';
  v_resv1 uuid; v_resv2 uuid;
  v_conflicts int;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('R2T José conflict', '+5210000221');
  select auth_id, actor_id into u_papa, a_papa from public._r2_make_person('R2T Papá conflict', '+5210000222');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('R2T Mizrahi Conflict', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx, a_papa);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  perform public.accept_invitation(v_ctx);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_palco := (public.create_resource(v_ctx, 'house', 'Palco Azteca R2T Conflict'))->>'resource_id';
  perform public.grant_right(v_palco, v_ctx, 'MANAGE');
  perform public.grant_right(v_palco, a_papa, 'USE');

  v_event := (public.create_calendar_event(
    p_context_actor_id := v_ctx,
    p_title := 'México vs Brasil (conflict)',
    p_event_type := 'community_event',
    p_starts_at := v_starts,
    p_ends_at := v_ends,
    p_invite_all_members := false))->>'event_id';

  -- Dos reservaciones overlapping en la misma ventana.
  v_resv1 := (public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_jose,
    p_source_event_id := v_event::uuid))->>'reservation_id';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  v_resv2 := (public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_papa,
    p_source_event_id := v_event::uuid))->>'reservation_id';

  -- detect_reservation_conflicts ya corre dentro del request, pero re-verifico
  -- contra la tabla.
  select count(*) into v_conflicts
    from public.reservation_conflicts
    where resource_id = v_palco
      and resolution_status = 'open'
      and (reservation_a_id = v_resv1::uuid or reservation_b_id = v_resv1::uuid
        or reservation_a_id = v_resv2::uuid or reservation_b_id = v_resv2::uuid);
  if v_conflicts < 1 then
    raise exception 'R2T smoke 4: esperaba >=1 reservation_conflict, got %', v_conflicts;
  end if;

  raise notice 'R2T smoke 4 OK: % conflict(s) detectado(s) por overlap', v_conflicts;
end; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Decision resuelve el conflict
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2t_decision_resolves_conflict()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_papa uuid; a_papa uuid;
  u_abu uuid;  a_abu uuid;
  v_ctx uuid;
  v_palco uuid;
  v_event uuid;
  v_starts timestamptz := now() + interval '50 days';
  v_ends   timestamptz := now() + interval '50 days' + interval '3 hours';
  v_resv1 uuid; v_resv2 uuid;
  v_conflict uuid;
  v_decision uuid;
  v_winner_opt text;
  v_status text;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('R2T José rslv2', '+5210000241');
  select auth_id, actor_id into u_papa, a_papa from public._r2_make_person('R2T Papá rslv2', '+5210000242');
  select auth_id, actor_id into u_abu,  a_abu  from public._r2_make_person('R2T Abuelo rslv2', '+5210000243');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('R2T Mizrahi Resolve2', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx, a_papa);
  perform public.invite_member(v_ctx, a_abu);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  perform public.accept_invitation(v_ctx);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abu::text)::text, true);
  perform public.accept_invitation(v_ctx);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_palco := (public.create_resource(v_ctx, 'house', 'Palco Azteca R2T Resolve2'))->>'resource_id';
  perform public.grant_right(v_palco, v_ctx, 'MANAGE');
  perform public.grant_right(v_palco, a_papa, 'USE');
  perform public.grant_right(v_palco, a_abu, 'USE');

  v_event := (public.create_calendar_event(
    p_context_actor_id := v_ctx,
    p_title := 'México vs Brasil (resolve2)',
    p_event_type := 'community_event',
    p_starts_at := v_starts,
    p_ends_at := v_ends,
    p_invite_all_members := false))->>'event_id';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  v_resv1 := (public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_papa,
    p_source_event_id := v_event::uuid))->>'reservation_id';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abu::text)::text, true);
  v_resv2 := (public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_abu,
    p_source_event_id := v_event::uuid))->>'reservation_id';

  select id into v_conflict from public.reservation_conflicts
    where resource_id = v_palco and resolution_status = 'open'
      and (reservation_a_id = v_resv2::uuid or reservation_b_id = v_resv2::uuid)
    limit 1;
  if v_conflict is null then
    raise exception 'R2T smoke 5: no se produjo conflict para resolver';
  end if;

  -- Founder convoca decision para resolver.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_decision := (public.resolve_reservation_conflict(v_conflict, 'requires_decision'))->>'decision_id';

  -- Pick winning option desde payload (mismo patrón que R.2S contract smoke).
  select case when (payload->'option_reservations'->>'res_a')::uuid = v_resv1::uuid then 'res_a' else 'res_b' end
    into v_winner_opt
    from public.decisions where id = v_decision;

  -- Patrón R.2S contract: 2 votos sólo + execute_decision explícito.
  -- Una 3ra vota_decision raise 22023 ('decision is approved') tras auto-finalize.
  perform public.vote_decision(v_decision, 'approve', v_winner_opt);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  perform public.vote_decision(v_decision, 'approve', v_winner_opt);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.execute_decision(v_decision);

  select resolution_status into v_status
    from public.reservation_conflicts where id = v_conflict;
  if v_status <> 'resolved' then
    raise exception 'R2T smoke 5: conflict no quedó resolved, got %', v_status;
  end if;

  raise notice 'R2T smoke 5 OK: decision % resolvió conflict %', v_decision, v_conflict;
end; $$;

-- ============================================================================
-- GRANT EXECUTE (smokes son DEFINER; los corren tests/CI bajo service_role).
-- ============================================================================
revoke all on function public._smoke_r2t_event_without_reservation()       from public, anon;
revoke all on function public._smoke_r2t_reservation_without_event()       from public, anon;
revoke all on function public._smoke_r2t_event_with_reservations()         from public, anon;
revoke all on function public._smoke_r2t_reservation_conflict_world_cup()  from public, anon;
revoke all on function public._smoke_r2t_decision_resolves_conflict()      from public, anon;
grant execute on function public._smoke_r2t_event_without_reservation()       to service_role;
grant execute on function public._smoke_r2t_reservation_without_event()       to service_role;
grant execute on function public._smoke_r2t_event_with_reservations()         to service_role;
grant execute on function public._smoke_r2t_reservation_conflict_world_cup()  to service_role;
grant execute on function public._smoke_r2t_decision_resolves_conflict()      to service_role;
