-- R.0F MIG 2 — Smoke for both world summary RPCs (8 casos)

CREATE OR REPLACE FUNCTION public._smoke_r0f_world_summaries()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_group     uuid;
  v_user      uuid;
  v_legal_id  uuid;
  v_res_id    uuid;
  v_result    jsonb;
  v_caught    boolean;
BEGIN
  SELECT id INTO v_group FROM public.groups LIMIT 1;
  SELECT id INTO v_user  FROM public.actors WHERE actor_kind='person' LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', v_user::text)::text, true);

  -- Caso 1: NULL group_id
  v_caught := false;
  BEGIN
    PERFORM public.group_world_summary(NULL);
    RAISE EXCEPTION '_smoke_r0f Caso1: should have failed';
  EXCEPTION WHEN invalid_parameter_value THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r0f Caso1: expected'; END IF;

  -- Caso 2: structure
  v_result := public.group_world_summary(v_group);
  IF v_result IS NULL THEN RAISE EXCEPTION '_smoke_r0f Caso2: NULL'; END IF;
  IF (v_result->'group'->>'id')::uuid IS DISTINCT FROM v_group THEN
    RAISE EXCEPTION '_smoke_r0f Caso2: group.id mismatch';
  END IF;
  IF NOT (v_result ? 'net_worth' AND v_result ? 'members'
          AND v_result ? 'resources_owned' AND v_result ? 'resources_managed'
          AND v_result ? 'resources_used' AND v_result ? 'governance'
          AND v_result ? 'rules' AND v_result ? 'recent_activity') THEN
    RAISE EXCEPTION '_smoke_r0f Caso2: missing sections';
  END IF;

  -- Caso 3: net_worth delegated structure
  IF NOT (v_result->'net_worth' ? 'owned_by_currency'
          AND v_result->'net_worth' ? 'beneficiary_by_currency') THEN
    RAISE EXCEPTION '_smoke_r0f Caso3: net_worth not delegated';
  END IF;

  -- Caso 4: group OWN appears
  INSERT INTO public.resources (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
  VALUES (v_group, 'asset', '_smoke_r0f group-owned', 'active', 'members', 'group', '{}'::jsonb,
          '{"estimated_value": 999, "currency": "MXN"}'::jsonb, v_user)
  RETURNING id INTO v_res_id;

  PERFORM public.grant_right(p_resource_id := v_res_id, p_holder_actor_id := v_group, p_right_kind := 'OWN', p_percent := 100);

  v_result := public.group_world_summary(v_group);
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_result->'resources_owned') e
    WHERE (e->>'resource_id')::uuid = v_res_id
  ) THEN
    RAISE EXCEPTION '_smoke_r0f Caso4: group-OWN missing';
  END IF;

  -- Caso 5: NULL legal_entity actor_id
  v_caught := false;
  BEGIN
    PERFORM public.legal_entity_world_summary(NULL);
    RAISE EXCEPTION '_smoke_r0f Caso5: should have failed';
  EXCEPTION WHEN invalid_parameter_value THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r0f Caso5: expected'; END IF;

  -- Caso 6: legal_entity not found
  v_caught := false;
  BEGIN
    PERFORM public.legal_entity_world_summary(v_user);
    RAISE EXCEPTION '_smoke_r0f Caso6: should have failed';
  EXCEPTION WHEN sqlstate 'P0002' THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r0f Caso6: expected P0002'; END IF;

  -- Caso 7: create legal_entity + structure + recent_activity=[]
  v_legal_id := public.create_legal_entity(
    p_display_name := '_smoke_r0f Trust',
    p_entity_type := 'trust',
    p_jurisdiction := 'MX'
  );

  v_result := public.legal_entity_world_summary(v_legal_id);
  IF v_result IS NULL THEN RAISE EXCEPTION '_smoke_r0f Caso7: NULL'; END IF;
  IF NOT (v_result ? 'entity' AND v_result ? 'net_worth'
          AND v_result ? 'owned_resources' AND v_result ? 'controlled_resources'
          AND v_result ? 'shareholders' AND v_result ? 'beneficiaries'
          AND v_result ? 'controlling_actors' AND v_result ? 'obligations'
          AND v_result ? 'recent_activity') THEN
    RAISE EXCEPTION '_smoke_r0f Caso7: missing sections';
  END IF;
  IF jsonb_array_length(v_result->'recent_activity') != 0 THEN
    RAISE EXCEPTION '_smoke_r0f Caso7: recent_activity should be empty by design';
  END IF;

  -- Caso 8: shareholder_of relationship
  PERFORM public.create_actor_relationship(
    p_subject_actor_id := v_user,
    p_relationship_type := 'shareholder_of',
    p_object_actor_id := v_legal_id,
    p_metadata := '{"percent": 70}'::jsonb
  );

  v_result := public.legal_entity_world_summary(v_legal_id);
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_result->'shareholders') e
    WHERE (e->>'actor_id')::uuid = v_user
  ) THEN
    RAISE EXCEPTION '_smoke_r0f Caso8: shareholder missing';
  END IF;

  -- Cleanup
  DELETE FROM public.actor_relationships
   WHERE subject_actor_id = v_user AND object_actor_id = v_legal_id;
  DELETE FROM public.resource_rights WHERE resource_id = v_res_id;
  UPDATE public.resources SET archived_at = now() WHERE id = v_res_id;
  DELETE FROM public.legal_entities WHERE id = v_legal_id;
  DELETE FROM public.actors WHERE id = v_legal_id;

  PERFORM set_config('request.jwt.claims', NULL, true);

  RAISE NOTICE '_smoke_r0f_world_summaries passed (8 casos)';
END;
$$;
