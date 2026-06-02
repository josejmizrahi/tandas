-- R.0E.1 MIG 2 — Smoke for actor_net_worth (8 casos)

CREATE OR REPLACE FUNCTION public._smoke_r0e1_actor_net_worth()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_group        uuid;
  v_user         uuid;
  v_user2        uuid;
  v_res_mxn      uuid;
  v_res_usd      uuid;
  v_res_use      uuid;
  v_res_revoked  uuid;
  v_res_archived uuid;
  v_res_benef    uuid;
  v_result       jsonb;
  v_owned        jsonb;
  v_benef        jsonb;
  v_caught       boolean;
BEGIN
  SELECT id INTO v_group FROM public.groups LIMIT 1;
  SELECT id INTO v_user  FROM public.actors WHERE actor_kind='person' LIMIT 1;
  SELECT id INTO v_user2 FROM public.actors WHERE actor_kind='person' AND id <> v_user LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', v_user::text)::text, true);

  -- Caso 1: empty/baseline structure
  v_result := public.actor_net_worth(v_user);
  IF v_result IS NULL OR jsonb_typeof(v_result->'owned_by_currency') != 'array' THEN
    RAISE EXCEPTION '_smoke_r0e1 Caso1: bad structure';
  END IF;

  -- Setup test resources
  INSERT INTO public.resources (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
  VALUES (v_group, 'asset', '_smoke_r0e1 MXN res', 'active', 'members', 'group', '{}'::jsonb,
          '{"estimated_value": 1000, "currency": "MXN"}'::jsonb, v_user)
  RETURNING id INTO v_res_mxn;

  INSERT INTO public.resources (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
  VALUES (v_group, 'asset', '_smoke_r0e1 USD res', 'active', 'members', 'group', '{}'::jsonb,
          '{"estimated_value": 500, "currency": "USD"}'::jsonb, v_user)
  RETURNING id INTO v_res_usd;

  INSERT INTO public.resources (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
  VALUES (v_group, 'asset', '_smoke_r0e1 USE-only', 'active', 'members', 'group', '{}'::jsonb,
          '{"estimated_value": 9999, "currency": "MXN"}'::jsonb, v_user)
  RETURNING id INTO v_res_use;

  INSERT INTO public.resources (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
  VALUES (v_group, 'asset', '_smoke_r0e1 revoked-OWN', 'active', 'members', 'group', '{}'::jsonb,
          '{"estimated_value": 7777, "currency": "MXN"}'::jsonb, v_user)
  RETURNING id INTO v_res_revoked;

  INSERT INTO public.resources (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
  VALUES (v_group, 'asset', '_smoke_r0e1 archived', 'active', 'members', 'group', '{}'::jsonb,
          '{"estimated_value": 6666, "currency": "MXN"}'::jsonb, v_user)
  RETURNING id INTO v_res_archived;

  INSERT INTO public.resources (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
  VALUES (v_group, 'asset', '_smoke_r0e1 beneficiary', 'active', 'members', 'group', '{}'::jsonb,
          '{"estimated_value": 200, "currency": "MXN"}'::jsonb, v_user)
  RETURNING id INTO v_res_benef;

  -- Use v_user2 as clean slate actor
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', v_user2::text)::text, true);

  -- Grant rights
  PERFORM public.grant_right(p_resource_id := v_res_mxn, p_holder_actor_id := v_user2, p_right_kind := 'OWN', p_percent := 100);
  PERFORM public.grant_right(p_resource_id := v_res_usd, p_holder_actor_id := v_user2, p_right_kind := 'OWN', p_percent := 50);
  PERFORM public.grant_right(p_resource_id := v_res_use, p_holder_actor_id := v_user2, p_right_kind := 'USE');

  DECLARE v_revoked_id uuid;
  BEGIN
    v_revoked_id := public.grant_right(p_resource_id := v_res_revoked, p_holder_actor_id := v_user2, p_right_kind := 'OWN', p_percent := 100);
    PERFORM public.revoke_right(p_right_id := v_revoked_id);
  END;

  PERFORM public.grant_right(p_resource_id := v_res_archived, p_holder_actor_id := v_user2, p_right_kind := 'OWN', p_percent := 100);
  UPDATE public.resources SET archived_at = now() WHERE id = v_res_archived;

  PERFORM public.grant_right(p_resource_id := v_res_benef, p_holder_actor_id := v_user2, p_right_kind := 'BENEFICIARY', p_percent := 100);

  -- Compute
  v_result := public.actor_net_worth(v_user2);
  v_owned := v_result->'owned_by_currency';
  v_benef := v_result->'beneficiary_by_currency';

  -- Caso 2 + 3: 2 currencies (MXN 1000, USD 250)
  IF jsonb_array_length(v_owned) != 2 THEN
    RAISE EXCEPTION '_smoke_r0e1 Caso2/4: expected 2 currency entries, got %', jsonb_array_length(v_owned);
  END IF;

  IF (SELECT (e->>'owned_value')::numeric FROM jsonb_array_elements(v_owned) e WHERE e->>'currency'='MXN') != 1000 THEN
    RAISE EXCEPTION '_smoke_r0e1 Caso2: MXN owned_value != 1000';
  END IF;
  IF (SELECT (e->>'owned_value')::numeric FROM jsonb_array_elements(v_owned) e WHERE e->>'currency'='USD') != 250 THEN
    RAISE EXCEPTION '_smoke_r0e1 Caso3: USD owned_value != 250 (50%% of 500)';
  END IF;

  -- Caso 5: BENEFICIARY separado
  IF jsonb_array_length(v_benef) != 1 THEN
    RAISE EXCEPTION '_smoke_r0e1 Caso5: expected 1 beneficiary entry';
  END IF;
  IF (SELECT (e->>'value')::numeric FROM jsonb_array_elements(v_benef) e WHERE e->>'currency'='MXN') != 200 THEN
    RAISE EXCEPTION '_smoke_r0e1 Caso5: BENEFICIARY MXN value != 200';
  END IF;

  -- Caso 6: USE excluido (MXN owned should be exactly 1000, not 1000+9999)
  -- Already verified by Caso 2

  -- Caso 7 + 8: revoked + archived excluded (MXN exactly 1000, not + 7777 + 6666)
  -- Already verified by Caso 2

  -- NULL actor_id → invalid_parameter_value
  v_caught := false;
  BEGIN
    PERFORM public.actor_net_worth(NULL);
    RAISE EXCEPTION '_smoke_r0e1 extra: NULL should fail';
  EXCEPTION WHEN invalid_parameter_value THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r0e1 extra: expected'; END IF;

  -- Cleanup
  DELETE FROM public.resource_rights
   WHERE resource_id IN (v_res_mxn, v_res_usd, v_res_use, v_res_revoked, v_res_archived, v_res_benef);
  UPDATE public.resources SET archived_at = now()
   WHERE id IN (v_res_mxn, v_res_usd, v_res_use, v_res_revoked, v_res_benef);

  PERFORM set_config('request.jwt.claims', NULL, true);

  RAISE NOTICE '_smoke_r0e1_actor_net_worth passed (8 casos)';
END;
$$;
