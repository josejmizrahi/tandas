-- V2-G3 sub-slice 5 (backend half): list RPC para que iOS pueda
-- visibilizar el audit log del engine.
--
-- group_rule_evaluations(group_id, limit, before) devuelve cada eval
-- hidratada con el rule title + trigger + matched_predicate (con
-- outcome real post-G3.4) + actions_emitted (per-action {kind,
-- execution, status, error?}). Active-member gate como el resto de
-- los reads. p_before es el cursor opcional para infinite scroll
-- (paginación por created_at DESC).

CREATE OR REPLACE FUNCTION public.group_rule_evaluations(
  p_group_id uuid,
  p_limit integer DEFAULT 50,
  p_before timestamptz DEFAULT NULL
)
RETURNS TABLE(
  evaluation_id        uuid,
  rule_id              uuid,
  rule_title           text,
  rule_version_id      uuid,
  shape_key            text,
  trigger_event_type   text,
  source_event_id      uuid,
  matched              boolean,
  cycle_detected       boolean,
  depth                integer,
  matched_predicate    jsonb,
  actions_emitted      jsonb,
  parent_evaluation_id uuid,
  created_at           timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
#variable_conflict use_column
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
    WHERE gm.group_id = p_group_id AND gm.user_id = v_uid AND gm.status = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING errcode = '42501';
  END IF;
  RETURN QUERY
  SELECT e.id, gr.id, gr.title, e.rule_version_id, grv.shape_key, grv.trigger_event_type,
         e.source_event_id, e.matched, e.cycle_detected, e.depth,
         e.matched_predicate, e.actions_emitted, e.parent_evaluation_id, e.created_at
    FROM public.group_rule_evaluations e
    JOIN public.group_rule_versions grv ON grv.id = e.rule_version_id
    JOIN public.group_rules gr ON gr.id = grv.rule_id
   WHERE e.group_id = p_group_id
     AND (p_before IS NULL OR e.created_at < p_before)
   ORDER BY e.created_at DESC
   LIMIT GREATEST(p_limit, 1);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.group_rule_evaluations(uuid, integer, timestamptz) TO authenticated;
