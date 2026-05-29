-- V2-G8 sub-slice 1 — rule evaluation summary RPC
--
-- Cheap aggregate sobre group_rule_evaluations para alimentar el banner
-- "Sistema evaluó M reglas en últimas N horas" en GroupHomeFeedView.
-- COUNT + MAX + EXISTS(failed actions) en un solo round-trip. iOS llama
-- en el refresh del home; si count=0 el banner es invisible (doctrina
-- situational: empty cluster = invisible).
--
-- Active-member gate idéntico al list RPC group_rule_evaluations.
-- Default window = 24h, override-able por iOS para ventanas distintas.

CREATE OR REPLACE FUNCTION public.group_rule_evaluation_summary(
  p_group_id uuid,
  p_window_hours int DEFAULT 24
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_count int := 0;
  v_last timestamptz;
  v_has_failures boolean := false;
  v_since timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  IF p_window_hours IS NULL OR p_window_hours <= 0 THEN
    RAISE EXCEPTION 'p_window_hours must be > 0' USING ERRCODE = '22023';
  END IF;

  -- Active-member gate (mismo que group_rule_evaluations list)
  IF NOT EXISTS (
    SELECT 1
      FROM public.group_memberships m
     WHERE m.group_id = p_group_id
       AND m.user_id = v_caller
       AND m.state = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING ERRCODE = '42501';
  END IF;

  v_since := now() - make_interval(hours => p_window_hours);

  SELECT count(*), max(re.created_at)
    INTO v_count, v_last
    FROM public.group_rule_evaluations re
   WHERE re.group_id = p_group_id
     AND re.created_at >= v_since;

  -- has_failures: any action with status='failed' within the window.
  -- Guard with the count check so we skip the jsonb scan when there's
  -- nothing to report.
  IF v_count > 0 THEN
    SELECT EXISTS (
      SELECT 1
        FROM public.group_rule_evaluations re,
             jsonb_array_elements(coalesce(re.actions_emitted, '[]'::jsonb)) AS action
       WHERE re.group_id = p_group_id
         AND re.created_at >= v_since
         AND action->>'status' = 'failed'
    ) INTO v_has_failures;
  END IF;

  RETURN jsonb_build_object(
    'evaluations_count', v_count,
    'last_evaluated_at', v_last,
    'has_failures',      v_has_failures,
    'window_hours',      p_window_hours
  );
END;
$$;

REVOKE ALL ON FUNCTION public.group_rule_evaluation_summary(uuid, int) FROM public;
GRANT EXECUTE ON FUNCTION public.group_rule_evaluation_summary(uuid, int) TO authenticated;

COMMENT ON FUNCTION public.group_rule_evaluation_summary(uuid, int) IS
  'V2-G8.1: cheap aggregate over group_rule_evaluations for the home banner. Returns {evaluations_count, last_evaluated_at, has_failures, window_hours}. Active-member gate.';
