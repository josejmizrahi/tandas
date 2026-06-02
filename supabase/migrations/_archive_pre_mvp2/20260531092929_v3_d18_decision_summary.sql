-- V3-D.18 FASE F
-- decision_summary(p_group_id) returns jsonb — founder dashboard payload.
--   open / passed / rejected / executed counts
--   participation_rate — votos únicos / membership_active (avg per decision)
--   avg_turnout — avg distinct voters per closed decision
--   by_type, by_legitimacy_source

CREATE OR REPLACE FUNCTION public.decision_summary(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_active_members int;
  v_open_count int;
  v_passed_count int;
  v_rejected_count int;
  v_executed_count int;
  v_cancelled_count int;
  v_avg_turnout numeric;
  v_participation numeric;
  v_by_type jsonb;
  v_by_legitimacy jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships
    WHERE group_id = p_group_id AND user_id = v_uid AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING errcode = '42501';
  END IF;

  SELECT count(*) INTO v_active_members
  FROM public.group_memberships
  WHERE group_id = p_group_id AND status = 'active';

  SELECT
    count(*) FILTER (WHERE status = 'open'),
    count(*) FILTER (WHERE status = 'passed'),
    count(*) FILTER (WHERE status = 'rejected'),
    count(*) FILTER (WHERE status = 'executed'),
    count(*) FILTER (WHERE status = 'cancelled')
  INTO v_open_count, v_passed_count, v_rejected_count, v_executed_count, v_cancelled_count
  FROM public.group_decisions
  WHERE group_id = p_group_id;

  -- Average distinct voters per closed decision (passed | rejected | executed)
  SELECT COALESCE(avg(voters), 0) INTO v_avg_turnout
  FROM (
    SELECT count(DISTINCT v.voter_membership_id) AS voters
    FROM public.group_decisions d
    LEFT JOIN public.group_votes v ON v.decision_id = d.id
    WHERE d.group_id = p_group_id
      AND d.status IN ('passed','rejected','executed')
    GROUP BY d.id
  ) per_decision;

  -- Participation rate: avg turnout / active members (0..1)
  v_participation := CASE
    WHEN v_active_members > 0 THEN v_avg_turnout / v_active_members
    ELSE 0
  END;

  SELECT COALESCE(jsonb_object_agg(decision_type, n), '{}'::jsonb) INTO v_by_type
  FROM (
    SELECT decision_type, count(*) AS n
    FROM public.group_decisions
    WHERE group_id = p_group_id
    GROUP BY decision_type
  ) t;

  SELECT COALESCE(jsonb_object_agg(legitimacy_source, n), '{}'::jsonb) INTO v_by_legitimacy
  FROM (
    SELECT legitimacy_source, count(*) AS n
    FROM public.group_decisions
    WHERE group_id = p_group_id AND legitimacy_source IS NOT NULL
    GROUP BY legitimacy_source
  ) t;

  RETURN jsonb_build_object(
    'group_id',           p_group_id,
    'active_members',     v_active_members,
    'open',               v_open_count,
    'passed',             v_passed_count,
    'rejected',           v_rejected_count,
    'executed',           v_executed_count,
    'cancelled',          v_cancelled_count,
    'avg_turnout',        round(v_avg_turnout, 2),
    'participation_rate', round(v_participation, 4),
    'by_type',            v_by_type,
    'by_legitimacy_source', v_by_legitimacy
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.decision_summary(uuid) TO authenticated;

COMMENT ON FUNCTION public.decision_summary(uuid) IS
  'V3-D.18 — founder dashboard payload for Decisions. Active-member gate.';
