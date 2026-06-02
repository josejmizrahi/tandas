-- R.1-REL.2 — Legal entity relationship helpers
--
-- Helpers seguros para gestionar relaciones de legal entities, gated por
-- has_actor_authority(entity, 'entity.manage') — solo quien controla la entity
-- puede declarar controllers/beneficiaries/shareholders sobre ella.
--
-- Estos helpers son la vía correcta para relaciones donde el SUBJECT es un tercero
-- (el hardened create_actor_relationship exige autoridad sobre el subject; aquí
-- la autoridad relevante es sobre la ENTITY object, así que se hace INSERT directo
-- tras validar autoridad sobre la entity).
--
-- Idempotente: si ya existe relación activa equivalente, retorna su id.

-- ============================================================
-- Helper interno común
-- ============================================================
CREATE OR REPLACE FUNCTION public._add_legal_entity_relationship(
  p_entity_actor_id uuid,
  p_subject_actor_id uuid,
  p_relationship_type text,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_id     uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;
  IF p_entity_actor_id IS NULL OR p_subject_actor_id IS NULL THEN
    RAISE EXCEPTION 'entity_actor_id and subject_actor_id required' USING errcode = '22023';
  END IF;

  -- La entity debe existir como legal_entity actor
  IF NOT EXISTS (
    SELECT 1 FROM public.actors a
    WHERE a.id = p_entity_actor_id AND a.actor_kind = 'legal_entity'
  ) THEN
    RAISE EXCEPTION 'legal_entity actor not found: %', p_entity_actor_id USING errcode = 'P0002';
  END IF;

  -- El subject debe existir como actor
  IF NOT EXISTS (SELECT 1 FROM public.actors a WHERE a.id = p_subject_actor_id) THEN
    RAISE EXCEPTION 'subject actor not found: %', p_subject_actor_id USING errcode = 'P0002';
  END IF;

  -- ── Autorización: solo quien controla la entity ────────────
  IF NOT public.has_actor_authority(p_entity_actor_id, 'entity.manage') THEN
    RAISE EXCEPTION 'not authorized to manage relationships of legal entity %', p_entity_actor_id
      USING errcode = '42501';
  END IF;

  -- Idempotencia: relación activa equivalente → retornar la existente
  SELECT ar.id INTO v_id
    FROM public.actor_relationships ar
   WHERE ar.subject_actor_id = p_subject_actor_id
     AND ar.object_actor_id = p_entity_actor_id
     AND ar.relationship_type = p_relationship_type
     AND (ar.ends_at IS NULL OR ar.ends_at > now())
   LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  INSERT INTO public.actor_relationships
    (subject_actor_id, relationship_type, object_actor_id, metadata)
  VALUES
    (p_subject_actor_id, p_relationship_type, p_entity_actor_id,
     COALESCE(p_metadata, '{}'::jsonb) || jsonb_build_object(
       'source', 'r1rel_legal_entity_helper',
       'created_by_uid', v_caller))
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public._add_legal_entity_relationship(uuid, uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._add_legal_entity_relationship(uuid, uuid, text, jsonb) TO service_role;

-- ============================================================
-- 1. add_legal_entity_controller
-- ============================================================
CREATE OR REPLACE FUNCTION public.add_legal_entity_controller(
  p_entity_actor_id uuid,
  p_controller_actor_id uuid,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  SELECT public._add_legal_entity_relationship(
    p_entity_actor_id, p_controller_actor_id, 'controls', p_metadata);
$$;

COMMENT ON FUNCTION public.add_legal_entity_controller(uuid, uuid, jsonb) IS
  'R.1-REL.2: declara controls controller→entity. Gated: has_actor_authority(entity, entity.manage).';

-- ============================================================
-- 2. add_legal_entity_beneficiary
-- ============================================================
CREATE OR REPLACE FUNCTION public.add_legal_entity_beneficiary(
  p_entity_actor_id uuid,
  p_beneficiary_actor_id uuid,
  p_percent numeric DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  SELECT public._add_legal_entity_relationship(
    p_entity_actor_id, p_beneficiary_actor_id, 'beneficiary_of',
    COALESCE(p_metadata, '{}'::jsonb)
      || CASE WHEN p_percent IS NOT NULL
              THEN jsonb_build_object('percent', p_percent)
              ELSE '{}'::jsonb END);
$$;

COMMENT ON FUNCTION public.add_legal_entity_beneficiary(uuid, uuid, numeric, jsonb) IS
  'R.1-REL.2: declara beneficiary_of beneficiary→entity. Gated: has_actor_authority(entity, entity.manage).';

-- ============================================================
-- 3. add_legal_entity_shareholder
-- ============================================================
CREATE OR REPLACE FUNCTION public.add_legal_entity_shareholder(
  p_entity_actor_id uuid,
  p_shareholder_actor_id uuid,
  p_percent numeric DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  SELECT public._add_legal_entity_relationship(
    p_entity_actor_id, p_shareholder_actor_id, 'shareholder_of',
    COALESCE(p_metadata, '{}'::jsonb)
      || CASE WHEN p_percent IS NOT NULL
              THEN jsonb_build_object('percent', p_percent)
              ELSE '{}'::jsonb END);
$$;

COMMENT ON FUNCTION public.add_legal_entity_shareholder(uuid, uuid, numeric, jsonb) IS
  'R.1-REL.2: declara shareholder_of shareholder→entity. Gated: has_actor_authority(entity, entity.manage).';

-- ============================================================
-- Grants: authenticated only (la autorización real está dentro)
-- ============================================================
REVOKE ALL ON FUNCTION public.add_legal_entity_controller(uuid, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_legal_entity_controller(uuid, uuid, jsonb) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.add_legal_entity_beneficiary(uuid, uuid, numeric, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_legal_entity_beneficiary(uuid, uuid, numeric, jsonb) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.add_legal_entity_shareholder(uuid, uuid, numeric, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_legal_entity_shareholder(uuid, uuid, numeric, jsonb) TO authenticated, service_role;
