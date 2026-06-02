-- V3 PARTE 7c — group_governance_versions read RPC
--
-- Hot path: EditDecisionRulesView quiere mostrar el historial de
-- cambios. RLS sobre la tabla ya permite SELECT a active members,
-- pero iOS no toca tablas directo (canonical) — necesita una RPC
-- pre-joined con `set_by_display_name` y ordenada por
-- effective_from DESC.

CREATE OR REPLACE FUNCTION public.group_governance_versions(
  p_group_id uuid,
  p_limit int DEFAULT 20
) RETURNS TABLE(
  id uuid,
  snapshot jsonb,
  effective_from timestamptz,
  effective_until timestamptz,
  set_by_user_id uuid,
  set_by_display_name text,
  source_decision_id uuid,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = p_group_id
       AND gm.user_id = v_uid
       AND gm.status = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT gv.id, gv.snapshot, gv.effective_from, gv.effective_until,
         gv.set_by, p.display_name, gv.source_decision_id, gv.created_at
    FROM public.group_governance_versions gv
    LEFT JOIN public.profiles p ON p.id = gv.set_by
   WHERE gv.group_id = p_group_id
   ORDER BY gv.effective_from DESC
   LIMIT GREATEST(p_limit, 1);
END;
$function$;

REVOKE ALL ON FUNCTION public.group_governance_versions(uuid, int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.group_governance_versions(uuid, int) TO authenticated;

COMMENT ON FUNCTION public.group_governance_versions(uuid, int) IS
  'V3 PARTE 7c: read RPC para historial de decision_rules. Pre-join con profile.display_name. Active-member gate. Ordenada effective_from DESC.';
