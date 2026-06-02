-- R.1-WIRE.2 — Creation flows generan OWN right automáticamente
--
-- Audit PR #131: la creación de recursos (create_group_resource / create_resource /
-- create_event / wrappers / inserts directos) NO otorgaba rights → cada recurso
-- nuevo nacía sin OWN y aumentaba el drift (ya eran 33).
--
-- Chokepoint real: AFTER INSERT trigger sobre `resources`. Cubre TODOS los flujos
-- de creación sin tocar ninguna de las ~26 RPCs writer:
--   - el BEFORE INSERT trigger R.0B.2 garantiza canonical_owner_actor_id
--     (deriva de group_id si viene NULL)
--   - este AFTER INSERT crea el OWN 100% para ese canonical owner
--   - el sync trigger de resource_rights (R.0C.2a) mantiene el cache coherente
--
-- Idempotente: NOT EXISTS evita duplicados (unique partial index protege además).

-- ============================================================
-- 1. Trigger: auto-grant OWN al canonical owner en cada INSERT
-- ============================================================
CREATE OR REPLACE FUNCTION public._resources_auto_grant_own_right()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.canonical_owner_actor_id IS NOT NULL THEN
    INSERT INTO public.resource_rights (resource_id, holder_actor_id, right_kind, percent, metadata)
    SELECT NEW.id, NEW.canonical_owner_actor_id, 'OWN', 100,
           jsonb_build_object('source', 'r1_wire_auto_own_on_create')
    WHERE NOT EXISTS (
      SELECT 1 FROM public.resource_rights rr
      WHERE rr.resource_id = NEW.id
        AND rr.right_kind = 'OWN'
        AND rr.revoked_at IS NULL
        AND rr.expired_at IS NULL
    );
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public._resources_auto_grant_own_right() IS
  'R.1-WIRE.2: todo resource nuevo con canonical_owner_actor_id recibe OWN 100% automático en resource_rights (fuente formal de relevancia).';

DROP TRIGGER IF EXISTS trg_resources_auto_grant_own_right ON public.resources;
CREATE TRIGGER trg_resources_auto_grant_own_right
  AFTER INSERT ON public.resources
  FOR EACH ROW EXECUTE FUNCTION public._resources_auto_grant_own_right();

-- ============================================================
-- 2. Fix _smoke_r1sec_actor_authority: el setup insertaba OWN explícito
--    después del INSERT del resource — con el nuevo trigger el OWN ya existe.
--    Se vuelve defensive (NOT EXISTS) para seguir siendo re-runnable.
-- ============================================================
CREATE OR REPLACE FUNCTION public._smoke_r1sec_actor_authority()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_user_a   uuid;  -- miembro activo de v_group
  v_user_b   uuid;  -- NO miembro de v_group
  v_group    uuid;
  v_other    uuid;  -- actor target para relationships
  v_resource uuid;  -- resource personal de user_a
  v_right_id uuid;
  v_rel_id   uuid;
  v_result   jsonb;
  v_caught   boolean;
BEGIN
  -- ── Setup ──────────────────────────────────────────────────
  SELECT gm.user_id, gm.group_id INTO v_user_a, v_group
    FROM public.group_memberships gm
    JOIN public.actors a ON a.id = gm.user_id AND a.actor_kind = 'person'
   WHERE gm.status = 'active' AND gm.user_id IS NOT NULL
   LIMIT 1;
  IF v_user_a IS NULL THEN
    RAISE EXCEPTION '_smoke_r1sec setup: no active membership found';
  END IF;

  SELECT p.id INTO v_user_b
    FROM public.profiles p
    JOIN public.actors a ON a.id = p.id AND a.actor_kind = 'person'
   WHERE p.id <> v_user_a
     AND NOT EXISTS (
       SELECT 1 FROM public.group_memberships gm
       WHERE gm.user_id = p.id AND gm.group_id = v_group
     )
   LIMIT 1;
  IF v_user_b IS NULL THEN
    RAISE EXCEPTION '_smoke_r1sec setup: no non-member profile found';
  END IF;

  SELECT id INTO v_other FROM public.actors
   WHERE actor_kind = 'person' AND id NOT IN (v_user_a, v_user_b)
   LIMIT 1;

  -- Resource personal de user_a + OWN right
  -- (post R.1-WIRE.2 el trigger auto-grant ya crea el OWN; el INSERT explícito
  --  queda como defensa NOT EXISTS para compat con cualquier estado)
  PERFORM set_config('ruul.resource_create_intent', '_smoke_r1sec_setup', true);
  INSERT INTO public.resources
    (group_id, resource_type, name, status, visibility, ownership_kind,
     ownership_metadata, metadata, created_by, canonical_owner_actor_id)
  VALUES
    (NULL, 'asset', '_smoke_r1sec personal asset', 'active', 'private', 'individual',
     '{}'::jsonb, '{}'::jsonb, v_user_a, v_user_a)
  RETURNING id INTO v_resource;

  INSERT INTO public.resource_rights (resource_id, holder_actor_id, right_kind, percent, metadata)
  SELECT v_resource, v_user_a, 'OWN', 100, '{"source": "_smoke_r1sec_setup"}'::jsonb
   WHERE NOT EXISTS (
     SELECT 1 FROM public.resource_rights rr
     WHERE rr.resource_id = v_resource AND rr.right_kind = 'OWN'
       AND rr.holder_actor_id = v_user_a AND rr.revoked_at IS NULL
   );

  -- ── Caso 1: person actor ve su propio net worth ────────────
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_result := public.actor_net_worth(v_user_a);
  IF v_result IS NULL OR (v_result->>'actor_id')::uuid IS DISTINCT FROM v_user_a THEN
    RAISE EXCEPTION '_smoke_r1sec Caso1: self net worth failed';
  END IF;

  -- ── Caso 2: person actor NO ve net worth de otro ───────────
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  v_caught := false;
  BEGIN
    v_result := public.actor_net_worth(v_user_a);
    RAISE EXCEPTION '_smoke_r1sec Caso2: should have been blocked';
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r1sec Caso2: expected 42501'; END IF;

  -- ── Caso 3: miembro activo ve group_world_summary ──────────
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_result := public.group_world_summary(v_group);
  IF v_result IS NULL OR (v_result->'group'->>'id')::uuid IS DISTINCT FROM v_group THEN
    RAISE EXCEPTION '_smoke_r1sec Caso3: member group summary failed';
  END IF;

  -- ── Caso 4: no-miembro NO ve group_world_summary ───────────
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  v_caught := false;
  BEGIN
    v_result := public.group_world_summary(v_group);
    RAISE EXCEPTION '_smoke_r1sec Caso4: should have been blocked';
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r1sec Caso4: expected 42501'; END IF;

  -- ── Caso 5: usuario sin autoridad NO puede grant OWN ───────
  v_caught := false;
  BEGIN
    v_right_id := public.grant_right(
      p_resource_id := v_resource, p_holder_actor_id := v_user_b,
      p_right_kind := 'OWN', p_percent := 100);
    RAISE EXCEPTION '_smoke_r1sec Caso5: should have been blocked';
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r1sec Caso5: expected 42501'; END IF;

  -- ── Caso 6: owner sí puede grant VIEW ──────────────────────
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_right_id := public.grant_right(
    p_resource_id := v_resource, p_holder_actor_id := v_user_b,
    p_right_kind := 'VIEW');
  IF v_right_id IS NULL THEN
    RAISE EXCEPTION '_smoke_r1sec Caso6: owner grant VIEW failed';
  END IF;
  IF NOT public.actor_has_right(v_user_b, v_resource, 'VIEW') THEN
    RAISE EXCEPTION '_smoke_r1sec Caso6: VIEW right not active';
  END IF;

  -- ── Caso 7: usuario sin autoridad NO puede create shareholder_of falso ──
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  v_caught := false;
  BEGIN
    v_rel_id := public.create_actor_relationship(
      p_subject_actor_id := v_user_a,
      p_relationship_type := 'shareholder_of',
      p_object_actor_id := v_other);
    RAISE EXCEPTION '_smoke_r1sec Caso7: should have been blocked';
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r1sec Caso7: expected 42501'; END IF;

  -- ── Caso 8: usuario autorizado sí puede crear relación ─────
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_rel_id := public.create_actor_relationship(
    p_subject_actor_id := v_user_a,
    p_relationship_type := 'shareholder_of',
    p_object_actor_id := v_other,
    p_metadata := '{"percent": 10, "source": "_smoke_r1sec"}'::jsonb);
  IF v_rel_id IS NULL THEN
    RAISE EXCEPTION '_smoke_r1sec Caso8: authorized create relationship failed';
  END IF;

  -- ── Caso 9: anon no puede ejecutar summaries sensibles ─────
  IF has_function_privilege('anon', 'public.group_world_summary(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.legal_entity_world_summary(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.actor_net_worth(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public._group_world_summary_unscoped(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public._legal_entity_world_summary_unscoped(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public._actor_net_worth_unscoped(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.list_actor_relationships(uuid, text, boolean)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.actor_has_right(uuid, uuid, text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.has_actor_authority(uuid, text)', 'EXECUTE') THEN
    RAISE EXCEPTION '_smoke_r1sec Caso9: anon can still execute a sensitive RPC';
  END IF;

  -- ── Caso 10: RLS enabled en tablas críticas ────────────────
  IF EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN ('action_catalog', 'group_rule_engine_quotas',
                        'resource_rights', 'actor_relationships', 'legal_entities',
                        'actors', 'resources', 'resource_owners')
      AND NOT c.relrowsecurity
  ) THEN
    RAISE EXCEPTION '_smoke_r1sec Caso10: a critical table still has RLS disabled';
  END IF;

  -- ── Cleanup ────────────────────────────────────────────────
  PERFORM set_config('request.jwt.claims', NULL, true);
  DELETE FROM public.actor_relationships WHERE id = v_rel_id;
  DELETE FROM public.resource_rights WHERE resource_id = v_resource;
  UPDATE public.resources SET archived_at = now() WHERE id = v_resource;

  RAISE NOTICE '_smoke_r1sec_actor_authority passed (10 casos)';
END;
$$;

REVOKE ALL ON FUNCTION public._smoke_r1sec_actor_authority() FROM PUBLIC, anon, authenticated;
