-- R.1-SEC.2 — Hardening de write RPCs actor-céntricos
--
-- Audit PR #131: grant_right / revoke_right / create_actor_relationship /
-- end_actor_relationship / update_legal_entity solo chequeaban autenticación,
-- no autorización. Cualquier usuario autenticado podía otorgarse OWN de cualquier
-- recurso, revocar rights ajenos o declararse shareholder de cualquier entidad.
--
-- Este slice compone autorización vía has_actor_authority (R.1-SEC.1) +
-- actor_has_right en los 5 RPCs de escritura. Además create_legal_entity
-- ahora crea la relación `controls` creator→entity (autoridad inicial).
--
-- NO se tocan los overloads legacy (grant_right 8-arg membership /
-- revoke_right 3-arg) — esos siguen operando sobre resource_right_subtype
-- vía compat view y son los que iOS llama hoy.

-- ============================================================
-- 1. grant_right (universal 9-arg) — autorización
-- ============================================================
-- Reglas R.1:
--   Right no-ejecutivo (USE/VIEW/MANAGE/...):
--     caller tiene MANAGE u OWN sobre el resource
--     OR has_actor_authority(canonical_owner_actor_id, 'resources.manage')
--   Right ejecutivo (OWN/SELL/TRANSFER/LIEN/PLEDGE):
--     caller tiene OWN sobre el resource
--     OR has_actor_authority(canonical_owner_actor_id, 'resources.transfer')
CREATE OR REPLACE FUNCTION public.grant_right(p_resource_id uuid, p_holder_actor_id uuid, p_right_kind text, p_percent numeric DEFAULT NULL::numeric, p_scope text DEFAULT NULL::text, p_starts_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_source_decision_id uuid DEFAULT NULL::uuid, p_metadata jsonb DEFAULT '{}'::jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_id          uuid;
  v_existing_id uuid;
  v_sentinel    uuid := '00000000-0000-0000-0000-000000000000';
  v_caller      uuid := auth.uid();
  v_resource    public.resources%ROWTYPE;
  v_authorized  boolean := false;
  v_executive   boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  IF p_resource_id IS NULL THEN
    RAISE EXCEPTION 'resource_id required' USING errcode = '22023';
  END IF;
  IF p_right_kind IS NULL THEN
    RAISE EXCEPTION 'right_kind required' USING errcode = '22023';
  END IF;

  SELECT * INTO v_resource FROM public.resources WHERE id = p_resource_id;
  IF v_resource.id IS NULL THEN
    RAISE EXCEPTION 'resource not found: %', p_resource_id USING errcode = 'P0002';
  END IF;

  -- ── Autorización R.1-SEC.2 ────────────────────────────────
  v_executive := p_right_kind IN ('OWN', 'SELL', 'TRANSFER', 'LIEN', 'PLEDGE');

  IF v_executive THEN
    v_authorized :=
      public.actor_has_right(v_caller, p_resource_id, 'OWN')
      OR (v_resource.canonical_owner_actor_id IS NOT NULL
          AND public.has_actor_authority(v_resource.canonical_owner_actor_id, 'resources.transfer'));
  ELSE
    v_authorized :=
      public.actor_has_right(v_caller, p_resource_id, 'MANAGE')
      OR public.actor_has_right(v_caller, p_resource_id, 'OWN')
      OR (v_resource.canonical_owner_actor_id IS NOT NULL
          AND public.has_actor_authority(v_resource.canonical_owner_actor_id, 'resources.manage'));
  END IF;

  IF NOT v_authorized THEN
    RAISE EXCEPTION 'not authorized to grant % right on resource %', p_right_kind, p_resource_id
      USING errcode = '42501';
  END IF;
  -- ──────────────────────────────────────────────────────────

  -- Find any matching row. Active rights primero, sino más reciente.
  SELECT id INTO v_existing_id
    FROM public.resource_rights
   WHERE resource_id = p_resource_id
     AND COALESCE(holder_actor_id, v_sentinel) = COALESCE(p_holder_actor_id, v_sentinel)
     AND right_kind = p_right_kind
   ORDER BY
     CASE WHEN revoked_at IS NULL AND expired_at IS NULL THEN 0 ELSE 1 END,
     granted_at DESC
   LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    -- UPSERT / UNDELETE
    UPDATE public.resource_rights
       SET percent            = p_percent,
           scope              = p_scope,
           starts_at          = p_starts_at,
           ends_at            = p_ends_at,
           source_decision_id = COALESCE(p_source_decision_id, source_decision_id),
           metadata           = metadata || COALESCE(p_metadata, '{}'::jsonb)
                                         || jsonb_build_object('granted_by_uid', v_caller),
           revoked_at         = NULL,
           expired_at         = NULL,
           granted_at         = now()
     WHERE id = v_existing_id;
    v_id := v_existing_id;
  ELSE
    INSERT INTO public.resource_rights
      (resource_id, holder_actor_id, right_kind, percent, scope,
       starts_at, ends_at, source_decision_id, metadata)
    VALUES
      (p_resource_id, p_holder_actor_id, p_right_kind, p_percent, p_scope,
       p_starts_at, p_ends_at, p_source_decision_id,
       COALESCE(p_metadata, '{}'::jsonb) || jsonb_build_object('granted_by_uid', v_caller))
    RETURNING id INTO v_id;
  END IF;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.grant_right(uuid, uuid, text, numeric, text, timestamp with time zone, timestamp with time zone, uuid, jsonb) IS
  'R.1-SEC.2 hardened: requiere MANAGE/OWN del caller o has_actor_authority(canonical_owner, resources.manage); kinds ejecutivos (OWN/SELL/TRANSFER/LIEN/PLEDGE) requieren OWN o resources.transfer. Universal rights (actor holder). Args: p_resource_id, p_holder_actor_id, p_right_kind, p_percent, p_scope, p_starts_at, p_ends_at, p_source_decision_id, p_metadata.';

-- ============================================================
-- 2. revoke_right (universal 1-arg) — autorización
-- ============================================================
-- Permitir si:
--   caller es holder_actor_id del right
--   OR caller tiene MANAGE/OWN sobre el resource
--   OR has_actor_authority(canonical_owner_actor_id, 'resources.manage')
CREATE OR REPLACE FUNCTION public.revoke_right(p_right_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller     uuid := auth.uid();
  v_right      public.resource_rights%ROWTYPE;
  v_owner      uuid;
  v_authorized boolean := false;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  SELECT * INTO v_right FROM public.resource_rights WHERE id = p_right_id;
  IF v_right.id IS NULL THEN
    RAISE NOTICE 'revoke_right: % not found', p_right_id;
    RETURN;
  END IF;

  IF v_right.revoked_at IS NOT NULL THEN
    -- idempotente: ya revocado
    RETURN;
  END IF;

  -- ── Autorización R.1-SEC.2 ────────────────────────────────
  SELECT canonical_owner_actor_id INTO v_owner
    FROM public.resources WHERE id = v_right.resource_id;

  v_authorized :=
    v_right.holder_actor_id = v_caller
    OR public.actor_has_right(v_caller, v_right.resource_id, 'MANAGE')
    OR public.actor_has_right(v_caller, v_right.resource_id, 'OWN')
    OR (v_owner IS NOT NULL AND public.has_actor_authority(v_owner, 'resources.manage'));

  IF NOT v_authorized THEN
    RAISE EXCEPTION 'not authorized to revoke right %', p_right_id
      USING errcode = '42501';
  END IF;
  -- ──────────────────────────────────────────────────────────

  UPDATE public.resource_rights
     SET revoked_at = now(),
         metadata   = metadata || jsonb_build_object('revoked_by_uid', v_caller)
   WHERE id = p_right_id
     AND revoked_at IS NULL;
END;
$$;

COMMENT ON FUNCTION public.revoke_right(uuid) IS
  'R.1-SEC.2 hardened: requiere ser holder del right, MANAGE/OWN sobre el resource, o has_actor_authority(canonical_owner, resources.manage). Soft revoke (revoked_at). Args: p_right_id.';

-- ============================================================
-- 3. create_actor_relationship — autorización
-- ============================================================
-- Permitir si:
--   subject_actor_id = auth.uid()  OR  has_actor_authority(subject, 'relationships.manage')
-- Tipos sensibles (shareholder_of/trustee_of/beneficiary_of/creditor_of/debtor_to/
-- guarantor_of/controls): requieren has_actor_authority(subject, 'relationships.manage')
-- (para person actors esto colapsa a subject = caller).
CREATE OR REPLACE FUNCTION public.create_actor_relationship(p_subject_actor_id uuid, p_relationship_type text, p_object_actor_id uuid DEFAULT NULL::uuid, p_object_resource_id uuid DEFAULT NULL::uuid, p_starts_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_metadata jsonb DEFAULT '{}'::jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_id        uuid;
  v_caller    uuid := auth.uid();
  v_sensitive boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  IF p_subject_actor_id IS NULL THEN
    RAISE EXCEPTION 'subject_actor_id required' USING errcode = '22023';
  END IF;
  IF p_relationship_type IS NULL THEN
    RAISE EXCEPTION 'relationship_type required' USING errcode = '22023';
  END IF;

  -- CHECK exactly one object (mirror del CHECK constraint para mejor error msg)
  IF (p_object_actor_id IS NULL AND p_object_resource_id IS NULL)
     OR (p_object_actor_id IS NOT NULL AND p_object_resource_id IS NOT NULL) THEN
    RAISE EXCEPTION 'exactly one of object_actor_id or object_resource_id required' USING errcode = '22023';
  END IF;

  -- ── Autorización R.1-SEC.2 ────────────────────────────────
  v_sensitive := p_relationship_type IN
    ('shareholder_of', 'trustee_of', 'beneficiary_of', 'creditor_of',
     'debtor_to', 'guarantor_of', 'controls');

  IF v_sensitive THEN
    IF NOT public.has_actor_authority(p_subject_actor_id, 'relationships.manage') THEN
      RAISE EXCEPTION 'not authorized to create % relationship for subject %', p_relationship_type, p_subject_actor_id
        USING errcode = '42501';
    END IF;
  ELSE
    IF p_subject_actor_id <> v_caller
       AND NOT public.has_actor_authority(p_subject_actor_id, 'relationships.manage') THEN
      RAISE EXCEPTION 'not authorized to create relationship for subject %', p_subject_actor_id
        USING errcode = '42501';
    END IF;
  END IF;
  -- ──────────────────────────────────────────────────────────

  INSERT INTO public.actor_relationships
    (subject_actor_id, relationship_type, object_actor_id, object_resource_id,
     starts_at, ends_at, metadata)
  VALUES
    (p_subject_actor_id, p_relationship_type, p_object_actor_id, p_object_resource_id,
     p_starts_at, p_ends_at,
     COALESCE(p_metadata, '{}'::jsonb) || jsonb_build_object('created_by_uid', v_caller))
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.create_actor_relationship(uuid, text, uuid, uuid, timestamp with time zone, timestamp with time zone, jsonb) IS
  'R.1-SEC.2 hardened: requiere subject=caller o has_actor_authority(subject, relationships.manage); tipos sensibles siempre requieren authority. Registra created_by_uid en metadata.';

-- ============================================================
-- 4. end_actor_relationship — autorización
-- ============================================================
-- Permitir si:
--   has_actor_authority(subject, 'relationships.manage')   [person → subject = caller]
--   OR (object_actor_id existe AND has_actor_authority(object_actor, 'relationships.manage'))
--   OR metadata.created_by_uid = auth.uid()
CREATE OR REPLACE FUNCTION public.end_actor_relationship(p_relationship_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller     uuid := auth.uid();
  v_rel        public.actor_relationships%ROWTYPE;
  v_authorized boolean := false;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  SELECT * INTO v_rel FROM public.actor_relationships WHERE id = p_relationship_id;
  IF v_rel.id IS NULL THEN
    RAISE NOTICE 'end_actor_relationship: % not found', p_relationship_id;
    RETURN;
  END IF;

  IF v_rel.ends_at IS NOT NULL THEN
    -- idempotente: ya terminada
    RETURN;
  END IF;

  -- ── Autorización R.1-SEC.2 ────────────────────────────────
  v_authorized :=
    public.has_actor_authority(v_rel.subject_actor_id, 'relationships.manage')
    OR (v_rel.object_actor_id IS NOT NULL
        AND public.has_actor_authority(v_rel.object_actor_id, 'relationships.manage'))
    OR (v_rel.metadata->>'created_by_uid')::uuid = v_caller;

  IF NOT v_authorized THEN
    RAISE EXCEPTION 'not authorized to end relationship %', p_relationship_id
      USING errcode = '42501';
  END IF;
  -- ──────────────────────────────────────────────────────────

  UPDATE public.actor_relationships
     SET ends_at  = now(),
         metadata = metadata || jsonb_build_object('ended_by_uid', v_caller)
   WHERE id = p_relationship_id
     AND ends_at IS NULL;
END;
$$;

COMMENT ON FUNCTION public.end_actor_relationship(uuid) IS
  'R.1-SEC.2 hardened: requiere authority sobre subject u object (relationships.manage), o ser el creador (metadata.created_by_uid).';

-- ============================================================
-- 5. update_legal_entity — autorización via entity.manage
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_legal_entity(p_id uuid, p_display_name text DEFAULT NULL::text, p_entity_type text DEFAULT NULL::text, p_tax_id text DEFAULT NULL::text, p_jurisdiction text DEFAULT NULL::text, p_metadata jsonb DEFAULT NULL::jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_exists boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.legal_entities WHERE id = p_id) INTO v_exists;
  IF NOT v_exists THEN
    RAISE EXCEPTION 'legal_entity not found: %', p_id USING errcode = 'P0002';
  END IF;

  -- ── Autorización R.1-SEC.2 ────────────────────────────────
  IF NOT public.has_actor_authority(p_id, 'entity.manage') THEN
    RAISE EXCEPTION 'not authorized to manage legal entity %', p_id
      USING errcode = '42501';
  END IF;
  -- ──────────────────────────────────────────────────────────

  UPDATE public.actors
     SET display_name = COALESCE(p_display_name, display_name),
         metadata     = CASE WHEN p_metadata IS NOT NULL THEN metadata || p_metadata ELSE metadata END
   WHERE id = p_id;

  UPDATE public.legal_entities
     SET entity_type  = COALESCE(p_entity_type, entity_type),
         tax_id       = COALESCE(p_tax_id, tax_id),
         jurisdiction = COALESCE(p_jurisdiction, jurisdiction),
         metadata     = CASE WHEN p_metadata IS NOT NULL THEN metadata || p_metadata ELSE metadata END
   WHERE id = p_id;
END;
$$;

COMMENT ON FUNCTION public.update_legal_entity(uuid, text, text, text, text, jsonb) IS
  'R.1-SEC.2 hardened: requiere has_actor_authority(entity, entity.manage) — relación controls/trustee_of/admin_of activa o creator.';

-- ============================================================
-- 6. create_legal_entity — wiring de autoridad inicial (creator controls entity)
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_legal_entity(p_display_name text, p_entity_type text, p_tax_id text DEFAULT NULL::text, p_jurisdiction text DEFAULT NULL::text, p_metadata jsonb DEFAULT '{}'::jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_id     uuid := gen_random_uuid();
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  IF p_display_name IS NULL OR length(trim(p_display_name)) = 0 THEN
    RAISE EXCEPTION 'display_name required' USING errcode = '22023';
  END IF;

  IF p_entity_type IS NULL OR length(trim(p_entity_type)) = 0 THEN
    RAISE EXCEPTION 'entity_type required' USING errcode = '22023';
  END IF;

  INSERT INTO public.actors (id, actor_kind, display_name, metadata)
  VALUES (
    v_id,
    'legal_entity',
    p_display_name,
    jsonb_build_object('created_by_uid', v_caller) || COALESCE(p_metadata, '{}'::jsonb)
  );

  INSERT INTO public.legal_entities (id, entity_type, tax_id, jurisdiction, metadata)
  VALUES (v_id, p_entity_type, p_tax_id, p_jurisdiction, COALESCE(p_metadata, '{}'::jsonb));

  -- R.1-SEC.2: autoridad inicial — creator controla la entity.
  -- INSERT directo (no via create_actor_relationship: la entity recién nace,
  -- el creator ES la autoridad inicial por definición).
  INSERT INTO public.actor_relationships
    (subject_actor_id, relationship_type, object_actor_id, metadata)
  VALUES
    (v_caller, 'controls', v_id,
     jsonb_build_object('source', 'create_legal_entity', 'created_by_uid', v_caller));

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.create_legal_entity(text, text, text, text, jsonb) IS
  'R.1-SEC.2: crea actor legal_entity + legal_entities row + relación controls creator→entity (autoridad inicial para has_actor_authority).';
