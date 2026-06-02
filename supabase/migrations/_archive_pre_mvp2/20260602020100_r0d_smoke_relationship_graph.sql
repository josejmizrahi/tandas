-- R.0D MIG 2 — Smoke for relationship graph (10 casos, final fixed).
--
-- SQLSTATE codes:
--   22023 = invalid_parameter_value (RPCs)
--   23514 = check_violation (CHECK constraints)

CREATE OR REPLACE FUNCTION public._smoke_r0d_relationship_graph()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_group_actor    uuid;
  v_jose           uuid;
  v_linda          uuid;
  v_resource_id    uuid;
  v_rel_1          uuid;
  v_rel_2          uuid;
  v_caught         boolean;
  v_count_out      int;
  v_count_in       int;
  v_count_both     int;
BEGIN
  SELECT id INTO v_jose  FROM public.actors WHERE actor_kind='person' LIMIT 1;
  SELECT id INTO v_linda FROM public.actors WHERE actor_kind='person' AND id <> v_jose LIMIT 1;
  SELECT id INTO v_group_actor FROM public.actors WHERE actor_kind='group' LIMIT 1;
  SELECT id INTO v_resource_id FROM public.resources WHERE archived_at IS NULL LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', v_jose::text)::text, true);

  -- Caso 1: actor → actor
  v_rel_1 := public.create_actor_relationship(
    p_subject_actor_id := v_jose,
    p_relationship_type := 'shareholder_of',
    p_object_actor_id := v_group_actor,
    p_metadata := '{"percent": 70}'::jsonb
  );
  IF v_rel_1 IS NULL THEN RAISE EXCEPTION '_smoke_r0d Caso1: NULL'; END IF;

  -- Caso 2: actor → resource
  v_rel_2 := public.create_actor_relationship(
    p_subject_actor_id := v_jose,
    p_relationship_type := 'guarantor_of',
    p_object_resource_id := v_resource_id
  );
  IF v_rel_2 IS NULL THEN RAISE EXCEPTION '_smoke_r0d Caso2: NULL'; END IF;

  -- Caso 3: both NULL → invalid_parameter_value
  v_caught := false;
  BEGIN
    PERFORM public.create_actor_relationship(
      p_subject_actor_id := v_jose,
      p_relationship_type := 'owns'
    );
    RAISE EXCEPTION '_smoke_r0d Caso3: should have failed';
  EXCEPTION WHEN invalid_parameter_value THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r0d Caso3: expected'; END IF;

  -- Caso 4: both NOT NULL → invalid_parameter_value
  v_caught := false;
  BEGIN
    PERFORM public.create_actor_relationship(
      p_subject_actor_id := v_jose,
      p_relationship_type := 'owns',
      p_object_actor_id := v_linda,
      p_object_resource_id := v_resource_id
    );
    RAISE EXCEPTION '_smoke_r0d Caso4: should have failed';
  EXCEPTION WHEN invalid_parameter_value THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r0d Caso4: expected'; END IF;

  -- Caso 5: Whitelist → check_violation
  v_caught := false;
  BEGIN
    PERFORM public.create_actor_relationship(
      p_subject_actor_id := v_jose,
      p_relationship_type := 'INVALID_KIND',
      p_object_actor_id := v_linda
    );
    RAISE EXCEPTION '_smoke_r0d Caso5: should have failed';
  EXCEPTION WHEN check_violation THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r0d Caso5: expected'; END IF;

  -- Caso 6: list out
  PERFORM public.create_actor_relationship(
    p_subject_actor_id := v_linda,
    p_relationship_type := 'creditor_of',
    p_object_actor_id := v_jose
  );

  SELECT count(*) INTO v_count_out
    FROM public.list_actor_relationships(v_jose, 'out');
  IF v_count_out < 2 THEN
    RAISE EXCEPTION '_smoke_r0d Caso6: out >=2 (got %)', v_count_out;
  END IF;

  -- Caso 7: list in
  SELECT count(*) INTO v_count_in
    FROM public.list_actor_relationships(v_jose, 'in');
  IF v_count_in < 1 THEN
    RAISE EXCEPTION '_smoke_r0d Caso7: in >=1 (got %)', v_count_in;
  END IF;

  -- Caso 8: list both
  SELECT count(*) INTO v_count_both
    FROM public.list_actor_relationships(v_jose, 'both');
  IF v_count_both < (v_count_out + v_count_in) THEN
    RAISE EXCEPTION '_smoke_r0d Caso8: both %, expected >=%+%',
      v_count_both, v_count_out, v_count_in;
  END IF;

  -- Caso 9: end → no active
  PERFORM public.end_actor_relationship(v_rel_1);
  IF (SELECT ends_at FROM public.actor_relationships WHERE id = v_rel_1) IS NULL THEN
    RAISE EXCEPTION '_smoke_r0d Caso9: ends_at should be set';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.list_actor_relationships(v_jose, 'out')
    WHERE id = v_rel_1
  ) THEN
    RAISE EXCEPTION '_smoke_r0d Caso9: should not be active';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.list_actor_relationships(v_jose, 'out', true)
    WHERE id = v_rel_1
  ) THEN
    RAISE EXCEPTION '_smoke_r0d Caso9b: should appear with include_inactive';
  END IF;

  -- Caso 10: end idempotente
  PERFORM public.end_actor_relationship(v_rel_1);
  PERFORM public.end_actor_relationship(gen_random_uuid());

  -- Cleanup
  DELETE FROM public.actor_relationships
   WHERE subject_actor_id IN (v_jose, v_linda)
      OR object_actor_id IN (v_jose, v_linda, v_group_actor)
      OR object_resource_id = v_resource_id;

  PERFORM set_config('request.jwt.claims', NULL, true);

  RAISE NOTICE '_smoke_r0d_relationship_graph passed (10 casos)';
END;
$$;
