-- R.2Q smoke fix: reservation_a_id en reservation_conflicts es least(...), no asume v_res_a.
-- Cargamos el orden real del conflict para validar award_a/award_b payloads.

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
  v_conf_a uuid;
  v_conf_b uuid;
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

  select id, reservation_a_id, reservation_b_id into v_conflict, v_conf_a, v_conf_b
    from public.reservation_conflicts
   where resource_id = v_casa and resolution_status = 'open';
  if v_conflict is null then raise exception 'R2Q RD FAIL: no conflict'; end if;

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

  -- award_a apunta a la reservación A del conflicto (no necesariamente v_res_a)
  if not exists (
    select 1 from public.decision_options
     where decision_id = v_decision::uuid and option_key = 'award_a'
       and payload->>'action' = 'reservation_award'
       and (payload->>'winner_reservation_id')::uuid = v_conf_a
  ) then
    raise exception 'R2Q RD FAIL: award_a payload incorrecto';
  end if;
  if not exists (
    select 1 from public.decision_options
     where decision_id = v_decision::uuid and option_key = 'award_b'
       and (payload->>'winner_reservation_id')::uuid = v_conf_b
  ) then
    raise exception 'R2Q RD FAIL: award_b payload incorrecto';
  end if;

  select id into v_opt_award_a from public.decision_options
   where decision_id = v_decision::uuid and option_key = 'award_a';

  -- Mayoría 3 miembros = 2 votos. A y C votan award_a → cierra.
  perform public.vote_for_option(v_decision::uuid, v_opt_award_a);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
  v_result := public.vote_for_option(v_decision::uuid, v_opt_award_a);

  if v_result->>'status' <> 'approved' then
    raise exception 'R2Q RD FAIL: no cerró approved (%)', v_result->>'status';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_result := public.execute_decision(v_decision::uuid);
  -- conf_a quedó approved, conf_b rejected
  if (select status from public.resource_reservations where id = v_conf_a) <> 'approved' then
    raise exception 'R2Q RD FAIL: conf_a no approved';
  end if;
  if (select status from public.resource_reservations where id = v_conf_b) <> 'rejected' then
    raise exception 'R2Q RD FAIL: conf_b no rejected';
  end if;
  if (select resolution_status from public.reservation_conflicts where id = v_conflict) <> 'resolved' then
    raise exception 'R2Q RD FAIL: conflicto no resolved';
  end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_a, a_b, a_c], array[u_a, u_b, u_c]);

  raise notice 'R.2Q reservation_dispute_e2e: PASS';
end; $$;
