-- R.1-SEC.3 — RLS Critical Cleanup
--
-- Audit PR #131 R4/R6:
--   - group_rule_engine_quotas y action_catalog tenían RLS DISABLED (advisory crítico).
--   - resource_rights / actor_relationships / legal_entities tenían SELECT qual=true
--     (todo usuario autenticado veía el patrimonio y vínculos de todos).
--
-- Este slice:
--   1. ENABLE RLS en action_catalog (catálogo global → read authenticated) y
--      group_rule_engine_quotas (→ read solo miembros del grupo).
--   2. Reemplaza SELECT true por policies scoped en resource_rights /
--      actor_relationships / legal_entities.
--   3. REVOKE grants de anon en las 5 tablas críticas.
--
-- Los RPCs SECURITY DEFINER (summaries, rule engine, grant/revoke) bypassean RLS,
-- así que ningún flujo existente se rompe. Idempotente.

-- ============================================================
-- 1. action_catalog — ENABLE RLS (catálogo global, read-only via API)
-- ============================================================
ALTER TABLE public.action_catalog ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS action_catalog_select_authenticated ON public.action_catalog;
CREATE POLICY action_catalog_select_authenticated ON public.action_catalog
  FOR SELECT TO authenticated
  USING (true);

REVOKE ALL ON public.action_catalog FROM anon;

-- ============================================================
-- 2. group_rule_engine_quotas — ENABLE RLS (solo miembros del grupo)
-- ============================================================
ALTER TABLE public.group_rule_engine_quotas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS group_rule_engine_quotas_select_member ON public.group_rule_engine_quotas;
CREATE POLICY group_rule_engine_quotas_select_member ON public.group_rule_engine_quotas
  FOR SELECT TO authenticated
  USING (public.is_group_member(group_id));

REVOKE ALL ON public.group_rule_engine_quotas FROM anon;

-- ============================================================
-- 3. resource_rights — SELECT scoped (era qual=true)
-- ============================================================
-- Visible si: caller es holder, caller es canonical owner del resource,
-- caller creó el resource, o caller es miembro activo del grupo scope del resource.
DROP POLICY IF EXISTS resource_rights_select_authenticated ON public.resource_rights;
DROP POLICY IF EXISTS resource_rights_select_scoped ON public.resource_rights;
CREATE POLICY resource_rights_select_scoped ON public.resource_rights
  FOR SELECT TO authenticated
  USING (
    holder_actor_id = (SELECT auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.resources r
      WHERE r.id = resource_rights.resource_id
        AND (
          r.canonical_owner_actor_id = (SELECT auth.uid())
          OR r.created_by = (SELECT auth.uid())
          OR (r.group_id IS NOT NULL AND public.is_group_member(r.group_id))
        )
    )
  );

REVOKE ALL ON public.resource_rights FROM anon;

-- ============================================================
-- 4. actor_relationships — SELECT scoped (era qual=true)
-- ============================================================
-- Visible si: caller participa como subject/object, o subject/object es un grupo
-- del que el caller es miembro activo.
DROP POLICY IF EXISTS actor_relationships_select_authenticated ON public.actor_relationships;
DROP POLICY IF EXISTS actor_relationships_select_scoped ON public.actor_relationships;
CREATE POLICY actor_relationships_select_scoped ON public.actor_relationships
  FOR SELECT TO authenticated
  USING (
    subject_actor_id = (SELECT auth.uid())
    OR object_actor_id = (SELECT auth.uid())
    OR public.is_group_member(subject_actor_id)
    OR (object_actor_id IS NOT NULL AND public.is_group_member(object_actor_id))
  );

REVOKE ALL ON public.actor_relationships FROM anon;

-- ============================================================
-- 5. legal_entities — SELECT scoped (era qual=true)
-- ============================================================
-- Visible si: caller es creator (actors.metadata.created_by_uid) o tiene relación
-- activa con la entity (controls/trustee_of/admin_of/shareholder_of/beneficiary_of).
DROP POLICY IF EXISTS legal_entities_select_authenticated ON public.legal_entities;
DROP POLICY IF EXISTS legal_entities_select_scoped ON public.legal_entities;
CREATE POLICY legal_entities_select_scoped ON public.legal_entities
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.actors a
      WHERE a.id = legal_entities.id
        AND a.metadata->>'created_by_uid' = (SELECT auth.uid())::text
    )
    OR EXISTS (
      SELECT 1 FROM public.actor_relationships ar
      WHERE ar.object_actor_id = legal_entities.id
        AND ar.subject_actor_id = (SELECT auth.uid())
        AND ar.relationship_type IN ('controls','trustee_of','admin_of','shareholder_of','beneficiary_of')
        AND (ar.starts_at IS NULL OR ar.starts_at <= now())
        AND (ar.ends_at IS NULL OR ar.ends_at > now())
    )
  );

REVOKE ALL ON public.legal_entities FROM anon;
