-- F.1A-3 — resource_settings_summary(p_resource_id)
-- Resumen único para la pantalla de Configuración del Recurso. Capability-gated:
-- las secciones policy (reservable/monetary/beneficiary/documentable) solo aparecen
-- si el resource_type tiene la capability. Acceso restringido a OWN/MANAGE.
-- Frontend NO calcula permisos: available_actions viene siempre del backend.

CREATE OR REPLACE FUNCTION public.resource_settings_summary(p_resource_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller uuid := public.current_actor_id();
  v_resource public.resources%rowtype;
  v_capabilities jsonb;
  v_rights_summary jsonb;
  v_meta jsonb;
  v_policies jsonb;
  v_has_own boolean;
  v_has_manage boolean;
  v_actions jsonb := '[]'::jsonb;
BEGIN
  IF v_caller IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING errcode = '28000'; END IF;

  SELECT * INTO v_resource FROM public.resources WHERE id = p_resource_id;
  IF v_resource.id IS NULL THEN
    RAISE EXCEPTION 'resource not found' USING errcode = 'P0002';
  END IF;

  -- Gate doctrinal: solo OWN/MANAGE pueden ver settings del recurso.
  v_has_own    := public.actor_has_right(v_caller, p_resource_id, 'OWN');
  v_has_manage := public.actor_has_right(v_caller, p_resource_id, 'MANAGE');
  IF NOT (v_has_own OR v_has_manage) THEN
    RAISE EXCEPTION 'not authorized to view resource settings' USING errcode = '42501';
  END IF;

  v_meta := COALESCE(v_resource.metadata, '{}'::jsonb);

  -- Capabilities desde el catálogo (resource_type_capabilities)
  SELECT COALESCE(jsonb_agg(capability_key ORDER BY capability_key), '[]'::jsonb)
    INTO v_capabilities
    FROM public.resource_type_capabilities
   WHERE type_key = v_resource.resource_type;

  -- Right counts (solo derechos activos)
  SELECT COALESCE(jsonb_object_agg(right_kind, n), '{}'::jsonb) INTO v_rights_summary
  FROM (
    SELECT right_kind, count(*) AS n
      FROM public.resource_rights
     WHERE resource_id = p_resource_id
       AND revoked_at IS NULL
       AND expired_at IS NULL
       AND (starts_at IS NULL OR starts_at <= now())
       AND (ends_at IS NULL OR ends_at > now())
     GROUP BY right_kind
  ) t;

  -- Policies — un sub-block por cada capability conocida.
  v_policies := jsonb_build_object(
    'reservable', jsonb_build_object(
      'max_window_days',    COALESCE((v_meta->'policies'->'reservable'->>'max_window_days')::int, 14),
      'cancellation_policy',COALESCE(v_meta->'policies'->'reservable'->>'cancellation_policy', 'open'),
      'priority_policy',    COALESCE(v_meta->'policies'->'reservable'->>'priority_policy', 'least_recent_use_wins'),
      'capacity',           COALESCE((v_meta->'policies'->'reservable'->>'capacity')::int, 1)
    ),
    'monetary', jsonb_build_object(
      'currency',          COALESCE(v_meta->'policies'->'monetary'->>'currency', v_resource.currency, 'MXN'),
      'settlement_policy', COALESCE(v_meta->'policies'->'monetary'->>'settlement_policy', 'monthly')
    ),
    'beneficiary', jsonb_build_object(
      'beneficiaries', COALESCE(v_meta->'policies'->'beneficiary'->'beneficiaries', '[]'::jsonb),
      'distribution',  COALESCE(v_meta->'policies'->'beneficiary'->>'distribution', 'equal')
    ),
    'documentable', jsonb_build_object(
      'versioning_enabled', COALESCE((v_meta->'policies'->'documentable'->>'versioning_enabled')::boolean, false),
      'approvals_required', COALESCE((v_meta->'policies'->'documentable'->>'approvals_required')::int, 0)
    )
  );

  IF v_has_own THEN
    v_actions := v_actions || '["edit_general","manage_rights","edit_policies","archive","transfer_ownership","view"]'::jsonb;
  ELSIF v_has_manage THEN
    v_actions := v_actions || '["edit_general","manage_rights","edit_policies","view"]'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'resource_id', v_resource.id,
    'general', jsonb_build_object(
      'resource_type',   v_resource.resource_type,
      'display_name',    v_resource.display_name,
      'description',     v_resource.description,
      'status',          v_resource.status,
      'estimated_value', v_resource.estimated_value,
      'currency',        v_resource.currency,
      'archived_at',     v_resource.archived_at
    ),
    'capabilities',     v_capabilities,
    'rights_summary',   v_rights_summary,
    'policies',         v_policies,
    'available_actions', v_actions
  );
END $$;

REVOKE EXECUTE ON FUNCTION public.resource_settings_summary(uuid) FROM anon;
