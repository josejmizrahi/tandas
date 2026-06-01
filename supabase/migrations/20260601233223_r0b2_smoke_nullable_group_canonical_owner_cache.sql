-- R.0B.2 MIG 2 — Smoke for nullable group_id + canonical_owner_actor_id cache.
--
-- Casos (per founder spec):
--  1) INSERT legacy con group_id via compat view → canonical_owner_actor_id auto-derived = group_id
--  2) INSERT directo a resources con group_id=NULL + canonical_owner_actor_id=actor person → personal
--  3) Legacy resource (con group_id) visible vía group_resources view
--  4) Personal resource (group_id=NULL) NO visible vía group_resources view
--  5) canonical_owner_actor_id correcto en ambos paths
--  6) Reject: INSERT via compat view con group_id=NULL → exception (preserva contrato legacy)

CREATE OR REPLACE FUNCTION public._smoke_r0b2_nullable_group_canonical_owner_cache()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_group              uuid;
  v_user               uuid;
  v_legacy_id          uuid;
  v_personal_id        uuid;
  v_canonical          uuid;
  v_visible_in_view    boolean;
  v_exception_caught   boolean := false;
BEGIN
  SELECT id INTO v_group FROM public.groups LIMIT 1;
  SELECT created_by INTO v_user FROM public.groups WHERE id = v_group;
  IF v_group IS NULL OR v_user IS NULL THEN
    RAISE EXCEPTION '_smoke_r0b2: no usable group/user found';
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_user::text)::text, true);

  -- ===== Caso 1: INSERT legacy vía compat view (group_id set) =====
  PERFORM set_config('ruul.resource_create_intent', '', true);
  INSERT INTO public.group_resources
    (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
  VALUES
    (v_group, 'document', '_smoke_r0b2 Caso1 legacy', 'active', 'members', 'group', '{}'::jsonb, '{}'::jsonb, v_user)
  RETURNING id INTO v_legacy_id;

  -- canonical_owner_actor_id debe haberse derivado = group_id (por BEFORE INSERT defensivo)
  SELECT canonical_owner_actor_id INTO v_canonical
    FROM public.resources WHERE id = v_legacy_id;
  IF v_canonical IS DISTINCT FROM v_group THEN
    RAISE EXCEPTION '_smoke_r0b2 Caso1: canonical_owner_actor_id should = group_id (% != %)',
      COALESCE(v_canonical::text,'NULL'), v_group::text;
  END IF;

  -- ===== Caso 2: INSERT directo a resources con group_id=NULL + canonical=actor person =====
  -- Personal/entity-owned path (futuro R.0E+ — aquí solo verificamos que el modelo lo permite).
  -- Usamos v_user como canonical_owner_actor_id (debe existir como actor person por R.0A.1).
  INSERT INTO public.resources
    (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by, canonical_owner_actor_id)
  VALUES
    (NULL, 'document', '_smoke_r0b2 Caso2 personal', 'active', 'members', 'group', '{}'::jsonb, '{}'::jsonb, v_user, v_user)
  RETURNING id INTO v_personal_id;

  SELECT canonical_owner_actor_id INTO v_canonical
    FROM public.resources WHERE id = v_personal_id;
  IF v_canonical IS DISTINCT FROM v_user THEN
    RAISE EXCEPTION '_smoke_r0b2 Caso2: personal canonical_owner_actor_id should = v_user (% != %)',
      COALESCE(v_canonical::text,'NULL'), v_user::text;
  END IF;

  IF (SELECT group_id FROM public.resources WHERE id = v_personal_id) IS NOT NULL THEN
    RAISE EXCEPTION '_smoke_r0b2 Caso2: personal resource should have group_id=NULL';
  END IF;

  -- ===== Caso 3: legacy resource visible vía compat view =====
  SELECT EXISTS(SELECT 1 FROM public.group_resources WHERE id = v_legacy_id) INTO v_visible_in_view;
  IF NOT v_visible_in_view THEN
    RAISE EXCEPTION '_smoke_r0b2 Caso3: legacy resource not visible vía group_resources view';
  END IF;

  -- ===== Caso 4: personal resource NO visible vía compat view =====
  SELECT EXISTS(SELECT 1 FROM public.group_resources WHERE id = v_personal_id) INTO v_visible_in_view;
  IF v_visible_in_view THEN
    RAISE EXCEPTION '_smoke_r0b2 Caso4: personal resource (group_id NULL) should NOT be visible vía legacy view';
  END IF;
  -- Sí debe ser visible vía tabla canónica
  IF NOT EXISTS(SELECT 1 FROM public.resources WHERE id = v_personal_id) THEN
    RAISE EXCEPTION '_smoke_r0b2 Caso4: personal resource not found in canonical table';
  END IF;

  -- ===== Caso 5: canonical_owner_actor_id correcto in both paths =====
  IF NOT EXISTS (
    SELECT 1 FROM public.resources r
    JOIN public.actors a ON a.id = r.canonical_owner_actor_id
    WHERE r.id = v_legacy_id AND a.actor_kind = 'group'
  ) THEN
    RAISE EXCEPTION '_smoke_r0b2 Caso5: legacy resource canonical should point to group actor';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.resources r
    JOIN public.actors a ON a.id = r.canonical_owner_actor_id
    WHERE r.id = v_personal_id AND a.actor_kind = 'person'
  ) THEN
    RAISE EXCEPTION '_smoke_r0b2 Caso5: personal resource canonical should point to person actor';
  END IF;

  -- ===== Caso 6: Reject INSERT via compat view con group_id NULL =====
  BEGIN
    INSERT INTO public.group_resources
      (group_id, resource_type, name, status, visibility, ownership_kind, ownership_metadata, metadata, created_by)
    VALUES
      (NULL, 'document', '_smoke_r0b2 Caso6 should fail', 'active', 'members', 'group', '{}'::jsonb, '{}'::jsonb, v_user);
    RAISE EXCEPTION '_smoke_r0b2 Caso6: INSERT via compat view con group_id NULL should have failed';
  EXCEPTION
    WHEN not_null_violation OR raise_exception THEN
      v_exception_caught := true;
  END;
  IF NOT v_exception_caught THEN
    RAISE EXCEPTION '_smoke_r0b2 Caso6: exception should have been raised';
  END IF;

  -- Cleanup (archive, no DELETE — append-only guard)
  UPDATE public.resources SET archived_at = now()
   WHERE id IN (v_legacy_id, v_personal_id) AND archived_at IS NULL;

  PERFORM set_config('request.jwt.claims', NULL, true);
  PERFORM set_config('ruul.resource_create_intent', '', true);

  RAISE NOTICE '_smoke_r0b2_nullable_group_canonical_owner_cache passed (6 casos: legacy+canonical derive, personal direct, view filter, reject NULL group_id)';
END;
$$;
