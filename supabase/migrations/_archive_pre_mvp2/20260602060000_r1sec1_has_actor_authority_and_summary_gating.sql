-- R.1-SEC.1 — Actor Authority & Auth Gating en read RPCs
--
-- Audit PR #131 hallazgos críticos resueltos en este slice:
--   1. has_actor_authority (doctrina D4) no existía → se crea.
--   2. group_world_summary / legal_entity_world_summary / actor_net_worth eran
--      SECURITY DEFINER ejecutables por anon sin gating → se gatean + REVOKE anon.
--   3. list_actor_relationships / actor_has_right ejecutables por anon → REVOKE anon
--      + list filtra por participación cuando el caller no tiene autoridad.
--
-- Estrategia: rename de las funciones originales a *_unscoped (internas, sin grants
-- públicos) + wrappers gated con el mismo nombre/signature. Cero cambios a la lógica
-- de agregación original. Idempotente (guards en DO blocks).

-- ============================================================
-- 1. has_actor_authority(p_actor_id, p_action) — doctrina D4
-- ============================================================
-- Person actor       → autoridad solo si auth.uid() = actor_id
-- Group actor        → has_group_permission(actor_id, action) (groups.id = actors.id)
--                      + mapping doctrina R.1 → permission keys existentes del catálogo
-- Legal entity actor → relación activa controls/trustee_of/admin_of del caller
--                      sobre la entity (actor_relationships), o creator fallback
CREATE OR REPLACE FUNCTION public.has_actor_authority(p_actor_id uuid, p_action text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_kind   text;
  v_mapped text;
BEGIN
  IF v_caller IS NULL OR p_actor_id IS NULL OR p_action IS NULL THEN
    RETURN false;
  END IF;

  SELECT actor_kind INTO v_kind FROM public.actors WHERE id = p_actor_id;
  IF v_kind IS NULL THEN
    RETURN false;
  END IF;

  -- Person actor: solo el propio usuario tiene autoridad sobre sí mismo
  IF v_kind = 'person' THEN
    RETURN v_caller = p_actor_id;
  END IF;

  -- Group actor: governance interna del grupo (groups.id = actors.id por R.0A D1)
  IF v_kind = 'group' THEN
    -- Key directa (forward-compat si el catálogo agrega keys actor-céntricas)
    IF public.has_group_permission(p_actor_id, p_action) THEN
      RETURN true;
    END IF;
    -- Mapping acciones doctrina R.1 → permission keys existentes (catálogo `permissions`)
    v_mapped := CASE p_action
      WHEN 'context.view'         THEN 'group.read'
      WHEN 'finance.view'         THEN 'records.read'
      WHEN 'resources.view'       THEN 'resources.read'
      WHEN 'resources.manage'     THEN 'resources.manage_ownership'
      WHEN 'relationships.view'   THEN 'group.read'
      WHEN 'relationships.manage' THEN 'group.update'
      WHEN 'entity.manage'        THEN 'group.update'
      ELSE NULL
    END;
    IF v_mapped IS NOT NULL THEN
      RETURN public.has_group_permission(p_actor_id, v_mapped);
    END IF;
    RETURN false;
  END IF;

  -- Legal entity actor: caller con relación activa de control sobre la entity
  IF v_kind = 'legal_entity' THEN
    RETURN EXISTS (
      SELECT 1 FROM public.actor_relationships ar
      WHERE ar.object_actor_id = p_actor_id
        AND ar.subject_actor_id = v_caller
        AND ar.relationship_type IN ('controls', 'trustee_of', 'admin_of')
        AND (ar.starts_at IS NULL OR ar.starts_at <= now())
        AND (ar.ends_at IS NULL OR ar.ends_at > now())
    )
    -- Creator fallback: cubre entities creadas antes del wiring R.1-REL.2
    OR EXISTS (
      SELECT 1 FROM public.actors a
      WHERE a.id = p_actor_id
        AND a.metadata->>'created_by_uid' = v_caller::text
    );
  END IF;

  RETURN false;
END;
$$;

COMMENT ON FUNCTION public.has_actor_authority(uuid, text) IS
  'R.1-SEC.1 doctrina D4: ¿el caller (auth.uid()) tiene autoridad de governance interna sobre el actor para esta acción? person=self, group=has_group_permission(+mapping), legal_entity=controls/trustee_of/admin_of relationship o creator.';

REVOKE ALL ON FUNCTION public.has_actor_authority(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_actor_authority(uuid, text) TO authenticated, service_role;

-- ============================================================
-- 2. actor_net_worth — rename a _unscoped + wrapper gated
-- ============================================================
DO $$
BEGIN
  IF to_regprocedure('public._actor_net_worth_unscoped(uuid)') IS NULL THEN
    ALTER FUNCTION public.actor_net_worth(uuid) RENAME TO _actor_net_worth_unscoped;
  END IF;
END $$;

REVOKE ALL ON FUNCTION public._actor_net_worth_unscoped(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._actor_net_worth_unscoped(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.actor_net_worth(p_actor_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_kind   text;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'actor_id required' USING errcode = '22023';
  END IF;
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  SELECT actor_kind INTO v_kind FROM public.actors WHERE id = p_actor_id;

  -- Gating R.1-SEC.1:
  --   self  OR  miembro activo del grupo (actor group)  OR  has_actor_authority(finance.view)
  IF v_caller = p_actor_id
     OR (v_kind = 'group' AND public.is_group_member(p_actor_id))
     OR public.has_actor_authority(p_actor_id, 'finance.view') THEN
    RETURN public._actor_net_worth_unscoped(p_actor_id);
  END IF;

  RAISE EXCEPTION 'not authorized to view net worth of actor %', p_actor_id
    USING errcode = '42501';
END;
$$;

COMMENT ON FUNCTION public.actor_net_worth(uuid) IS
  'R.1-SEC.1 gated wrapper sobre _actor_net_worth_unscoped. Permite: self, miembro activo (group actor), o has_actor_authority(actor, finance.view).';

REVOKE ALL ON FUNCTION public.actor_net_worth(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actor_net_worth(uuid) TO authenticated, service_role;

-- ============================================================
-- 3. group_world_summary — rename a _unscoped + wrapper gated
-- ============================================================
DO $$
BEGIN
  IF to_regprocedure('public._group_world_summary_unscoped(uuid)') IS NULL THEN
    ALTER FUNCTION public.group_world_summary(uuid) RENAME TO _group_world_summary_unscoped;
  END IF;
END $$;

REVOKE ALL ON FUNCTION public._group_world_summary_unscoped(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._group_world_summary_unscoped(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.group_world_summary(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF p_group_id IS NULL THEN
    RAISE EXCEPTION 'group_id required' USING errcode = '22023';
  END IF;
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  -- Gating R.1-SEC.1: miembro activo del grupo OR has_actor_authority(context.view)
  IF public.is_group_member(p_group_id)
     OR public.has_actor_authority(p_group_id, 'context.view') THEN
    RETURN public._group_world_summary_unscoped(p_group_id);
  END IF;

  RAISE EXCEPTION 'not authorized to view group world summary of %', p_group_id
    USING errcode = '42501';
END;
$$;

COMMENT ON FUNCTION public.group_world_summary(uuid) IS
  'R.1-SEC.1 gated wrapper sobre _group_world_summary_unscoped. Permite: miembro activo del grupo o has_actor_authority(group, context.view).';

REVOKE ALL ON FUNCTION public.group_world_summary(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.group_world_summary(uuid) TO authenticated, service_role;

-- ============================================================
-- 4. legal_entity_world_summary — rename a _unscoped + wrapper gated
-- ============================================================
DO $$
BEGIN
  IF to_regprocedure('public._legal_entity_world_summary_unscoped(uuid)') IS NULL THEN
    ALTER FUNCTION public.legal_entity_world_summary(uuid) RENAME TO _legal_entity_world_summary_unscoped;
  END IF;
END $$;

REVOKE ALL ON FUNCTION public._legal_entity_world_summary_unscoped(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._legal_entity_world_summary_unscoped(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.legal_entity_world_summary(p_actor_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'actor_id required' USING errcode = '22023';
  END IF;
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  -- Gating R.1-SEC.1: has_actor_authority(entity, context.view)
  -- (autorización primero — no se filtra existencia de la entity a callers sin autoridad)
  IF public.has_actor_authority(p_actor_id, 'context.view') THEN
    RETURN public._legal_entity_world_summary_unscoped(p_actor_id);
  END IF;

  RAISE EXCEPTION 'not authorized to view legal entity world summary of %', p_actor_id
    USING errcode = '42501';
END;
$$;

COMMENT ON FUNCTION public.legal_entity_world_summary(uuid) IS
  'R.1-SEC.1 gated wrapper sobre _legal_entity_world_summary_unscoped. Permite: has_actor_authority(entity, context.view) (controls/trustee_of/admin_of o creator).';

REVOKE ALL ON FUNCTION public.legal_entity_world_summary(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.legal_entity_world_summary(uuid) TO authenticated, service_role;

-- ============================================================
-- 5. list_actor_relationships — gated re-create
-- ============================================================
-- Full access si self o has_actor_authority(relationships.view).
-- Sin autoridad: solo las relaciones donde el caller participa como subject/object.
CREATE OR REPLACE FUNCTION public.list_actor_relationships(p_actor_id uuid, p_direction text DEFAULT 'both'::text, p_include_inactive boolean DEFAULT false)
RETURNS TABLE(id uuid, subject_actor_id uuid, relationship_type text, object_actor_id uuid, object_resource_id uuid, starts_at timestamp with time zone, ends_at timestamp with time zone, metadata jsonb, created_at timestamp with time zone, direction text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller      uuid := auth.uid();
  v_full_access boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  v_full_access := (p_actor_id = v_caller)
                   OR public.has_actor_authority(p_actor_id, 'relationships.view');

  RETURN QUERY
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
       v_full_access
       OR ar.subject_actor_id = v_caller
       OR ar.object_actor_id = v_caller
     )
     AND (
       p_include_inactive
       OR (
         (ar.starts_at IS NULL OR ar.starts_at <= now())
         AND (ar.ends_at IS NULL OR ar.ends_at > now())
       )
     )
   ORDER BY ar.created_at DESC;
END;
$$;

COMMENT ON FUNCTION public.list_actor_relationships(uuid, text, boolean) IS
  'R.1-SEC.1 gated: full access si self/has_actor_authority(relationships.view); sin autoridad solo relaciones donde el caller participa como subject/object.';

REVOKE ALL ON FUNCTION public.list_actor_relationships(uuid, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_actor_relationships(uuid, text, boolean) TO authenticated, service_role;

-- ============================================================
-- 6. actor_has_right — sigue callable pero authenticated-only (solo retorna boolean)
-- ============================================================
REVOKE ALL ON FUNCTION public.actor_has_right(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actor_has_right(uuid, uuid, text) TO authenticated, service_role;
