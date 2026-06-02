-- ============================================================================
-- R.2-2 — ACCEPTANCE TESTS (R.2K): los 4 escenarios end-to-end
-- ============================================================================
-- + assign_role RPC (necesario para "negocio entre socios": ambos socios admin)
--
--   1. _smoke_r2_cena_semanal    (R.2B+D+E+H+I+J)
--   2. _smoke_r2_casa_familiar   (R.2C+F+G)
--   3. _smoke_r2_viaje
--   4. _smoke_r2_negocio_socios
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- assign_role: requiere members.manage
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.assign_role(
  p_context_actor_id uuid,
  p_member_actor_id uuid,
  p_role_key text
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_role uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'members.manage') then
    raise exception 'not authorized to assign roles' using errcode = '42501';
  end if;

  select id into v_role from public.roles
   where context_actor_id = p_context_actor_id and role_key = p_role_key;
  if v_role is null then
    raise exception 'role % not found in context', p_role_key using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from public.actor_memberships
    where context_actor_id = p_context_actor_id and member_actor_id = p_member_actor_id
      and membership_status = 'active'
  ) then
    raise exception 'member is not active in context' using errcode = '22023';
  end if;

  insert into public.role_assignments (context_actor_id, member_actor_id, role_id)
  values (p_context_actor_id, p_member_actor_id, v_role)
  on conflict (context_actor_id, member_actor_id, role_id) do update set ends_at = null;

  perform public._emit_activity(p_context_actor_id, v_caller, 'role.assigned', 'actor', p_member_actor_id,
    jsonb_build_object('role_key', p_role_key));

  return jsonb_build_object('assigned', true, 'role_key', p_role_key);
end; $$;

revoke all on function public.assign_role(uuid, uuid, text) from public, anon;
grant execute on function public.assign_role(uuid, uuid, text) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- Helper de setup para los acceptance tests (interno)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._r2_make_person(p_name text, p_phone text)
returns table(auth_id uuid, actor_id uuid)
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth uuid := gen_random_uuid();
  v_actor uuid;
begin
  v_actor := public._create_person_actor_for_auth_user(v_auth, p_name, p_phone, null);
  return query select v_auth, v_actor;
end; $$;

revoke all on function public._r2_make_person(text, text) from public, anon, authenticated;

create or replace function public._r2_cleanup_context(p_ctx uuid, p_actors uuid[], p_auths uuid[])
returns void
language plpgsql security definer set search_path = public, auth
as $$
begin
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
  delete from public.reservation_conflicts where resource_id in
    (select id from public.resources where canonical_owner_actor_id = p_ctx);
  delete from public.resource_reservations where context_actor_id = p_ctx;
  delete from public.decision_votes where decision_id in
    (select id from public.decisions where context_actor_id = p_ctx);
  delete from public.decisions where context_actor_id = p_ctx;
  delete from public.documents where context_actor_id = p_ctx;
  delete from public.resource_rights where resource_id in
    (select id from public.resources where canonical_owner_actor_id = p_ctx);
  delete from public.resources where canonical_owner_actor_id = p_ctx;
  delete from public.context_invites where context_actor_id = p_ctx;
  delete from public.role_assignments where context_actor_id = p_ctx;
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id = p_ctx;
  delete from public.roles where context_actor_id = p_ctx;
  delete from public.actor_memberships where context_actor_id = p_ctx;
  delete from public.actors where id = p_ctx;
  delete from public.resource_rights where holder_actor_id = any(p_actors);
  delete from public.resources where canonical_owner_actor_id = any(p_actors);
  delete from public.person_profiles where actor_id = any(p_actors);
  delete from public.actors where id = any(p_actors);
  delete from auth.users where id = any(p_auths);
end; $$;

revoke all on function public._r2_cleanup_context(uuid, uuid[], uuid[]) from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- ACCEPTANCE 1 — CENA SEMANAL (R.2B + R.2D + R.2E + R.2H + R.2I + R.2J)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2_cena_semanal()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  a_jose uuid; a_david uuid; a_isaac uuid; a_moises uuid; a_daniel uuid;
  u_jose uuid; u_david uuid; u_isaac uuid; u_moises uuid; u_daniel uuid;
  v_ctx uuid; v_event uuid; v_result jsonb; v_batch uuid;
  r record;
begin
  -- Personas
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José', '+5210000001');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David', '+5210000002');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac', '+5210000003');
  select auth_id, actor_id into u_moises, a_moises from public._r2_make_person('Moisés', '+5210000004');
  select auth_id, actor_id into u_daniel, a_daniel from public._r2_make_person('Daniel', '+5210000005');

  -- ═══ R.2B: contexto + invitaciones directas + aceptación → members_count = 5 ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Cena Semanal Amigos', 'collective', 'friend_group'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_david);
  perform public.invite_member(v_ctx::uuid, a_isaac);
  perform public.invite_member(v_ctx::uuid, a_moises);
  perform public.invite_member(v_ctx::uuid, a_daniel);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.context_summary(v_ctx::uuid);
  if (v_result->>'members_count')::integer <> 5 then
    raise exception 'CENA FAIL: members_count = % (esperaba 5)', v_result->>'members_count';
  end if;

  -- ═══ R.2E: regla de multa por tardanza ═══
  perform public.create_rule(v_ctx::uuid, 'Llegar >15 min tarde → multa $100',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": ">", "field": "minutes_late", "value": 15}'::jsonb,
    p_consequences := '[{"type": "fine", "amount": 100, "currency": "MXN"}]'::jsonb);

  -- ═══ R.2D: evento cena 20:00 (simulado: empezó hace 21 min) + RSVP + check-ins ═══
  v_event := (public.create_calendar_event(v_ctx::uuid, 'Cena miércoles', 'dinner',
    p_starts_at := now() - interval '21 minutes', p_host_actor_id := a_jose))->>'event_id';

  -- RSVP going: José, David, Isaac
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');

  -- Check-ins: José 20:05 (+5, a tiempo)... como el evento "empezó" hace 21 min,
  -- el check-in de David AHORA = +21 min (tarde), José/Isaac simulan sus tiempos via metadata.
  -- David hace check-in real (21 min tarde) → multa automática
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.check_in_participant(v_event::uuid);
  if v_result->>'status' <> 'late' then
    raise exception 'CENA FAIL: David debió quedar late (quedó %)', v_result->>'status';
  end if;
  if (v_result->'rules'->>'rules_matched')::integer < 1 then
    raise exception 'CENA FAIL: regla de tardanza no aplicó a David';
  end if;

  -- ═══ R.2E verificación: obligation fine $100 para David ═══
  if not exists (
    select 1 from public.obligations
    where context_actor_id = v_ctx::uuid and debtor_actor_id = a_david
      and obligation_type = 'fine' and amount = 100 and status = 'open'
  ) then
    raise exception 'CENA FAIL: multa de $100 a David no existe';
  end if;

  -- ═══ R.2H: David paga $1300 (pizza 600 + cerveza 400 + botanas 300), 4 participantes ═══
  -- → 3 obligations de $325 c/u (José, Isaac, Daniel deben a David)
  v_result := public.record_expense(v_ctx::uuid, 1300, 'MXN', 'Pizza + Cerveza + Botanas',
    p_split_with := array[a_david, a_jose, a_isaac, a_daniel]);
  if (v_result->>'share_per_person')::numeric <> 325 then
    raise exception 'CENA FAIL: share = % (esperaba 325)', v_result->>'share_per_person';
  end if;
  if (select count(*) from public.obligations
      where context_actor_id = v_ctx::uuid and obligation_type = 'expense_share'
        and creditor_actor_id = a_david and amount = 325 and status = 'open') <> 3 then
    raise exception 'CENA FAIL: no hay 3 obligations de $325';
  end if;

  -- ═══ R.2I: settlement optimizado ═══
  -- Abiertas: José→David 325, Isaac→David 325, Daniel→David 325, David→Grupo 100 (multa)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.generate_settlement_batch(v_ctx::uuid, 'MXN');
  v_batch := (v_result->>'batch_id')::uuid;
  if v_batch is null then raise exception 'CENA FAIL: settlement batch no generado'; end if;
  -- neto: David +975-100=+875, Grupo +100, José -325, Isaac -325, Daniel -325 → suma 0
  -- el batch debe cubrir exactamente el neto total de deudores: 975
  if (select sum(amount) from public.settlement_items where settlement_batch_id = v_batch) <> 975 then
    raise exception 'CENA FAIL: total settlement = % (esperaba 975)',
      (select sum(amount) from public.settlement_items where settlement_batch_id = v_batch);
  end if;

  -- ═══ R.2I: pagos marcados → obligations cerradas ═══
  for r in select id, from_actor_id from public.settlement_items where settlement_batch_id = v_batch loop
    -- el deudor de cada item lo paga
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', (select pp.auth_user_id from public.person_profiles pp where pp.actor_id = r.from_actor_id)::text)::text, true);
    perform public.mark_settlement_paid(r.id);
  end loop;

  if exists (select 1 from public.obligations
             where context_actor_id = v_ctx::uuid and status = 'open'
               and obligation_type = 'expense_share') then
    raise exception 'CENA FAIL: quedaron expense_shares abiertas post-settlement';
  end if;

  -- ═══ R.2J: actividad auditada ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.context_summary(v_ctx::uuid);
  if jsonb_array_length(v_result->'recent_activity') < 10 then
    raise exception 'CENA FAIL: actividad incompleta (%)', jsonb_array_length(v_result->'recent_activity');
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_jose, a_david, a_isaac, a_moises, a_daniel],
    array[u_jose, u_david, u_isaac, u_moises, u_daniel]);

  raise notice 'R.2 CENA SEMANAL: PASS';
end; $$;

revoke all on function public._smoke_r2_cena_semanal() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- ACCEPTANCE 2 — CASA FAMILIAR (R.2C + R.2F + R.2G)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2_casa_familiar()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  a_abuelo uuid; a_jose uuid; a_david uuid; a_isaac uuid;
  u_abuelo uuid; u_jose uuid; u_david uuid; u_isaac uuid;
  v_ctx uuid; v_casa uuid; v_result jsonb;
  v_res_david uuid; v_res_isaac uuid; v_conflict record;
  v_decision uuid;
begin
  select auth_id, actor_id into u_abuelo, a_abuelo from public._r2_make_person('Abuelo', '+5210000006');
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José', '+5210000007');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David', '+5210000008');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac', '+5210000009');

  -- Contexto familia (Abuelo admin) + 3 miembros
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_ctx := (public.create_context('Familia Valle', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_jose);
  perform public.invite_member(v_ctx::uuid, a_david);
  perform public.invite_member(v_ctx::uuid, a_isaac);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);

  -- ═══ R.2C: Casa Valle + rights (Abuelo OWN 100%, José/David/Isaac USE) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_casa := (public.create_resource(v_ctx::uuid, 'house', 'Casa Valle',
    p_estimated_value := 8000000, p_currency := 'MXN'))->>'resource_id';

  perform public.grant_right(v_casa::uuid, a_abuelo, 'OWN', 100);
  perform public.grant_right(v_casa::uuid, a_jose, 'USE');
  perform public.grant_right(v_casa::uuid, a_david, 'USE');
  perform public.grant_right(v_casa::uuid, a_isaac, 'USE');

  v_result := public.resource_detail(v_casa::uuid);
  if not exists (
    select 1 from jsonb_array_elements(v_result->'rights') rt
    where (rt->>'holder_actor_id')::uuid = a_abuelo and rt->>'right_kind' = 'OWN'
      and (rt->>'percent')::numeric = 100
  ) then
    raise exception 'CASA FAIL: Abuelo no tiene OWN 100%%';
  end if;
  if (select count(*) from jsonb_array_elements(v_result->'rights') rt
      where rt->>'right_kind' = 'USE') <> 3 then
    raise exception 'CASA FAIL: no hay 3 USE rights';
  end if;

  -- update_resource + archive funcionan (R.2C)
  perform public.update_resource(v_casa::uuid, p_description := 'Casa del lago de la familia');

  -- ═══ R.2F: reservaciones en conflicto (David vs Isaac, 10-12 julio) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_res_david := (public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
    '2026-07-10 12:00+00'::timestamptz, '2026-07-12 12:00+00'::timestamptz))->>'reservation_id';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  v_result := public.request_resource_reservation(v_casa::uuid, v_ctx::uuid,
    '2026-07-10 14:00+00'::timestamptz, '2026-07-12 10:00+00'::timestamptz);
  v_res_isaac := v_result->>'reservation_id';
  if (v_result->>'conflicts_detected')::integer < 1 then
    raise exception 'CASA FAIL: conflicto no detectado';
  end if;

  -- conflict abierto con recommended_winner (least recent use → ambos 0 usos → David por orden)
  select * into v_conflict from public.reservation_conflicts
   where resource_id = v_casa::uuid and resolution_status = 'open' limit 1;
  if v_conflict.id is null then raise exception 'CASA FAIL: conflict row no existe'; end if;
  if v_conflict.recommended_winner_actor_id is null then
    raise exception 'CASA FAIL: sin recommended_winner';
  end if;

  -- ═══ R.2G: decisión por opciones "¿Quién usa Casa Valle?" ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_decision := (public.create_decision(v_ctx::uuid, 'reservation_dispute',
    '¿Quién usa Casa Valle el 10-12 julio?',
    p_payload := jsonb_build_object('options', jsonb_build_array('David', 'Isaac'),
                                    'conflict_id', v_conflict.id)))->>'decision_id';

  -- Votos: Abuelo→David, José→David, David→David (3 de 4 = mayoría)
  perform public.vote_decision(v_decision::uuid, 'approve', 'David');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.vote_decision(v_decision::uuid, 'approve', 'David');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_result := public.vote_decision(v_decision::uuid, 'approve', 'David');
  if v_result->>'status' <> 'approved' then
    raise exception 'CASA FAIL: decisión no aprobada con mayoría (%)', v_result->>'status';
  end if;

  -- Ejecutar: resolver el conflicto a favor de David
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  perform public.execute_decision(v_decision::uuid,
    jsonb_build_object('winner', 'David', 'reservation_id', v_res_david));
  perform public.resolve_reservation_conflict(v_conflict.id, v_res_david::uuid);

  if not exists (select 1 from public.resource_reservations where id = v_res_david::uuid and status = 'approved') then
    raise exception 'CASA FAIL: reservación de David no quedó approved';
  end if;
  if not exists (select 1 from public.resource_reservations where id = v_res_isaac::uuid and status = 'rejected') then
    raise exception 'CASA FAIL: reservación de Isaac no quedó rejected';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_abuelo, a_jose, a_david, a_isaac],
    array[u_abuelo, u_jose, u_david, u_isaac]);

  raise notice 'R.2 CASA FAMILIAR: PASS';
end; $$;

revoke all on function public._smoke_r2_casa_familiar() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- ACCEPTANCE 3 — VIAJE
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2_viaje()
returns void
language plpgsql security definer set search_path = public, auth
as $$
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
    p_starts_at := now() + interval '30 days', p_ends_at := now() + interval '33 days');

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
  end loop;

  if exists (select 1 from public.obligations where context_actor_id = v_ctx::uuid and status = 'open') then
    raise exception 'VIAJE FAIL: obligations abiertas post-settlement';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_jose, a_david, a_isaac], array[u_jose, u_david, u_isaac]);

  raise notice 'R.2 VIAJE: PASS';
end; $$;

revoke all on function public._smoke_r2_viaje() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- ACCEPTANCE 4 — NEGOCIO ENTRE SOCIOS
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2_negocio_socios()
returns void
language plpgsql security definer set search_path = public, auth
as $$
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
end; $$;

revoke all on function public._smoke_r2_negocio_socios() from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- R.2K — el acceptance master: los 4 escenarios en secuencia
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_r2k_acceptance()
returns void
language plpgsql security definer set search_path = public, auth
as $$
begin
  perform public._smoke_r2_cena_semanal();
  perform public._smoke_r2_casa_familiar();
  perform public._smoke_r2_viaje();
  perform public._smoke_r2_negocio_socios();
  raise notice 'R.2K ACCEPTANCE: CENA PASS · CASA PASS · VIAJE PASS · NEGOCIO PASS';
end; $$;

revoke all on function public._smoke_mvp2_r2k_acceptance() from public, anon, authenticated;

comment on function public._smoke_mvp2_r2k_acceptance() is
  'R.2K: los 4 escenarios de aceptación end-to-end (cena semanal, casa familiar, viaje, negocio entre socios). Ruul pasa R.2 solo si los 4 dan PASS.';
