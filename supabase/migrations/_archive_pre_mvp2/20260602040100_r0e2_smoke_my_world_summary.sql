-- R.0E.2 MIG 2 — Smoke for my_world_summary().
-- 8 casos:
--  1) Unauthenticated → exception 28000
--  2) Authenticated → returns 10 sections + actor + net_worth
--  3) OWN right → appears in owned_resources
--  4) MANAGE right → appears in managed_resources
--  5) USE right → appears in used_resources
--  6) BENEFICIARY right → appears in beneficiary_resources
--  7) shareholder_of relationship → appears in controlled_entities
--  8) debtor_to relationship → appears in obligations

CREATE OR REPLACE FUNCTION public._smoke_r0e2_my_world_summary()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_group       uuid;
  v_user        uuid;
  v_other_actor uuid;
  v_res_own     uuid;
  v_res_manage  uuid;
  v_res_use     uuid;
  v_res_benef   uuid;
  v_result      jsonb;
  v_caught      boolean;
BEGIN
  -- Caso 1: unauthenticated → 28000
  v_caught := false;
  PERFORM set_config('request.jwt.claims', NULL, true);
  BEGIN
    PERFORM public.my_world_summary();
    RAISE EXCEPTION '_smoke_r0e2 Caso1: should have failed';
  EXCEPTION
    WHEN sqlstate '28000' THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r0e2 Caso1: expected'; END IF;

  -- Setup: real user con membership activa
  SELECT user_id INTO v_user
    FROM public.group_memberships
   WHERE status='active'
   LIMIT 1;
  SELECT id INTO v_group FROM public.groups
   WHERE id IN (SELECT group_id FROM public.group_memberships WHERE user_id = v_user AND status='active')
   LIMIT 1;
  SELECT id INTO v_other_actor FROM public.actors
   WHERE actor_kind='person' AND id <> v_user LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', v_user::text)::text, true);

  -- Caso 2: structure
  v_result := public.my_world_summary();
  IF v_result IS NULL THEN RAISE EXCEPTION '_smoke_r0e2 Caso2: NULL'; END IF;
  IF (v_result->'actor'->>'id')::uuid IS DISTINCT FROM v_user THEN
    RAISE EXCEPTION '_smoke_r0e2 Caso2: actor.id mismatch';
  END IF;
  IF v_result->'net_worth' IS NULL THEN
    RAISE EXCEPTION '_smoke_r0e2 Caso2: net_worth missing';
  END IF;
  IF NOT (v_result ? 'owned_resources' AND v_result ? 'managed_resources'
          AND v_result ? 'used_resources' AND v_result ? 'beneficiary_resources'
          AND v_result ? 'groups' AND v_result ? 'controlled_entities'
          AND v_result ? 'obligations' AND v_result ? 'recent_activity'
          AND v_result ? 'pending_decisions') THEN
    RAISE EXCEPTION '_smoke_r0e2 Caso2: missing sections';
  END IF;

  -- Setup: 4 resources + 1 of each right + 2 relationships
  INSERT INTO public.resources (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
  VALUES (v_group, 'asset', '_smoke_r0e2 own', 'active', 'members', 'group', '{}'::jsonb,
          '{"estimated_value": 100, "currency": "MXN"}'::jsonb, v_user)
  RETURNING id INTO v_res_own;

  INSERT INTO public.resources (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
  VALUES (v_group, 'asset', '_smoke_r0e2 manage', 'active', 'members', 'group', '{}'::jsonb, '{}'::jsonb, v_user)
  RETURNING id INTO v_res_manage;

  INSERT INTO public.resources (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
  VALUES (v_group, 'asset', '_smoke_r0e2 use', 'active', 'members', 'group', '{}'::jsonb, '{}'::jsonb, v_user)
  RETURNING id INTO v_res_use;

  INSERT INTO public.resources (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
  VALUES (v_group, 'asset', '_smoke_r0e2 benef', 'active', 'members', 'group', '{}'::jsonb,
          '{"estimated_value": 50, "currency": "MXN"}'::jsonb, v_user)
  RETURNING id INTO v_res_benef;

  PERFORM public.grant_right(p_resource_id := v_res_own, p_holder_actor_id := v_user, p_right_kind := 'OWN', p_percent := 100);
  PERFORM public.grant_right(p_resource_id := v_res_manage, p_holder_actor_id := v_user, p_right_kind := 'MANAGE');
  PERFORM public.grant_right(p_resource_id := v_res_use, p_holder_actor_id := v_user, p_right_kind := 'USE');
  PERFORM public.grant_right(p_resource_id := v_res_benef, p_holder_actor_id := v_user, p_right_kind := 'BENEFICIARY');

  PERFORM public.create_actor_relationship(
    p_subject_actor_id := v_user,
    p_relationship_type := 'shareholder_of',
    p_object_actor_id := v_other_actor,
    p_metadata := '{"percent": 30}'::jsonb
  );

  PERFORM public.create_actor_relationship(
    p_subject_actor_id := v_user,
    p_relationship_type := 'debtor_to',
    p_object_actor_id := v_other_actor,
    p_metadata := '{"amount": 5000, "currency": "MXN"}'::jsonb
  );

  v_result := public.my_world_summary();

  -- Caso 3: OWN
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_result->'owned_resources') e
    WHERE (e->>'resource_id')::uuid = v_res_own
  ) THEN
    RAISE EXCEPTION '_smoke_r0e2 Caso3: OWN missing';
  END IF;

  -- Caso 4: MANAGE
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_result->'managed_resources') e
    WHERE (e->>'resource_id')::uuid = v_res_manage
  ) THEN
    RAISE EXCEPTION '_smoke_r0e2 Caso4: MANAGE missing';
  END IF;

  -- Caso 5: USE
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_result->'used_resources') e
    WHERE (e->>'resource_id')::uuid = v_res_use
  ) THEN
    RAISE EXCEPTION '_smoke_r0e2 Caso5: USE missing';
  END IF;

  -- Caso 6: BENEFICIARY
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_result->'beneficiary_resources') e
    WHERE (e->>'resource_id')::uuid = v_res_benef
  ) THEN
    RAISE EXCEPTION '_smoke_r0e2 Caso6: BENEFICIARY missing';
  END IF;

  -- Caso 7: shareholder_of
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_result->'controlled_entities') e
    WHERE (e->>'actor_id')::uuid = v_other_actor
      AND e->>'relationship_type' = 'shareholder_of'
  ) THEN
    RAISE EXCEPTION '_smoke_r0e2 Caso7: shareholder_of missing';
  END IF;

  -- Caso 8: debtor_to
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_result->'obligations') e
    WHERE e->>'relationship_type' = 'debtor_to'
      AND e->>'direction' = 'out'
  ) THEN
    RAISE EXCEPTION '_smoke_r0e2 Caso8: debtor_to missing';
  END IF;

  -- Cleanup
  DELETE FROM public.actor_relationships
   WHERE subject_actor_id = v_user
     AND object_actor_id = v_other_actor
     AND relationship_type IN ('shareholder_of','debtor_to');
  DELETE FROM public.resource_rights
   WHERE resource_id IN (v_res_own, v_res_manage, v_res_use, v_res_benef);
  UPDATE public.resources SET archived_at = now()
   WHERE id IN (v_res_own, v_res_manage, v_res_use, v_res_benef);

  PERFORM set_config('request.jwt.claims', NULL, true);

  RAISE NOTICE '_smoke_r0e2_my_world_summary passed (8 casos)';
END;
$$;
