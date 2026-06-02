-- R.0D — Relationship Graph (ATOMIC)
--
-- Doctrina: actor_relationships ES SEMÁNTICA. NO reemplaza resource_rights.
--   resource_rights = derechos formales sobre recursos (OWN/USE/MANAGE/etc).
--   actor_relationships = grafo entre actores y/o recursos (relaciones semánticas
--     como shareholder_of, trustee_of, beneficiary_of, creditor_of, etc.).
--
-- Schema:
--   subject_actor_id NOT NULL (siempre actor)
--   object polimórfico: exactly one of (object_actor_id, object_resource_id) NOT NULL
--   Temporal bounds: starts_at, ends_at (active = starts NULL/≤now AND ends NULL/>now)
--
-- Whitelist 14 relationship_type:
--   owns, controls, member_of, admin_of, beneficiary_of, leased_to, managed_by,
--   employed_by, guarantor_of, trustee_of, shareholder_of, custodian_of,
--   debtor_to, creditor_of

-- ============================================================
-- STEP 1: CREATE TABLE actor_relationships
-- ============================================================
CREATE TABLE public.actor_relationships (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_actor_id   uuid NOT NULL REFERENCES public.actors(id) ON DELETE CASCADE,
  relationship_type  text NOT NULL CHECK (relationship_type IN (
    'owns','controls','member_of','admin_of','beneficiary_of','leased_to',
    'managed_by','employed_by','guarantor_of','trustee_of','shareholder_of',
    'custodian_of','debtor_to','creditor_of'
  )),
  object_actor_id    uuid REFERENCES public.actors(id) ON DELETE CASCADE,
  object_resource_id uuid REFERENCES public.resources(id) ON DELETE CASCADE,
  starts_at          timestamptz,
  ends_at            timestamptz,
  metadata           jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT actor_relationships_exactly_one_object CHECK (
    (object_actor_id IS NOT NULL AND object_resource_id IS NULL)
    OR
    (object_actor_id IS NULL AND object_resource_id IS NOT NULL)
  )
);

COMMENT ON TABLE public.actor_relationships IS
  'R.0D semantic relationship graph. Subject siempre actor. Object polimórfico actor|resource (exactly one NOT NULL). NO reemplaza resource_rights (que captura derechos formales); aquí van relaciones semánticas (shareholder_of, trustee_of, beneficiary_of, etc.).';

-- ============================================================
-- STEP 2: Indexes
-- ============================================================
CREATE INDEX idx_actor_relationships_subject ON public.actor_relationships(subject_actor_id);
CREATE INDEX idx_actor_relationships_object_actor ON public.actor_relationships(object_actor_id)
  WHERE object_actor_id IS NOT NULL;
CREATE INDEX idx_actor_relationships_object_resource ON public.actor_relationships(object_resource_id)
  WHERE object_resource_id IS NOT NULL;
CREATE INDEX idx_actor_relationships_type ON public.actor_relationships(relationship_type);
CREATE INDEX idx_actor_relationships_active
  ON public.actor_relationships(subject_actor_id, relationship_type)
  WHERE ends_at IS NULL;

-- ============================================================
-- STEP 3: RLS
-- ============================================================
ALTER TABLE public.actor_relationships ENABLE ROW LEVEL SECURITY;
CREATE POLICY actor_relationships_select_authenticated
  ON public.actor_relationships FOR SELECT TO authenticated USING (true);

-- ============================================================
-- STEP 4: Touch updated_at
-- ============================================================
CREATE OR REPLACE FUNCTION public._actor_relationships_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END;
$$;

CREATE TRIGGER trg_actor_relationships_touch_updated_at
  BEFORE UPDATE ON public.actor_relationships
  FOR EACH ROW EXECUTE FUNCTION public._actor_relationships_touch_updated_at();

-- ============================================================
-- STEP 5: RPC create_actor_relationship
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_actor_relationship(
  p_subject_actor_id   uuid,
  p_relationship_type  text,
  p_object_actor_id    uuid DEFAULT NULL,
  p_object_resource_id uuid DEFAULT NULL,
  p_starts_at          timestamptz DEFAULT NULL,
  p_ends_at            timestamptz DEFAULT NULL,
  p_metadata           jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  IF p_subject_actor_id IS NULL THEN
    RAISE EXCEPTION 'subject_actor_id required' USING errcode = '22023';
  END IF;
  IF p_relationship_type IS NULL THEN
    RAISE EXCEPTION 'relationship_type required' USING errcode = '22023';
  END IF;

  IF (p_object_actor_id IS NULL AND p_object_resource_id IS NULL)
     OR (p_object_actor_id IS NOT NULL AND p_object_resource_id IS NOT NULL) THEN
    RAISE EXCEPTION 'exactly one of object_actor_id or object_resource_id required' USING errcode = '22023';
  END IF;

  INSERT INTO public.actor_relationships
    (subject_actor_id, relationship_type, object_actor_id, object_resource_id,
     starts_at, ends_at, metadata)
  VALUES
    (p_subject_actor_id, p_relationship_type, p_object_actor_id, p_object_resource_id,
     p_starts_at, p_ends_at, COALESCE(p_metadata, '{}'::jsonb))
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_actor_relationship(uuid, text, uuid, uuid, timestamptz, timestamptz, jsonb) TO authenticated;

COMMENT ON FUNCTION public.create_actor_relationship(uuid, text, uuid, uuid, timestamptz, timestamptz, jsonb) IS
  'R.0D create new relationship. Subject siempre actor, object exactly one of actor|resource. Whitelist 14 types.';

-- ============================================================
-- STEP 6: RPC end_actor_relationship (soft end)
-- ============================================================
CREATE OR REPLACE FUNCTION public.end_actor_relationship(p_relationship_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  UPDATE public.actor_relationships
     SET ends_at = now()
   WHERE id = p_relationship_id
     AND ends_at IS NULL;

  IF NOT FOUND THEN
    RAISE NOTICE 'end_actor_relationship: % already ended or not found', p_relationship_id;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.end_actor_relationship(uuid) TO authenticated;

COMMENT ON FUNCTION public.end_actor_relationship(uuid) IS
  'R.0D soft end. ends_at=now(). Idempotente.';

-- ============================================================
-- STEP 7: RPC list_actor_relationships
-- ============================================================
CREATE OR REPLACE FUNCTION public.list_actor_relationships(
  p_actor_id          uuid,
  p_direction         text DEFAULT 'both',
  p_include_inactive  boolean DEFAULT false
) RETURNS TABLE (
  id                 uuid,
  subject_actor_id   uuid,
  relationship_type  text,
  object_actor_id    uuid,
  object_resource_id uuid,
  starts_at          timestamptz,
  ends_at            timestamptz,
  metadata           jsonb,
  created_at         timestamptz,
  direction          text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT ar.id, ar.subject_actor_id, ar.relationship_type,
         ar.object_actor_id, ar.object_resource_id,
         ar.starts_at, ar.ends_at, ar.metadata, ar.created_at,
         CASE
           WHEN ar.subject_actor_id = p_actor_id THEN 'out'
           WHEN ar.object_actor_id = p_actor_id THEN 'in'
           ELSE 'unknown'
         END AS direction
    FROM public.actor_relationships ar
   WHERE
     (
       (p_direction IN ('out','both') AND ar.subject_actor_id = p_actor_id)
       OR
       (p_direction IN ('in','both') AND ar.object_actor_id = p_actor_id)
     )
     AND (
       p_include_inactive
       OR (
         (ar.starts_at IS NULL OR ar.starts_at <= now())
         AND (ar.ends_at IS NULL OR ar.ends_at > now())
       )
     )
   ORDER BY ar.created_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.list_actor_relationships(uuid, text, boolean) TO authenticated, anon;

COMMENT ON FUNCTION public.list_actor_relationships(uuid, text, boolean) IS
  'R.0D list relationships donde actor es subject (out), object_actor (in) o both. Activos por default. p_include_inactive=true para histórico.';
