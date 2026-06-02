-- R.1-REL Smoke — _smoke_r1rel_relationship_wiring()
--
-- 5 casos requeridos por el plan R.1:
--   1. Active membership genera member_of (backfill global + trigger en INSERT fresco).
--   2. Removed membership cierra relationship.
--   3. list_actor_relationships refleja member_of.
--   4. Unauthorized user no puede crear relationship sensible.
--   5. Authorized user sí puede.

CREATE OR REPLACE FUNCTION public._smoke_r1rel_relationship_wiring()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_user_a    uuid;   -- usuario de prueba (será nuevo member)
  v_user_b    uuid;   -- usuario sin autoridad
  v_group     uuid;   -- grupo donde user_a NO es miembro todavía
  v_mship_id  uuid;
  v_rel_id    uuid;
  v_entity_id uuid;
  v_count     integer;
  v_caught    boolean;
BEGIN
  -- ── Caso 1a: invariante global — toda membership activa tiene member_of ──
  SELECT count(*) INTO v_count
    FROM public.group_memberships gm
   WHERE gm.status = 'active'
     AND gm.user_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.actors a WHERE a.id = gm.user_id)
     AND EXISTS (SELECT 1 FROM public.actors a WHERE a.id = gm.group_id)
     AND NOT EXISTS (
       SELECT 1 FROM public.actor_relationships ar
       WHERE ar.subject_actor_id = gm.user_id
         AND ar.object_actor_id = gm.group_id
         AND ar.relationship_type = 'member_of'
         AND ar.ends_at IS NULL
     );
  IF v_count > 0 THEN
    RAISE EXCEPTION '_smoke_r1rel Caso1a: % memberships activas sin member_of', v_count;
  END IF;

  -- ── Setup: user + group donde NO es miembro ────────────────
  SELECT p.id, g.id INTO v_user_a, v_group
    FROM public.profiles p
    CROSS JOIN public.groups g
   WHERE EXISTS (SELECT 1 FROM public.actors a WHERE a.id = p.id AND a.actor_kind = 'person')
     AND EXISTS (SELECT 1 FROM public.actors a WHERE a.id = g.id AND a.actor_kind = 'group')
     AND NOT EXISTS (
       SELECT 1 FROM public.group_memberships gm
       WHERE gm.user_id = p.id AND gm.group_id = g.id
     )
   LIMIT 1;
  IF v_user_a IS NULL THEN
    RAISE EXCEPTION '_smoke_r1rel setup: no (user, group) pair without membership found';
  END IF;

  SELECT p.id INTO v_user_b FROM public.profiles p
   WHERE p.id <> v_user_a
     AND EXISTS (SELECT 1 FROM public.actors a WHERE a.id = p.id AND a.actor_kind = 'person')
   LIMIT 1;

  -- ── Caso 1b: INSERT membership activa → trigger crea member_of ──
  INSERT INTO public.group_memberships
    (group_id, user_id, status, membership_type, joined_via, joined_at)
  VALUES
    (v_group, v_user_a, 'active', 'member', 'admin_add', now())
  RETURNING id INTO v_mship_id;

  SELECT ar.id INTO v_rel_id
    FROM public.actor_relationships ar
   WHERE ar.subject_actor_id = v_user_a
     AND ar.object_actor_id = v_group
     AND ar.relationship_type = 'member_of'
     AND ar.ends_at IS NULL;
  IF v_rel_id IS NULL THEN
    RAISE EXCEPTION '_smoke_r1rel Caso1b: trigger no creó member_of para membership nueva';
  END IF;

  -- ── Caso 3: list_actor_relationships refleja member_of ─────
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  IF NOT EXISTS (
    SELECT 1 FROM public.list_actor_relationships(v_user_a, 'out', false) lr
    WHERE lr.relationship_type = 'member_of'
      AND lr.object_actor_id = v_group
  ) THEN
    RAISE EXCEPTION '_smoke_r1rel Caso3: member_of no aparece en list_actor_relationships';
  END IF;
  PERFORM set_config('request.jwt.claims', NULL, true);

  -- ── Caso 2: removed membership cierra relationship ─────────
  UPDATE public.group_memberships
     SET status = 'removed', removed_at = now(), removed_reason = '_smoke_r1rel'
   WHERE id = v_mship_id;

  IF EXISTS (
    SELECT 1 FROM public.actor_relationships ar
    WHERE ar.id = v_rel_id AND ar.ends_at IS NULL
  ) THEN
    RAISE EXCEPTION '_smoke_r1rel Caso2: member_of sigue activa después de remove';
  END IF;

  -- ── Caso 5 (setup): user_a crea legal entity (controls automático) ──
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_entity_id := public.create_legal_entity(
    p_display_name := '_smoke_r1rel Entity SA',
    p_entity_type := 'company',
    p_jurisdiction := 'MX');

  -- ── Caso 4: usuario SIN autoridad no puede crear relationship sensible ──
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  v_caught := false;
  BEGIN
    PERFORM public.add_legal_entity_shareholder(
      p_entity_actor_id := v_entity_id,
      p_shareholder_actor_id := v_user_b,
      p_percent := 50);
    RAISE EXCEPTION '_smoke_r1rel Caso4: should have been blocked';
  EXCEPTION
    WHEN insufficient_privilege THEN v_caught := true;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION '_smoke_r1rel Caso4: expected 42501'; END IF;

  -- ── Caso 5: usuario autorizado (controller) sí puede ───────
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_rel_id := public.add_legal_entity_shareholder(
    p_entity_actor_id := v_entity_id,
    p_shareholder_actor_id := v_user_b,
    p_percent := 25);
  IF v_rel_id IS NULL THEN
    RAISE EXCEPTION '_smoke_r1rel Caso5: authorized shareholder declaration failed';
  END IF;
  -- Verificar que la relación quedó en el grafo
  IF NOT EXISTS (
    SELECT 1 FROM public.actor_relationships ar
    WHERE ar.id = v_rel_id
      AND ar.subject_actor_id = v_user_b
      AND ar.object_actor_id = v_entity_id
      AND ar.relationship_type = 'shareholder_of'
  ) THEN
    RAISE EXCEPTION '_smoke_r1rel Caso5: shareholder_of relationship not found in graph';
  END IF;

  -- ── Cleanup ────────────────────────────────────────────────
  PERFORM set_config('request.jwt.claims', NULL, true);
  -- relaciones de la entity + member_of de prueba
  DELETE FROM public.actor_relationships
   WHERE object_actor_id = v_entity_id
      OR (subject_actor_id = v_user_a AND object_actor_id = v_group AND relationship_type = 'member_of');
  -- legal entity de prueba
  DELETE FROM public.legal_entities WHERE id = v_entity_id;
  DELETE FROM public.actors WHERE id = v_entity_id AND actor_kind = 'legal_entity';
  -- membership de prueba (best-effort: guards append-only pueden bloquear el DELETE)
  BEGIN
    DELETE FROM public.group_memberships WHERE id = v_mship_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '_smoke_r1rel cleanup: membership % queda como removed (residuo aceptado)', v_mship_id;
  END;

  RAISE NOTICE '_smoke_r1rel_relationship_wiring passed (5 casos)';
END;
$$;

REVOKE ALL ON FUNCTION public._smoke_r1rel_relationship_wiring() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._smoke_r1rel_relationship_wiring() IS
  'Smoke R.1-REL: 5 casos de relationship wiring (membership→member_of projection, list, legal entity helpers con autorización).';
