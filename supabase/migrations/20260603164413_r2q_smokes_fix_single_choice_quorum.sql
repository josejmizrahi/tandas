-- R.2Q smoke fix: con 3 miembros mayoría = 2 votos. A y B votan David → cierra automáticamente.
-- C intenta votar después → error decision is approved (esperado).

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
  v_tally jsonb;
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

  if jsonb_array_length(public.list_decision_options(v_decision::uuid)) <> 0 then
    raise exception 'R2Q SC FAIL: no debieron auto-crearse opciones';
  end if;

  v_opt_david := (public.create_decision_option(v_decision::uuid, 'david', 'David'))->>'option_id';
  v_opt_isaac := (public.create_decision_option(v_decision::uuid, 'isaac', 'Isaac'))->>'option_id';
  if v_opt_david is null or v_opt_isaac is null then
    raise exception 'R2Q SC FAIL: create_decision_option falló';
  end if;
  if jsonb_array_length(public.list_decision_options(v_decision::uuid)) <> 2 then
    raise exception 'R2Q SC FAIL: list debió devolver 2';
  end if;

  -- Con 3 miembros, mayoría absoluta es 2. A vota david, B vota david → cierra.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  perform public.vote_for_option(v_decision::uuid, v_opt_david::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  v_result := public.vote_for_option(v_decision::uuid, v_opt_david::uuid);

  if v_result->>'status' <> 'approved' then
    raise exception 'R2Q SC FAIL: decisión no cerró approved (%)', v_result->>'status';
  end if;
  if (select result->>'winning_option' from public.decisions where id = v_decision::uuid) <> 'david' then
    raise exception 'R2Q SC FAIL: winner debió ser david';
  end if;
  if (select (result->>'winning_option_id')::uuid from public.decisions where id = v_decision::uuid) <> v_opt_david::uuid then
    raise exception 'R2Q SC FAIL: winning_option_id incorrecto';
  end if;

  v_tally := (select result->'option_tally' from public.decisions where id = v_decision::uuid);
  if (v_tally->>'david')::numeric <> 2 then
    raise exception 'R2Q SC FAIL: david debió tener 2, tiene %', v_tally->>'david';
  end if;

  -- C intenta votar despues — debe fallar porque ya cerró
  declare v_caught boolean := false; begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
    begin
      perform public.vote_for_option(v_decision::uuid, v_opt_isaac::uuid);
    exception when invalid_parameter_value then v_caught := true;
    end;
    if not v_caught then raise exception 'R2Q SC FAIL: voto después de cerrar no rechazado'; end if;
  end;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_a, a_b, a_c], array[u_a, u_b, u_c]);

  raise notice 'R.2Q single_choice: PASS';
end; $$;
