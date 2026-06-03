CREATE OR REPLACE FUNCTION public._smoke_f1a2_context_settings_summary()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
declare
  u_admin uuid; a_admin uuid;
  u_member uuid; a_member uuid;
  u_out uuid; a_out uuid;
  v_ctx uuid;
  v_code text;
  v_result jsonb;
  v_actions text[];
  v_caught boolean;
begin
  select auth_id, actor_id into u_admin, a_admin from public._r2_make_person('F1A2 Admin', '+5210000400');
  select auth_id, actor_id into u_member, a_member from public._r2_make_person('F1A2 Member', '+5210000401');
  select auth_id, actor_id into u_out, a_out from public._r2_make_person('F1A2 Out', '+5210000402');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_admin::text)::text, true);
  v_ctx := (public.create_context('F1A2 Familia', 'collective', 'family'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_member::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_admin::text)::text, true);
  v_result := public.context_settings_summary(v_ctx::uuid);

  if v_result->>'context_actor_id' is null then raise exception 'F1A2 FAIL: sin context_actor_id'; end if;
  if v_result->'general' is null then raise exception 'F1A2 FAIL: sin general'; end if;
  if v_result->'general'->>'display_name' <> 'F1A2 Familia' then
    raise exception 'F1A2 FAIL: display_name incorrecto';
  end if;
  if (v_result->'general'->>'member_count')::int <> 2 then
    raise exception 'F1A2 FAIL: member_count debió ser 2, fue %', v_result->'general'->>'member_count';
  end if;
  if v_result->'decisions_config'->>'default_voting_model' <> 'yes_no_abstain' then
    raise exception 'F1A2 FAIL: default voting_model';
  end if;
  if v_result->'money_config'->>'currency' <> 'MXN' then
    raise exception 'F1A2 FAIL: default currency';
  end if;
  if v_result->'reservations_config'->>'priority_policy' <> 'least_recent_use_wins' then
    raise exception 'F1A2 FAIL: default priority_policy';
  end if;

  select array_agg(value) into v_actions
    from jsonb_array_elements_text(v_result->'available_actions');
  if not ('edit_general' = any(v_actions)) then
    raise exception 'F1A2 FAIL: admin no tiene edit_general (actions: %)', v_actions;
  end if;
  if not ('manage_members' = any(v_actions)) then
    raise exception 'F1A2 FAIL: admin no tiene manage_members';
  end if;
  if not ('view' = any(v_actions)) then
    raise exception 'F1A2 FAIL: admin no tiene view';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_member::text)::text, true);
  v_result := public.context_settings_summary(v_ctx::uuid);
  select array_agg(value) into v_actions
    from jsonb_array_elements_text(v_result->'available_actions');
  if 'edit_general' = any(v_actions) then
    raise exception 'F1A2 FAIL: member tiene edit_general (actions: %)', v_actions;
  end if;
  if not ('view' = any(v_actions)) then
    raise exception 'F1A2 FAIL: member no tiene view';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_caught := false;
  begin
    perform public.context_settings_summary(v_ctx::uuid);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'F1A2 FAIL: outsider no rechazado'; end if;

  if has_function_privilege('anon', 'public.context_settings_summary(uuid)', 'EXECUTE') then
    raise exception 'F1A2 FAIL: anon puede ejecutar';
  end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_admin, a_member, a_out], array[u_admin, u_member, u_out]);

  raise notice 'F.1A.2 context_settings_summary: PASS';
end; $$;
