-- R.0C.2a MIG 2 — Smoke for universal resource_rights table.
--
-- Casos (8):
--  1) Backfill: 77 OWN active con holder_actor_id consistente vs resource_owners
--  2) Sync trigger UP: INSERT OWN con percent mayor → canonical actualiza
--  3) Sync trigger DOWN: INSERT OWN con percent menor → canonical NO cambia
--  4) Revoke high-percent OWN → canonical re-sincroniza al siguiente OWN activo
--  5) Founder ajuste #5: revoke ALL OWN → canonical NO se borra (legacy cache permanece)
--  6) Whitelist CHECK rejects right_kind inválido
--  7) Percent CHECK rejects valores fuera de [0..100]
--  8) Unique partial index previene duplicado active OWN para mismo (resource, holder)

CREATE OR REPLACE FUNCTION public._smoke_r0c2a_universal_rights()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_group           uuid;
  v_user_a          uuid;
  v_user_b          uuid;
  v_resource_id     uuid;
  v_canonical_pre   uuid;
  v_canonical_mid   uuid;
  v_canonical_post  uuid;
  v_right_a_id      uuid;
  v_right_b_id      uuid;
  v_caught          boolean;
  v_backfill_mismatch int;
BEGIN
  SELECT id INTO v_group FROM public.groups LIMIT 1;
  SELECT id INTO v_user_a FROM public.actors WHERE actor_kind='person' LIMIT 1;
  SELECT id INTO v_user_b FROM public.actors WHERE actor_kind='person' AND id <> v_user_a LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', v_user_a::text)::text, true);

  -- Caso 1
  SELECT count(*) INTO v_backfill_mismatch
    FROM public.resource_owners ro
    LEFT JOIN public.resource_rights rr
      ON rr.resource_id = ro.resource_id
     AND rr.right_kind = 'OWN'
     AND rr.metadata->>'legacy_owner_id' = ro.id::text
   WHERE rr.id IS NULL;
  IF v_backfill_mismatch > 0 THEN
    RAISE EXCEPTION '_smoke_r0c2a Caso1: % resource_owners sin row OWN', v_backfill_mismatch;
  END IF;

  INSERT INTO public.resources
    (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
  VALUES
    (v_group, 'document', '_smoke_r0c2a resource', 'active', 'members', 'group', '{}'::jsonb, '{}'::jsonb, v_user_a)
  RETURNING id, canonical_owner_actor_id INTO v_resource_id, v_canonical_pre;

  -- Caso 2: sync UP
  INSERT INTO public.resource_rights
    (resource_id, holder_actor_id, right_kind, percent)
  VALUES (v_resource_id, v_user_a, 'OWN', 70)
  RETURNING id INTO v_right_a_id;

  SELECT canonical_owner_actor_id INTO v_canonical_mid
    FROM public.resources WHERE id = v_resource_id;
  IF v_canonical_mid IS DISTINCT FROM v_user_a THEN
    RAISE EXCEPTION '_smoke_r0c2a Caso2: canonical should sync to v_user_a';
  END IF;

  -- Caso 3: sync DOWN no cambia
  INSERT INTO public.resource_rights
    (resource_id, holder_actor_id, right_kind, percent)
  VALUES (v_resource_id, v_user_b, 'OWN', 30)
  RETURNING id INTO v_right_b_id;

  SELECT canonical_owner_actor_id INTO v_canonical_post
    FROM public.resources WHERE id = v_resource_id;
  IF v_canonical_post IS DISTINCT FROM v_user_a THEN
    RAISE EXCEPTION '_smoke_r0c2a Caso3: canonical should remain v_user_a';
  END IF;

  -- Caso 4: revoke high → re-sync
  UPDATE public.resource_rights SET revoked_at = now() WHERE id = v_right_a_id;
  SELECT canonical_owner_actor_id INTO v_canonical_post
    FROM public.resources WHERE id = v_resource_id;
  IF v_canonical_post IS DISTINCT FROM v_user_b THEN
    RAISE EXCEPTION '_smoke_r0c2a Caso4: after revoke, canonical should be v_user_b';
  END IF;

  -- Caso 5: founder #5 — revoke ALL → no clear
  UPDATE public.resource_rights SET revoked_at = now() WHERE id = v_right_b_id;
  SELECT canonical_owner_actor_id INTO v_canonical_post
    FROM public.resources WHERE id = v_resource_id;
  IF v_canonical_post IS NULL THEN
    RAISE EXCEPTION '_smoke_r0c2a Caso5: founder #5 broken — canonical cleared';
  END IF;
  IF v_canonical_post IS DISTINCT FROM v_user_b THEN
    RAISE EXCEPTION '_smoke_r0c2a Caso5: canonical should remain v_user_b';
  END IF;

  -- Caso 6: whitelist
  v_caught := false;
  BEGIN
    INSERT INTO public.resource_rights (resource_id, holder_actor_id, right_kind)
    VALUES (v_resource_id, v_user_a, 'INVALID_KIND');
    RAISE EXCEPTION '_smoke_r0c2a Caso6: should have failed';
  EXCEPTION WHEN check_violation THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r0c2a Caso6: CHECK violation expected'; END IF;

  -- Caso 7: percent CHECK
  v_caught := false;
  BEGIN
    INSERT INTO public.resource_rights (resource_id, holder_actor_id, right_kind, percent)
    VALUES (v_resource_id, v_user_a, 'OWN', 150);
    RAISE EXCEPTION '_smoke_r0c2a Caso7: percent=150 should have failed';
  EXCEPTION WHEN check_violation THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r0c2a Caso7: percent CHECK expected'; END IF;

  v_caught := false;
  BEGIN
    INSERT INTO public.resource_rights (resource_id, holder_actor_id, right_kind, percent)
    VALUES (v_resource_id, v_user_a, 'OWN', -5);
    RAISE EXCEPTION '_smoke_r0c2a Caso7b: percent=-5 should have failed';
  EXCEPTION WHEN check_violation THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r0c2a Caso7b: negative percent CHECK expected'; END IF;

  -- Caso 8: unique partial index
  INSERT INTO public.resource_rights
    (resource_id, holder_actor_id, right_kind, percent)
  VALUES (v_resource_id, v_user_a, 'OWN', 50);

  v_caught := false;
  BEGIN
    INSERT INTO public.resource_rights
      (resource_id, holder_actor_id, right_kind, percent)
    VALUES (v_resource_id, v_user_a, 'OWN', 50);
    RAISE EXCEPTION '_smoke_r0c2a Caso8: duplicate active OWN should have failed';
  EXCEPTION WHEN unique_violation THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r0c2a Caso8: unique constraint expected'; END IF;

  -- Cleanup
  DELETE FROM public.resource_rights WHERE resource_id = v_resource_id;
  UPDATE public.resources SET archived_at = now() WHERE id = v_resource_id;

  PERFORM set_config('request.jwt.claims', NULL, true);

  RAISE NOTICE '_smoke_r0c2a_universal_rights passed (8 casos)';
END;
$$;
