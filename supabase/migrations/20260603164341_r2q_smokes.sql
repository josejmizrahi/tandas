-- R.2Q smokes (6)
-- 1. backward_compatibility — decisión sin opciones → yes_no_abstain default + 3 auto-options
-- 2. yes_no_abstain — votar approve cierra como approved con winning_option_id
-- 3. single_choice — Casa Valle David vs Isaac con create_decision_option manual
-- 4. voting_model_not_implemented — ranked_choice/multiple_choice rechazan vote_decision
-- 5. execution_payload — winning_option.payload.action="reservation_award" ejecuta
-- 6. reservation_dispute_e2e — trigger auto-seedea 4 opciones desde conflict_id

CREATE OR REPLACE FUNCTION public._smoke_r2q_backward_compatibility()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
declare
  u_a uuid; a_a uuid;
  u_b uuid; a_b uuid;
  v_ctx uuid;
  v_code text;
  v_decision uuid;
  v_options jsonb;
  v_result jsonb;
begin
  select auth_id, actor_id into u_a, a_a from public._r2_make_person('R2Q-Back A', '+5210000200');
  select auth_id, actor_id into u_b, a_b from public._r2_make_person('R2Q-Back B', '+5210000201');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := (public.create_context('R2Q backward', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Crear decisión SIN opciones — debe defaultear a yes_no_abstain
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_decision := (public.create_decision(v_ctx::uuid, 'generic', 'Aprobar?'))->>'decision_id';

  if (select voting_model from public.decisions where id = v_decision::uuid) <> 'yes_no_abstain' then
    raise exception 'R2Q backward FAIL: voting_model default debió ser yes_no_abstain';
  end if;

  -- Trigger debió crear 3 opciones approve/reject/abstain
  v_options := public.list_decision_options(v_decision::uuid);
  if jsonb_array_length(v_options) <> 3 then
    raise exception 'R2Q backward FAIL: debió haber 3 opciones auto-creadas, hay %', jsonb_array_length(v_options);
  end if;
  if not exists (
    select 1 from public.decision_options
     where decision_id = v_decision::uuid and option_key in ('approve','reject','abstain')
     group by decision_id having count(distinct option_key) = 3
  ) then
    raise exception 'R2Q backward FAIL: faltan opciones approve/reject/abstain';
  end if;

  -- Votar con vote_decision (sin option) funciona como antes
  perform public.vote_decision(v_decision::uuid, 'approve');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  v_result := public.vote_decision(v_decision::uuid, 'approve');

  if v_result->>'status' <> 'approved' then
    raise exception 'R2Q backward FAIL: decision no cerró approved (%)', v_result->>'status';
  end if;
  if v_result->>'winning_option' <> 'approve' then
    raise exception 'R2Q backward FAIL: winning_option debió ser approve, fue %', v_result->>'winning_option';
  end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_a, a_b], array[u_a, u_b]);

  raise notice 'R.2Q backward_compatibility: PASS';
end; $$;

CREATE OR REPLACE FUNCTION public._smoke_r2q_yes_no_abstain()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
declare
  u_a uuid; a_a uuid;
  u_b uuid; a_b uuid;
  v_ctx uuid;
  v_code text;
  v_decision uuid;
  v_results jsonb;
  v_approve_opt_id uuid;
begin
  select auth_id, actor_id into u_a, a_a from public._r2_make_person('R2Q-YNA A', '+5210000210');
  select auth_id, actor_id into u_b, a_b from public._r2_make_person('R2Q-YNA B', '+5210000211');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := (public.create_context('R2Q YNA', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_decision := (public.create_decision(v_ctx::uuid, 'generic', 'Aprobar gasto X',
    p_voting_model := 'yes_no_abstain'))->>'decision_id';

  -- vote_for_option con la fila approve
  select id into v_approve_opt_id from public.decision_options
   where decision_id = v_decision::uuid and option_key = 'approve';
  if v_approve_opt_id is null then raise exception 'R2Q YNA FAIL: no se creó la opción approve'; end if;

  perform public.vote_for_option(v_decision::uuid, v_approve_opt_id);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.vote_for_option(v_decision::uuid, v_approve_opt_id);

  if (select status from public.decisions where id = v_decision::uuid) <> 'approved' then
    raise exception 'R2Q YNA FAIL: decisión no cerró approved';
  end if;
  if (select (result->>'winning_option_id')::uuid from public.decisions where id = v_decision::uuid) <> v_approve_opt_id then
    raise exception 'R2Q YNA FAIL: winning_option_id incorrecto';
  end if;

  -- decision_results contrato
  v_results := public.decision_results(v_decision::uuid);
  if v_results->'winner'->>'option_key' <> 'approve' then
    raise exception 'R2Q YNA FAIL: decision_results winner.option_key debió ser approve';
  end if;
  if jsonb_array_length(v_results->'options') <> 3 then
    raise exception 'R2Q YNA FAIL: decision_results.options debió tener 3 items';
  end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_a, a_b], array[u_a, u_b]);

  raise notice 'R.2Q yes_no_abstain: PASS';
end; $$;

CREATE OR REPLACE FUNCTION public._smoke_r2q_single_choice()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
declare
  u_a uuid; a_a uuid;
  u_b uuid; a_b uuid;
  u_c uuid; a_c uuid;
  v_ctx uuid;
  v_code text;
  v_decision uuid;
  v_opt_david uuid;
  v_opt_isaac uuid;
  v_result jsonb;
begin
  select auth_id, actor_id into u_a, a_a from public._r2_make_person('R2Q-SC A', '+5210000220');
  select auth_id, actor_id into u_b, a_b from public._r2_make_person('R2Q-SC B', '+5210000221');
  select auth_id, actor_id into u_c, a_c from public._r2_make_person('R2Q-SC C', '+5210000222');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := (public.create_context('R2Q SC', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_decision := (public.create_decision(v_ctx::uuid, 'generic', 'Quién se queda con la casa?',
    p_voting_model := 'single_choice'))->>'decision_id';

  -- No hay opciones auto-seedeadas (single_choice sin payload.options ni reservation_dispute)
  if jsonb_array_length(public.list_decision_options(v_decision::uuid)) <> 0 then
    raise exception 'R2Q SC FAIL: no debieron auto-crearse opciones';
  end if;

  -- Crear opciones manualmente
  v_opt_david := (public.create_decision_option(v_decision::uuid, 'david', 'David'))->>'option_id';
  v_opt_isaac := (public.create_decision_option(v_decision::uuid, 'isaac', 'Isaac'))->>'option_id';
  if v_opt_david is null or v_opt_isaac is null then
    raise exception 'R2Q SC FAIL: create_decision_option falló';
  end if;
  if jsonb_array_length(public.list_decision_options(v_decision::uuid)) <> 2 then
    raise exception 'R2Q SC FAIL: list debió devolver 2';
  end if;

  -- vota: 2-1 a favor de David
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  perform public.vote_for_option(v_decision::uuid, v_opt_david::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.vote_for_option(v_decision::uuid, v_opt_david::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
  v_result := public.vote_for_option(v_decision::uuid, v_opt_isaac::uuid);

  if v_result->>'status' <> 'approved' then
    raise exception 'R2Q SC FAIL: decisión no cerró approved (%)', v_result->>'status';
  end if;
  if (select result->>'winning_option' from public.decisions where id = v_decision::uuid) <> 'david' then
    raise exception 'R2Q SC FAIL: winner debió ser david, fue %', (select result->>'winning_option' from public.decisions where id = v_decision::uuid);
  end if;
  if (select (result->>'winning_option_id')::uuid from public.decisions where id = v_decision::uuid) <> v_opt_david::uuid then
    raise exception 'R2Q SC FAIL: winning_option_id incorrecto';
  end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_a, a_b, a_c], array[u_a, u_b, u_c]);

  raise notice 'R.2Q single_choice: PASS';
end; $$;

CREATE OR REPLACE FUNCTION public._smoke_r2q_voting_model_not_implemented()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
declare
  u_a uuid; a_a uuid;
  v_ctx uuid;
  v_decision uuid;
  v_caught boolean;
  v_model text;
begin
  select auth_id, actor_id into u_a, a_a from public._r2_make_person('R2Q-NI A', '+5210000230');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := (public.create_context('R2Q NI', 'collective', 'friend_group'))->>'context_actor_id';

  -- Cada modelo no implementado debe rechazar vote_decision con feature_not_supported
  foreach v_model in array array['multiple_choice','ranked_choice','approval_vote','numeric_allocation','consent'] loop
    v_decision := (public.create_decision(v_ctx::uuid, 'generic', 'Test ' || v_model,
      p_voting_model := v_model))->>'decision_id';

    -- crear una opción para que vote tenga algo a apuntar
    perform public.create_decision_option(v_decision::uuid, 'a', 'Opción A');

    v_caught := false;
    begin
      perform public.vote_decision(v_decision::uuid, 'approve', 'a');
    exception when feature_not_supported then v_caught := true;
    end;
    if not v_caught then
      raise exception 'R2Q NI FAIL: % no rechazó con feature_not_supported', v_model;
    end if;
  end loop;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_a], array[u_a]);

  raise notice 'R.2Q voting_model_not_implemented: PASS';
end; $$;

CREATE OR REPLACE FUNCTION public._smoke_r2q_execution_payload()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
declare
  u_a uuid; a_a uuid;
  u_b uuid; a_b uuid;
  v_ctx uuid;
  v_code text;
  v_casa uuid;
  v_res_a uuid;
  v_res_b uuid;
  v_conflict uuid;
  v_decision uuid;
  v_opt_award_a uuid;
  v_starts timestamptz := '2026-08-15 10:00-06'::timestamptz;
  v_ends timestamptz := '2026-08-17 10:00-06'::timestamptz;
  v_result jsonb;
begin
  select auth_id, actor_id into u_a, a_a from public._r2_make_person('R2Q-EP A', '+5210000240');
  select auth_id, actor_id into u_b, a_b from public._r2_make_person('R2Q-EP B', '+5210000241');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := (public.create_context('R2Q EP', 'collective', 'family'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_casa := (public.create_resource(v_ctx::uuid, 'house', 'Casa EP'))->>'resource_id';
  perform public.grant_right(v_casa, a_a, 'USE');
  perform public.grant_right(v_casa, a_b, 'USE');

  v_res_a := (public.request_resource_reservation(v_casa, v_ctx::uuid, v_starts, v_ends))->>'reservation_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  v_res_b := (public.request_resource_reservation(v_casa, v_ctx::uuid, v_starts, v_ends))->>'reservation_id';

  select id into v_conflict from public.reservation_conflicts
   where resource_id = v_casa and resolution_status = 'open';
  if v_conflict is null then raise exception 'R2Q EP FAIL: no se detectó conflicto'; end if;

  -- Crear decisión single_choice manual con payload.action en la opción ganadora
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_decision := (public.create_decision(v_ctx::uuid, 'reservation_dispute',
    'Resolver disputa EP', p_voting_model := 'single_choice'))->>'decision_id';

  -- Manual opt: award reservation A
  v_opt_award_a := (public.create_decision_option(
    v_decision::uuid, 'award_a', 'Dar a A',
    p_payload := jsonb_build_object(
      'action', 'reservation_award',
      'winner_reservation_id', v_res_a,
      'conflict_id', v_conflict
    )))->>'option_id';

  perform public.create_decision_option(
    v_decision::uuid, 'award_b', 'Dar a B',
    p_payload := jsonb_build_object(
      'action', 'reservation_award',
      'winner_reservation_id', v_res_b,
      'conflict_id', v_conflict
    ));

  -- A vota award_a, B vota award_a → close auto-finaliza
  perform public.vote_for_option(v_decision::uuid, v_opt_award_a::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  v_result := public.vote_for_option(v_decision::uuid, v_opt_award_a::uuid);

  if v_result->>'status' <> 'approved' then
    raise exception 'R2Q EP FAIL: no cerró approved (%)', v_result->>'status';
  end if;

  -- execute_decision debe dispatch por payload.action="reservation_award"
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_result := public.execute_decision(v_decision::uuid);
  if v_result->>'status' <> 'executed' then
    raise exception 'R2Q EP FAIL: execute_decision';
  end if;
  if (select status from public.resource_reservations where id = v_res_a) <> 'approved' then
    raise exception 'R2Q EP FAIL: res_a no quedó approved';
  end if;
  if (select status from public.resource_reservations where id = v_res_b) <> 'rejected' then
    raise exception 'R2Q EP FAIL: res_b no quedó rejected';
  end if;
  if (select resolution_status from public.reservation_conflicts where id = v_conflict) <> 'resolved' then
    raise exception 'R2Q EP FAIL: conflicto no resolved';
  end if;
  -- effects debe traer 3 items: conflict_resolved, reservation_approved, reservation_rejected
  if jsonb_array_length(v_result->'effects') <> 3 then
    raise exception 'R2Q EP FAIL: effects debió tener 3 items, tiene %', jsonb_array_length(v_result->'effects');
  end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_a, a_b], array[u_a, u_b]);

  raise notice 'R.2Q execution_payload: PASS';
end; $$;

CREATE OR REPLACE FUNCTION public._smoke_r2q_reservation_dispute_e2e()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
declare
  u_a uuid; a_a uuid;
  u_b uuid; a_b uuid;
  u_c uuid; a_c uuid;
  v_ctx uuid;
  v_code text;
  v_casa uuid;
  v_res_a uuid;
  v_res_b uuid;
  v_conflict uuid;
  v_decision uuid;
  v_options jsonb;
  v_opt_award_a uuid;
  v_starts timestamptz := '2026-09-10 10:00-06'::timestamptz;
  v_ends timestamptz := '2026-09-12 10:00-06'::timestamptz;
  v_result jsonb;
begin
  select auth_id, actor_id into u_a, a_a from public._r2_make_person('R2Q-RD A', '+5210000250');
  select auth_id, actor_id into u_b, a_b from public._r2_make_person('R2Q-RD B', '+5210000251');
  select auth_id, actor_id into u_c, a_c from public._r2_make_person('R2Q-RD C', '+5210000252');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := (public.create_context('R2Q RD', 'collective', 'family'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_casa := (public.create_resource(v_ctx::uuid, 'house', 'Casa RD'))->>'resource_id';
  perform public.grant_right(v_casa, a_a, 'USE');
  perform public.grant_right(v_casa, a_b, 'USE');
  perform public.grant_right(v_casa, a_c, 'USE');

  v_res_a := (public.request_resource_reservation(v_casa, v_ctx::uuid, v_starts, v_ends))->>'reservation_id';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  v_res_b := (public.request_resource_reservation(v_casa, v_ctx::uuid, v_starts, v_ends))->>'reservation_id';

  select id into v_conflict from public.reservation_conflicts
   where resource_id = v_casa and resolution_status = 'open';
  if v_conflict is null then raise exception 'R2Q RD FAIL: no conflict'; end if;

  -- iOS-style: crear decisión con payload.conflict_id (clave corta) y SIN payload.options
  -- create_decision detecta reservation_dispute + conflict_id → single_choice
  -- trigger auto-seedea 4 opciones (award_a, award_b, split, cancel)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_decision := (public.create_decision(v_ctx::uuid, 'reservation_dispute',
    '¿Cómo resolver el conflicto?',
    p_payload := jsonb_build_object('conflict_id', v_conflict)))->>'decision_id';

  if (select voting_model from public.decisions where id = v_decision::uuid) <> 'single_choice' then
    raise exception 'R2Q RD FAIL: voting_model debió ser single_choice';
  end if;

  v_options := public.list_decision_options(v_decision::uuid);
  if jsonb_array_length(v_options) <> 4 then
    raise exception 'R2Q RD FAIL: debió haber 4 opciones, hay %', jsonb_array_length(v_options);
  end if;

  if not exists (
    select 1 from public.decision_options
     where decision_id = v_decision::uuid
       and option_key in ('award_a','award_b','split','cancel')
     group by decision_id having count(distinct option_key) = 4
  ) then
    raise exception 'R2Q RD FAIL: faltan opciones award_a/award_b/split/cancel';
  end if;

  -- award_a debe tener payload.action="reservation_award" + winner_reservation_id=v_res_a
  if not exists (
    select 1 from public.decision_options
     where decision_id = v_decision::uuid and option_key = 'award_a'
       and payload->>'action' = 'reservation_award'
       and (payload->>'winner_reservation_id')::uuid = v_res_a
  ) then
    raise exception 'R2Q RD FAIL: award_a payload incorrecto';
  end if;

  select id into v_opt_award_a from public.decision_options
   where decision_id = v_decision::uuid and option_key = 'award_a';

  -- 2 votos para award_a (A y C) cierra approved con quorum (3 miembros, mayoría)
  perform public.vote_for_option(v_decision::uuid, v_opt_award_a);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
  v_result := public.vote_for_option(v_decision::uuid, v_opt_award_a);

  if v_result->>'status' <> 'approved' then
    raise exception 'R2Q RD FAIL: no cerró approved (%)', v_result->>'status';
  end if;

  -- execute → reservación A approved, B rejected, conflicto resolved
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_result := public.execute_decision(v_decision::uuid);
  if (select status from public.resource_reservations where id = v_res_a) <> 'approved' then
    raise exception 'R2Q RD FAIL: res_a no approved';
  end if;
  if (select status from public.resource_reservations where id = v_res_b) <> 'rejected' then
    raise exception 'R2Q RD FAIL: res_b no rejected';
  end if;
  if (select resolution_status from public.reservation_conflicts where id = v_conflict) <> 'resolved' then
    raise exception 'R2Q RD FAIL: conflicto no resolved';
  end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_a, a_b, a_c], array[u_a, u_b, u_c]);

  raise notice 'R.2Q reservation_dispute_e2e: PASS';
end; $$;

-- Master smoke que corre los 6
CREATE OR REPLACE FUNCTION public._smoke_r2q_all()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
begin
  perform public._smoke_r2q_backward_compatibility();
  perform public._smoke_r2q_yes_no_abstain();
  perform public._smoke_r2q_single_choice();
  perform public._smoke_r2q_voting_model_not_implemented();
  perform public._smoke_r2q_execution_payload();
  perform public._smoke_r2q_reservation_dispute_e2e();
  raise notice 'R.2Q ALL SMOKES PASS (6/6)';
end; $$;
