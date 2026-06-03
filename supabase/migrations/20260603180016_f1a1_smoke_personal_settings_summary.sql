CREATE OR REPLACE FUNCTION public._smoke_f1a1_personal_settings_summary()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
declare
  u_a uuid; a_a uuid;
  v_result jsonb;
  v_actions jsonb;
  v_caught boolean;
begin
  -- Setup: una persona
  select auth_id, actor_id into u_a, a_a from public._r2_make_person('F1A1 User', '+5210000300');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_result := public.personal_settings_summary();

  -- shape check
  if v_result->>'actor_id' is null then raise exception 'F1A1 FAIL: sin actor_id'; end if;
  if v_result->'profile' is null then raise exception 'F1A1 FAIL: sin profile'; end if;
  if v_result->'notifications' is null then raise exception 'F1A1 FAIL: sin notifications'; end if;
  if v_result->'privacy' is null then raise exception 'F1A1 FAIL: sin privacy'; end if;
  if v_result->'calendar' is null then raise exception 'F1A1 FAIL: sin calendar'; end if;
  if v_result->'contexts' is null then raise exception 'F1A1 FAIL: sin contexts'; end if;
  if v_result->'integrations' is null then raise exception 'F1A1 FAIL: sin integrations'; end if;

  -- defaults: notifications.invitations.push = true
  if (v_result->'notifications'->'invitations'->>'push')::boolean <> true then
    raise exception 'F1A1 FAIL: default notifications.invitations.push debió ser true';
  end if;
  -- privacy defaults
  if v_result->'privacy'->>'discoverable_by' <> 'members_in_common' then
    raise exception 'F1A1 FAIL: default privacy.discoverable_by';
  end if;
  -- calendar defaults
  if v_result->'calendar'->>'time_zone' <> 'America/Mexico_City' then
    raise exception 'F1A1 FAIL: default time_zone';
  end if;

  -- available_actions = 6 acciones
  v_actions := v_result->'available_actions';
  if jsonb_array_length(v_actions) <> 6 then
    raise exception 'F1A1 FAIL: available_actions debe tener 6 items';
  end if;

  -- Persistir un cambio via update_my_profile + re-leer summary
  perform public.update_my_profile(
    p_metadata := jsonb_build_object(
      'notifications', jsonb_build_object('invitations', jsonb_build_object('push', false, 'email', true))
    )
  );
  v_result := public.personal_settings_summary();
  if (v_result->'notifications'->'invitations'->>'push')::boolean <> false then
    raise exception 'F1A1 FAIL: metadata.notifications no persiste';
  end if;
  -- otros slots mantienen default
  if (v_result->'notifications'->'decisions'->>'push')::boolean <> true then
    raise exception 'F1A1 FAIL: otros slots de notifications perdieron default';
  end if;

  -- Anon bloqueado
  if has_function_privilege('anon', 'public.personal_settings_summary()', 'EXECUTE') then
    raise exception 'F1A1 FAIL: anon puede ejecutar personal_settings_summary';
  end if;

  -- Sin auth → unauthenticated
  perform set_config('request.jwt.claims', null, true);
  v_caught := false;
  begin
    perform public.personal_settings_summary();
  exception when invalid_authorization_specification then v_caught := true;
  end;
  if not v_caught then raise exception 'F1A1 FAIL: sin auth no rechazó'; end if;

  -- Cleanup
  perform public._r2_cleanup_context(null::uuid, array[a_a], array[u_a]);

  raise notice 'F.1A.1 personal_settings_summary: PASS';
end; $$;
