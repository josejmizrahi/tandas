-- R.2Q hizo evolucionar create_decision(uuid,text,text,text,timestamptz,jsonb,text) →
-- create_decision(uuid,text,text,text,timestamptz,jsonb,text,text). Actualizamos el smoke R.2G
-- para que el chequeo de anon-revoke apunte a la signature actual.

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
    'public.create_decision(uuid, text, text, text, timestamptz, jsonb, text, text)',
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
