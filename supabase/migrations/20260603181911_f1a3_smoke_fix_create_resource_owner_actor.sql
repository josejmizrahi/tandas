CREATE OR REPLACE FUNCTION public._smoke_f1a3_resource_settings_summary()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
declare
  u_owner uuid; a_owner uuid;
  u_user uuid; a_user uuid;
  u_view uuid; a_view uuid;
  u_out uuid; a_out uuid;
  v_ctx uuid;
  v_code text;
  v_casa uuid;
  v_result jsonb;
  v_actions text[];
  v_caps text[];
  v_caught boolean;
begin
  select auth_id, actor_id into u_owner, a_owner from public._r2_make_person('F1A3 Owner', '+5210000500');
  select auth_id, actor_id into u_user, a_user from public._r2_make_person('F1A3 User', '+5210000501');
  select auth_id, actor_id into u_view, a_view from public._r2_make_person('F1A3 Viewer', '+5210000502');
  select auth_id, actor_id into u_out, a_out from public._r2_make_person('F1A3 Out', '+5210000503');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner::text)::text, true);
  v_ctx := (public.create_context('F1A3 Casa Ctx', 'collective', 'family'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_user::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_view::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner::text)::text, true);
  -- Crear el recurso a nombre del PERSONA actor del owner (OWN se auto-asigna)
  v_casa := (public.create_resource(a_owner, 'house', 'F1A3 Casa'))->>'resource_id';
  perform public.grant_right(v_casa, v_ctx::uuid, 'GOVERN');
  perform public.grant_right(v_casa, a_user, 'USE');
  perform public.grant_right(v_casa, a_view, 'VIEW');

  v_result := public.resource_settings_summary(v_casa);
  if v_result->>'resource_id' is null then raise exception 'F1A3 FAIL: sin resource_id'; end if;
  if v_result->'general'->>'display_name' <> 'F1A3 Casa' then raise exception 'F1A3 FAIL: nombre'; end if;
  if v_result->'general'->>'resource_type' <> 'house' then raise exception 'F1A3 FAIL: type'; end if;
  if v_result->'policies' is null then raise exception 'F1A3 FAIL: sin policies'; end if;

  select array_agg(value) into v_caps from jsonb_array_elements_text(v_result->'capabilities');
  if not ('reservable' = any(v_caps)) then
    raise exception 'F1A3 FAIL: house no expone reservable (caps: %)', v_caps;
  end if;
  if not ('ownership_trackable' = any(v_caps)) then
    raise exception 'F1A3 FAIL: house no expone ownership_trackable';
  end if;

  select array_agg(value) into v_actions from jsonb_array_elements_text(v_result->'available_actions');
  if not ('edit_general' = any(v_actions)) then
    raise exception 'F1A3 FAIL: owner sin edit_general (actions: %)', v_actions;
  end if;
  if not ('transfer_ownership' = any(v_actions)) then
    raise exception 'F1A3 FAIL: owner sin transfer_ownership';
  end if;

  -- USE: no debe poder
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_user::text)::text, true);
  v_caught := false;
  begin
    perform public.resource_settings_summary(v_casa);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'F1A3 FAIL: USE pudo ver settings'; end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_view::text)::text, true);
  v_caught := false;
  begin
    perform public.resource_settings_summary(v_casa);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'F1A3 FAIL: VIEW pudo ver settings'; end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_out::text)::text, true);
  v_caught := false;
  begin
    perform public.resource_settings_summary(v_casa);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'F1A3 FAIL: outsider pudo ver settings'; end if;

  -- MANAGE puede ver pero NO transfer_ownership
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_owner::text)::text, true);
  perform public.grant_right(v_casa, a_user, 'MANAGE');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_user::text)::text, true);
  v_result := public.resource_settings_summary(v_casa);
  select array_agg(value) into v_actions from jsonb_array_elements_text(v_result->'available_actions');
  if not ('edit_general' = any(v_actions)) then
    raise exception 'F1A3 FAIL: MANAGE sin edit_general';
  end if;
  if 'transfer_ownership' = any(v_actions) then
    raise exception 'F1A3 FAIL: MANAGE tiene transfer_ownership (actions: %)', v_actions;
  end if;

  if has_function_privilege('anon', 'public.resource_settings_summary(uuid)', 'EXECUTE') then
    raise exception 'F1A3 FAIL: anon puede ejecutar';
  end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_owner, a_user, a_view, a_out], array[u_owner, u_user, u_view, u_out]);

  raise notice 'F.1A.3 resource_settings_summary: PASS';
end; $$;