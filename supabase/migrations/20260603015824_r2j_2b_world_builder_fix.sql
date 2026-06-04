-- R.2J-2b — fix del world builder: los recursos de la Familia se crean EN el
-- contexto (la activity resource.*/right.* queda en la Familia, no en el actor
-- personal del Abuelo). Reemplaza solo _r2j_make_world.
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
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2J', '+5210000100');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David R2J', '+5210000101');
  select auth_id, actor_id into u_isaac, a_isaac from public._r2_make_person('Isaac R2J', '+5210000102');
  select auth_id, actor_id into u_moises, a_moises from public._r2_make_person('Moisés R2J', '+5210000103');
  select auth_id, actor_id into u_daniel, a_daniel from public._r2_make_person('Daniel R2J', '+5210000104');
  select auth_id, actor_id into u_abuelo, a_abuelo from public._r2_make_person('Abuelo R2J', '+5210000105');
  select auth_id, actor_id into u_out, a_out from public._r2_make_person('Outsider R2J', '+5210000106');

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
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_viaje := (public.create_context('Viaje Japón', 'collective', 'trip'))->>'context_actor_id';
  v_code := (public.create_invite(v_viaje::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.join_by_invite_code(v_code);

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

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_negocio := (public.create_context('Negocio Valle', 'collective', 'company'))->>'context_actor_id';
  v_code := (public.create_invite(v_negocio::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.join_by_invite_code(v_code);

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

  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_isaac::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_daniel::text)::text, true);
  perform public.rsvp_event(v_event::uuid, 'going');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.check_in_participant(v_event::uuid, p_checked_in_at := v_starts);
  perform public.check_in_participant(v_event::uuid, a_jose, v_starts + interval '5 minutes');
  perform public.check_in_participant(v_event::uuid, a_isaac, v_starts + interval '12 minutes');
  perform public.cancel_participation(v_event::uuid, a_daniel, v_starts);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.check_in_participant(v_event::uuid);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.record_expense(v_cena::uuid, 1300, 'MXN', 'Pizza, cerveza y botanas',
    p_split_with := array[a_david, a_jose, a_isaac, a_moises],
    p_event_id := v_event::uuid, p_client_id := 'r2j-cena-expense-001',
    p_excluded_actor_ids := array[a_daniel]);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_moises::text)::text, true);
  perform public.record_game_result(v_cena::uuid, v_event::uuid, 'Catan', a_moises, a_daniel, 250, 'MXN', 'r2j-catan-001');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.register_document('Recibo de la cena', p_context_actor_id := v_cena::uuid);

  v_batch := (public.generate_settlement_batch(v_cena::uuid, 'MXN'))->>'batch_id';
  for v_item in select id from public.settlement_items
                 where settlement_batch_id = v_batch::uuid and status = 'pending' loop
    perform public.mark_settlement_paid(v_item.id);
  end loop;

  perform public.remove_member(v_cena::uuid, a_out, 'salida del grupo');

  -- ═══ FAMILIA: recursos EN el contexto + rights + reservaciones ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abuelo::text)::text, true);
  v_casa := (public.create_resource(v_familia::uuid, 'house', 'Casa Valle'))->>'resource_id';
  v_terreno := (public.create_resource(v_familia::uuid, 'property', 'Terreno Valle'))->>'resource_id';
  perform public.grant_right(v_casa::uuid, a_david, 'USE');
  perform public.grant_right(v_casa::uuid, a_isaac, 'USE');
  v_right_moises := (public.grant_right(v_casa::uuid, a_moises, 'USE'))->>'right_id';
  perform public.revoke_right(v_right_moises::uuid);

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
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  v_res_extra := (public.request_resource_reservation(v_casa::uuid, v_familia::uuid,
    '2026-07-17 16:00-06'::timestamptz, '2026-07-19 18:00-06'::timestamptz))->>'reservation_id';
  perform public.cancel_reservation(v_res_extra::uuid);

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