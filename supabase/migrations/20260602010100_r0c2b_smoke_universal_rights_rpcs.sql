-- R.0C.2b MIG 2 — Smoke for universal grant_right / revoke_right / actor_has_right.
--
-- 8 casos:
--  1) grant_right NEW → returns uuid + actor_has_right=true
--  2) UPSERT: grant_right same (resource, holder, kind) → same id + fields updated
--  3) revoke_right → revoked_at set, actor_has_right=false
--  4) UNDELETE: grant_right after revoke → same id, revoked_at NULL
--  5) starts_at futuro → actor_has_right=false
--  6) ends_at pasado → actor_has_right=false
--  7) revoke_right idempotente (re-call no-op)
--  8) revoke_right id inexistente → no-op
--
-- IMPORTANTE: usar named params (`p_right_id := …`) para desambiguar overloads.

CREATE OR REPLACE FUNCTION public._smoke_r0c2b_rights_rpcs()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_group       uuid;
  v_user_a      uuid;
  v_resource_id uuid;
  v_right_id    uuid;
  v_right_id2   uuid;
  v_has         boolean;
BEGIN
  SELECT id INTO v_group FROM public.groups LIMIT 1;
  SELECT id INTO v_user_a FROM public.actors WHERE actor_kind='person' LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', v_user_a::text)::text, true);

  INSERT INTO public.resources
    (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
  VALUES
    (v_group, 'document', '_smoke_r0c2b res', 'active', 'members', 'group', '{}'::jsonb, '{}'::jsonb, v_user_a)
  RETURNING id INTO v_resource_id;

  -- Caso 1: grant_right NEW
  v_right_id := public.grant_right(
    p_resource_id := v_resource_id,
    p_holder_actor_id := v_user_a,
    p_right_kind := 'USE',
    p_metadata := '{"source":"r0c2b_smoke_caso1"}'::jsonb
  );
  IF v_right_id IS NULL THEN RAISE EXCEPTION '_smoke_r0c2b Caso1: grant returned NULL'; END IF;
  v_has := public.actor_has_right(v_user_a, v_resource_id, 'USE');
  IF NOT v_has THEN RAISE EXCEPTION '_smoke_r0c2b Caso1: should have right'; END IF;

  -- Caso 2: UPSERT
  v_right_id2 := public.grant_right(
    p_resource_id := v_resource_id,
    p_holder_actor_id := v_user_a,
    p_right_kind := 'USE',
    p_scope := 'r0c2b_scope_updated',
    p_metadata := '{"source":"r0c2b_smoke_caso2"}'::jsonb
  );
  IF v_right_id2 IS DISTINCT FROM v_right_id THEN
    RAISE EXCEPTION '_smoke_r0c2b Caso2: upsert should return same id';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.resource_rights
    WHERE id = v_right_id
      AND scope = 'r0c2b_scope_updated'
      AND metadata->>'source' = 'r0c2b_smoke_caso2'
  ) THEN
    RAISE EXCEPTION '_smoke_r0c2b Caso2: fields not updated';
  END IF;

  -- Caso 3: revoke → has_right=false
  PERFORM public.revoke_right(p_right_id := v_right_id);
  IF (SELECT revoked_at FROM public.resource_rights WHERE id = v_right_id) IS NULL THEN
    RAISE EXCEPTION '_smoke_r0c2b Caso3: revoked_at should be set';
  END IF;
  v_has := public.actor_has_right(v_user_a, v_resource_id, 'USE');
  IF v_has THEN RAISE EXCEPTION '_smoke_r0c2b Caso3: should not have right'; END IF;

  -- Caso 4: UNDELETE
  v_right_id2 := public.grant_right(
    p_resource_id := v_resource_id,
    p_holder_actor_id := v_user_a,
    p_right_kind := 'USE'
  );
  IF v_right_id2 IS DISTINCT FROM v_right_id THEN
    RAISE EXCEPTION '_smoke_r0c2b Caso4: undelete should return same id';
  END IF;
  IF (SELECT revoked_at FROM public.resource_rights WHERE id = v_right_id) IS NOT NULL THEN
    RAISE EXCEPTION '_smoke_r0c2b Caso4: revoked_at should be NULL';
  END IF;
  v_has := public.actor_has_right(v_user_a, v_resource_id, 'USE');
  IF NOT v_has THEN RAISE EXCEPTION '_smoke_r0c2b Caso4: should have right after undelete'; END IF;

  -- Caso 5: starts_at futuro
  v_right_id2 := public.grant_right(
    p_resource_id := v_resource_id,
    p_holder_actor_id := v_user_a,
    p_right_kind := 'MANAGE',
    p_starts_at := now() + interval '1 hour'
  );
  v_has := public.actor_has_right(v_user_a, v_resource_id, 'MANAGE');
  IF v_has THEN RAISE EXCEPTION '_smoke_r0c2b Caso5: should not have right (future starts_at)'; END IF;

  -- Caso 6: ends_at pasado
  v_right_id2 := public.grant_right(
    p_resource_id := v_resource_id,
    p_holder_actor_id := v_user_a,
    p_right_kind := 'VIEW',
    p_ends_at := now() - interval '1 hour'
  );
  v_has := public.actor_has_right(v_user_a, v_resource_id, 'VIEW');
  IF v_has THEN RAISE EXCEPTION '_smoke_r0c2b Caso6: should not have right (past ends_at)'; END IF;

  -- Caso 7: revoke idempotente
  PERFORM public.revoke_right(p_right_id := v_right_id);
  PERFORM public.revoke_right(p_right_id := v_right_id);
  IF (SELECT revoked_at FROM public.resource_rights WHERE id = v_right_id) IS NULL THEN
    RAISE EXCEPTION '_smoke_r0c2b Caso7: revoked_at should be set';
  END IF;

  -- Caso 8: revoke id inexistente → no-op
  PERFORM public.revoke_right(p_right_id := gen_random_uuid());

  -- Cleanup
  DELETE FROM public.resource_rights WHERE resource_id = v_resource_id;
  UPDATE public.resources SET archived_at = now() WHERE id = v_resource_id;

  PERFORM set_config('request.jwt.claims', NULL, true);

  RAISE NOTICE '_smoke_r0c2b_rights_rpcs passed (8 casos)';
END;
$$;
