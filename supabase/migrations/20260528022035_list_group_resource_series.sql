-- 20260527180000 — Rituals read surface (Primitiva 21, B6).
--
-- Write surface (create_resource_series / update_resource_series) ya
-- existe canónico y gateado por resources.create / resources.update.
-- Lo que falta para B6 es el read RPC del grupo + un filtro que
-- distinga "serie con ritual" (ritual_meaning OR ritual_marker_kind
-- presente) de una recurrencia genérica.
--
-- iOS solo expone rituales en V1; las series sin ritual quedan
-- invisibles hasta que haya un surface de recurrence genérico.

CREATE OR REPLACE FUNCTION public.list_group_resource_series(
  p_group_id     uuid,
  p_rituals_only boolean DEFAULT true,
  p_include_past boolean DEFAULT false
)
RETURNS TABLE (
  series_id              uuid,
  group_id               uuid,
  resource_type          text,
  cadence                text,
  pattern                jsonb,
  starts_on              date,
  ends_on                date,
  ritual_meaning         text,
  ritual_marker_kind     text,
  ritual_norm_id         uuid,
  template_payload       jsonb,
  created_by             uuid,
  created_by_display_name text,
  created_at             timestamptz,
  updated_at             timestamptz
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
#variable_conflict use_column
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = p_group_id
       AND gm.user_id  = v_uid
       AND gm.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    s.id                                 AS series_id,
    s.group_id                           AS group_id,
    s.resource_type                      AS resource_type,
    s.cadence                            AS cadence,
    s.pattern                            AS pattern,
    s.starts_on                          AS starts_on,
    s.ends_on                            AS ends_on,
    s.ritual_meaning                     AS ritual_meaning,
    s.ritual_marker_kind                 AS ritual_marker_kind,
    s.ritual_norm_id                     AS ritual_norm_id,
    s.template_payload                   AS template_payload,
    s.created_by                         AS created_by,
    NULLIF(p.display_name, '')           AS created_by_display_name,
    s.created_at                         AS created_at,
    s.updated_at                         AS updated_at
  FROM public.group_resource_series s
  LEFT JOIN public.profiles p ON p.id = s.created_by
  WHERE s.group_id = p_group_id
    AND (NOT p_rituals_only
         OR s.ritual_meaning IS NOT NULL
         OR s.ritual_marker_kind IS NOT NULL)
    AND (p_include_past OR s.ends_on IS NULL OR s.ends_on >= current_date)
  ORDER BY s.starts_on ASC NULLS LAST, s.created_at DESC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.list_group_resource_series(uuid, boolean, boolean) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.list_group_resource_series(uuid, boolean, boolean) TO authenticated;
COMMENT ON FUNCTION public.list_group_resource_series(uuid, boolean, boolean) IS
  'Primitiva 21 (mig 20260527180000): list resource series for a group; default filters to series flagged as rituals (ritual_meaning/ritual_marker_kind set) and excludes ended ones. Active-member gate.';
