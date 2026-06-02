-- R.1-CONTRACT.1 — Backend contract smoke para iOS context-centric
--
-- Verifica que el contrato backend completo para frontend context-centric existe,
-- está asegurado y funciona end-to-end:
--   - Los 14 RPCs del contrato existen.
--   - Person context (my_world_summary + create_personal_resource + list_actor_resources).
--   - Group context (group_world_summary para miembros).
--   - Legal entity context (create_legal_entity + legal_entity_world_summary para controller).
--   - Resource relevante a múltiples contexts (OWN persona + MANAGE grupo).
--   - Rights visibles por razón (right_kind en list_actor_resources).
--   - Unauthorized blocked en los 3 contexts.

CREATE OR REPLACE FUNCTION public._smoke_r1_backend_contract()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_member    uuid;   -- miembro activo de v_group
  v_group     uuid;
  v_user_b    uuid;   -- tercero sin autoridad
  v_res       public.resources%ROWTYPE;
  v_entity_id uuid;
  v_result    jsonb;
  v_caught    boolean;
  v_rpc       text;
  v_missing   text := '';
BEGIN
  -- ── 1. Contrato: los 14 RPCs existen ───────────────────────
  FOREACH v_rpc IN ARRAY ARRAY[
    'public.my_world_summary()',
    'public.group_world_summary(uuid)',
    'public.legal_entity_world_summary(uuid)',
    'public.actor_net_worth(uuid)',
    'public.list_actor_resources(uuid)',
    'public.actor_has_right(uuid, uuid, text)',
    'public.has_actor_authority(uuid, text)',
    'public.grant_right(uuid, uuid, text, numeric, text, timestamptz, timestamptz, uuid, jsonb)',
    'public.revoke_right(uuid)',
    'public.create_actor_relationship(uuid, text, uuid, uuid, timestamptz, timestamptz, jsonb)',
    'public.end_actor_relationship(uuid)',
    'public.list_actor_relationships(uuid, text, boolean)',
    'public.create_personal_resource(text, text, text, text, jsonb, text)',
    'public.create_legal_entity(text, text, text, text, jsonb)',
    'public.update_legal_entity(uuid, text, text, text, text, jsonb)'
  ] LOOP
    IF to_regprocedure(v_rpc) IS NULL THEN
      v_missing := v_missing || v_rpc || '; ';
    END IF;
  END LOOP;
  IF v_missing <> '' THEN
    RAISE EXCEPTION '_smoke_r1contract: RPCs faltantes del contrato: %', v_missing;
  END IF;

  -- ── Setup ──────────────────────────────────────────────────
  SELECT gm.user_id, gm.group_id INTO v_member, v_group
    FROM public.group_memberships gm
   WHERE gm.status = 'active' AND gm.user_id IS NOT NULL
   LIMIT 1;

  SELECT p.id INTO v_user_b
    FROM public.profiles p
   WHERE p.id <> v_member
     AND NOT EXISTS (
       SELECT 1 FROM public.group_memberships gm
       WHERE gm.user_id = p.id AND gm.group_id = v_group)
   LIMIT 1;

  -- ── 2. Person context ──────────────────────────────────────
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_member::text)::text, true);

  v_result := public.my_world_summary();
  IF v_result IS NULL OR (v_result->'actor'->>'id')::uuid IS DISTINCT FROM v_member THEN
    RAISE EXCEPTION '_smoke_r1contract person: my_world_summary failed';
  END IF;

  v_res := public.create_personal_resource(
    p_resource_type := 'asset',
    p_name := '_smoke_r1contract multi-context asset',
    p_metadata := '{"estimated_value": 1000, "currency": "MXN"}'::jsonb);

  IF NOT EXISTS (
    SELECT 1 FROM public.list_actor_resources(v_member) lr
    WHERE lr.resource_id = v_res.id AND lr.right_kind = 'OWN'
  ) THEN
    RAISE EXCEPTION '_smoke_r1contract person: OWN no visible por razón en list_actor_resources';
  END IF;

  -- ── 3. Group context ───────────────────────────────────────
  v_result := public.group_world_summary(v_group);
  IF v_result IS NULL OR (v_result->'group'->>'id')::uuid IS DISTINCT FROM v_group THEN
    RAISE EXCEPTION '_smoke_r1contract group: group_world_summary failed para miembro';
  END IF;

  -- ── 4. Resource relevante a múltiples contexts ─────────────
  -- v_member (OWN) otorga MANAGE al group actor → el resource es relevante
  -- en el person context (owned) Y en el group context (managed)
  PERFORM public.grant_right(
    p_resource_id := v_res.id,
    p_holder_actor_id := v_group,
    p_right_kind := 'MANAGE');

  v_result := public.group_world_summary(v_group);
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_result->'resources_managed') e
    WHERE (e->>'resource_id')::uuid = v_res.id
  ) THEN
    RAISE EXCEPTION '_smoke_r1contract multi-context: resource no aparece en group resources_managed';
  END IF;

  v_result := public.my_world_summary();
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_result->'owned_resources') e
    WHERE (e->>'resource_id')::uuid = v_res.id
  ) THEN
    RAISE EXCEPTION '_smoke_r1contract multi-context: resource no aparece en my_world owned_resources';
  END IF;

  -- ── 5. Legal entity context ────────────────────────────────
  v_entity_id := public.create_legal_entity(
    p_display_name := '_smoke_r1contract Holdings SA',
    p_entity_type := 'company',
    p_jurisdiction := 'MX');

  v_result := public.legal_entity_world_summary(v_entity_id);
  IF v_result IS NULL OR (v_result->'entity'->>'id')::uuid IS DISTINCT FROM v_entity_id THEN
    RAISE EXCEPTION '_smoke_r1contract entity: legal_entity_world_summary failed para controller';
  END IF;

  -- net worth de la entity accesible para el controller (finance.view via controls)
  v_result := public.actor_net_worth(v_entity_id);
  IF v_result IS NULL THEN
    RAISE EXCEPTION '_smoke_r1contract entity: actor_net_worth de la entity failed para controller';
  END IF;

  -- ── 6. Unauthorized blocked en los 3 contexts ──────────────
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);

  -- 6a. group context bloqueado para no-miembro
  v_caught := false;
  BEGIN
    v_result := public.group_world_summary(v_group);
  EXCEPTION WHEN insufficient_privilege THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r1contract unauthorized: group context no bloqueado'; END IF;

  -- 6b. legal entity context bloqueado para tercero
  v_caught := false;
  BEGIN
    v_result := public.legal_entity_world_summary(v_entity_id);
  EXCEPTION WHEN insufficient_privilege THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r1contract unauthorized: entity context no bloqueado'; END IF;

  -- 6c. person net worth bloqueado para tercero
  v_caught := false;
  BEGIN
    v_result := public.actor_net_worth(v_member);
  EXCEPTION WHEN insufficient_privilege THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r1contract unauthorized: person net worth no bloqueado'; END IF;

  -- 6d. list_actor_resources de tercero bloqueado
  v_caught := false;
  BEGIN
    PERFORM * FROM public.list_actor_resources(v_member);
  EXCEPTION WHEN insufficient_privilege THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r1contract unauthorized: list_actor_resources no bloqueado'; END IF;

  -- ── Cleanup ────────────────────────────────────────────────
  PERFORM set_config('request.jwt.claims', NULL, true);
  DELETE FROM public.resource_rights WHERE resource_id = v_res.id;
  UPDATE public.resources SET archived_at = now() WHERE id = v_res.id;
  DELETE FROM public.actor_relationships WHERE object_actor_id = v_entity_id;
  DELETE FROM public.legal_entities WHERE id = v_entity_id;
  DELETE FROM public.actors WHERE id = v_entity_id AND actor_kind = 'legal_entity';

  RAISE NOTICE '_smoke_r1_backend_contract passed (contrato completo: person/group/entity contexts + multi-context resource + unauthorized blocked)';
END;
$$;

REVOKE ALL ON FUNCTION public._smoke_r1_backend_contract() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._smoke_r1_backend_contract() IS
  'Smoke R.1-CONTRACT: contrato backend completo para frontend context-centric (14 RPCs, 3 contexts, multi-context resource, rights por razón, unauthorized blocked).';
