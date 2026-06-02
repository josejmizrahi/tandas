-- V3-D.18 FASE C
-- 1. decisions.execute permission distinct from resolve.
-- 2. decision_templates_catalog — analogía con rule_shapes_catalog.
--    Cada fila es una receta de gobernanza: how to vote on a topic.
--    template_key  = identificador canónico (e.g. decision.resource_archive)
--    decision_type = uno de los 11 existentes (NO ampliamos el CHECK)
--    reference_kind = qué entidad gobierna (sin handler aún para resource)
--    execution_mode = auto | manual | secondary_approval
--    default_method/legitimacy_source/threshold_pct/quorum_pct
-- 3. list_decision_templates() expone el catalog.

-- 1.1 permission
INSERT INTO public.permissions (key, category, description)
VALUES ('decisions.execute', 'decisions', 'Ejecutar decisiones aprobadas')
ON CONFLICT (key) DO UPDATE SET
  category    = EXCLUDED.category,
  description = EXCLUDED.description;

INSERT INTO public.group_role_permissions (role_id, permission_key)
SELECT r.id, 'decisions.execute'
FROM public.group_roles r
WHERE r.is_system = true AND r.key = 'founder'
ON CONFLICT DO NOTHING;

-- 2.1 catalog table
CREATE TABLE IF NOT EXISTS public.decision_templates_catalog (
  template_key                text PRIMARY KEY,
  display_name                text NOT NULL,
  description                 text,
  decision_type               text NOT NULL,
  reference_kind              text,
  default_method              text NOT NULL,
  default_legitimacy_source   text NOT NULL,
  default_threshold_pct       numeric,
  default_quorum_pct          numeric,
  execution_mode              text NOT NULL DEFAULT 'manual',
  metadata                    jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT decision_templates_catalog_execution_mode_check
    CHECK (execution_mode IN ('auto','manual','secondary_approval')),
  CONSTRAINT decision_templates_catalog_method_check
    CHECK (default_method IN ('admin','majority','supermajority','consensus','consent','ranked_choice','weighted','veto')),
  CONSTRAINT decision_templates_catalog_legitimacy_check
    CHECK (default_legitimacy_source IN ('founder','election','majority','supermajority','committee','unanimity','expert','external_contract','tradition','emergency')),
  CONSTRAINT decision_templates_catalog_type_check
    CHECK (decision_type IN ('proposal','poll','election','budget','rule_change','membership','sanction_appeal','mandate_grant','mandate_revoke','dissolution','other'))
);

ALTER TABLE public.decision_templates_catalog ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS decision_templates_catalog_read_all ON public.decision_templates_catalog;
CREATE POLICY decision_templates_catalog_read_all
  ON public.decision_templates_catalog FOR SELECT
  USING (true);

-- 2.2 seed canonical templates
-- Topic stays in decision_type; the recipe lives in the template row.
INSERT INTO public.decision_templates_catalog (
  template_key, display_name, description,
  decision_type, reference_kind,
  default_method, default_legitimacy_source,
  default_threshold_pct, default_quorum_pct,
  execution_mode, metadata
) VALUES
  ('decision.membership_accept',
   'Aceptar miembro',
   'Decisión para incorporar un miembro pendiente.',
   'membership', 'membership',
   'majority', 'majority',
   50.01, 50.00,
   'auto',
   jsonb_build_object('target_state','active')),

  ('decision.membership_remove',
   'Remover miembro',
   'Decisión para suspender o expulsar a un miembro.',
   'membership', 'membership',
   'supermajority', 'supermajority',
   66.66, 50.00,
   'manual',
   jsonb_build_object('target_state','banned')),

  ('decision.rule_change',
   'Cambio de regla',
   'Decisión para activar, archivar o modificar una regla.',
   'rule_change', 'rule',
   'majority', 'majority',
   50.01, 50.00,
   'manual',
   jsonb_build_object('action','archive')),

  ('decision.resource_archive',
   'Archivar recurso',
   'Decisión para archivar un recurso del grupo.',
   'proposal', 'resource',
   'majority', 'majority',
   50.01, NULL,
   'manual',
   jsonb_build_object('action','archive')),

  ('decision.resource_transfer',
   'Transferir recurso',
   'Decisión para transferir la propiedad de un recurso.',
   'proposal', 'resource',
   'supermajority', 'supermajority',
   66.66, 50.00,
   'secondary_approval',
   jsonb_build_object('action','transfer')),

  ('decision.expense_approval',
   'Aprobar gasto',
   'Decisión para aprobar un gasto del fondo común.',
   'proposal', 'pool_charge',
   'majority', 'majority',
   50.01, NULL,
   'auto',
   jsonb_build_object('charge_kind','fee')),

  ('decision.budget_approval',
   'Aprobar presupuesto',
   'Decisión para aprobar un presupuesto del grupo.',
   'budget', NULL,
   'supermajority', 'supermajority',
   66.66, 50.00,
   'manual',
   '{}'::jsonb),

  ('decision.custom',
   'Decisión personalizada',
   'Decisión sin receta predefinida.',
   'proposal', NULL,
   'majority', 'majority',
   50.01, NULL,
   'manual',
   '{}'::jsonb)
ON CONFLICT (template_key) DO UPDATE SET
  display_name              = EXCLUDED.display_name,
  description               = EXCLUDED.description,
  decision_type             = EXCLUDED.decision_type,
  reference_kind            = EXCLUDED.reference_kind,
  default_method            = EXCLUDED.default_method,
  default_legitimacy_source = EXCLUDED.default_legitimacy_source,
  default_threshold_pct     = EXCLUDED.default_threshold_pct,
  default_quorum_pct        = EXCLUDED.default_quorum_pct,
  execution_mode            = EXCLUDED.execution_mode,
  metadata                  = EXCLUDED.metadata;

-- 3. list_decision_templates() — active-member gate at iOS read time
--    (catalog is global, RLS is read-all).
CREATE OR REPLACE FUNCTION public.list_decision_templates()
RETURNS TABLE (
  template_key              text,
  display_name              text,
  description               text,
  decision_type             text,
  reference_kind            text,
  default_method            text,
  default_legitimacy_source text,
  default_threshold_pct     numeric,
  default_quorum_pct        numeric,
  execution_mode            text,
  metadata                  jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
  SELECT
    t.template_key, t.display_name, t.description,
    t.decision_type, t.reference_kind,
    t.default_method, t.default_legitimacy_source,
    t.default_threshold_pct, t.default_quorum_pct,
    t.execution_mode, t.metadata
  FROM public.decision_templates_catalog t
  ORDER BY t.template_key;
$$;

GRANT EXECUTE ON FUNCTION public.list_decision_templates() TO authenticated;

COMMENT ON TABLE public.decision_templates_catalog IS
  'V3-D.18 — recipes for governance: template_key + defaults. decision_type stays as topic; template is the procedural skeleton (method, legitimacy, quorum, execution_mode).';
COMMENT ON FUNCTION public.list_decision_templates() IS
  'V3-D.18 — list canonical decision templates for the propose sheet.';
