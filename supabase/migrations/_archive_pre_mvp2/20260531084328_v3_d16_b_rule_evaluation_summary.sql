-- V3 FASE D.16 — Mig B: rule_evaluation_summary(p_group_id, p_since)
-- Returns single jsonb with: totals, matched/unmatched, action status counts,
-- breakdowns by trigger and consequence kind, top failing rules,
-- engine_skipped_breakdown (rate_limited / kill_switch / other),
-- engine_active flag.

BEGIN;

CREATE OR REPLACE FUNCTION public.rule_evaluation_summary(
  p_group_id uuid,
  p_since timestamptz DEFAULT (now() - interval '7 days')
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total_evaluations int;
  v_matched_count int;
  v_unmatched_count int;
  v_failed_actions int;
  v_emitted_actions int;
  v_evaluations_by_trigger jsonb;
  v_actions_by_consequence jsonb;
  v_top_failing_rules jsonb;
  v_engine_skipped_breakdown jsonb;
  v_engine_active boolean;
BEGIN
  SELECT engine_active INTO v_engine_active FROM public.groups WHERE id = p_group_id;

  -- Totals over evaluations
  SELECT
    count(*),
    count(*) FILTER (WHERE matched),
    count(*) FILTER (WHERE NOT matched)
  INTO v_total_evaluations, v_matched_count, v_unmatched_count
  FROM public.group_rule_evaluations
  WHERE group_id = p_group_id
    AND created_at >= p_since;

  -- Action status counts (unnest actions_emitted)
  SELECT
    COALESCE(SUM(CASE WHEN a.value->>'status'='emitted' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN a.value->>'status'='failed'  THEN 1 ELSE 0 END), 0)
  INTO v_emitted_actions, v_failed_actions
  FROM public.group_rule_evaluations gre
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(gre.actions_emitted, '[]'::jsonb)) a
  WHERE gre.group_id = p_group_id
    AND gre.created_at >= p_since;

  -- Evaluations by trigger
  SELECT COALESCE(jsonb_object_agg(trigger_event_type, cnt) FILTER (WHERE trigger_event_type IS NOT NULL), '{}'::jsonb)
  INTO v_evaluations_by_trigger
  FROM (
    SELECT rv.trigger_event_type, count(*) AS cnt
    FROM public.group_rule_evaluations gre
    JOIN public.group_rule_versions rv ON rv.id = gre.rule_version_id
    WHERE gre.group_id = p_group_id AND gre.created_at >= p_since
    GROUP BY rv.trigger_event_type
  ) t;

  -- Actions by consequence kind
  SELECT COALESCE(jsonb_object_agg(consequence_kind, cnt) FILTER (WHERE consequence_kind IS NOT NULL), '{}'::jsonb)
  INTO v_actions_by_consequence
  FROM (
    SELECT a.value->>'kind' AS consequence_kind, count(*) AS cnt
    FROM public.group_rule_evaluations gre
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(gre.actions_emitted, '[]'::jsonb)) a
    WHERE gre.group_id = p_group_id AND gre.created_at >= p_since
    GROUP BY a.value->>'kind'
  ) t;

  -- Top failing rules (top 5 by # of failed actions)
  SELECT COALESCE(jsonb_agg(jsonb_build_object('rule_id', rule_id, 'failed_actions', failed_actions) ORDER BY failed_actions DESC), '[]'::jsonb)
  INTO v_top_failing_rules
  FROM (
    SELECT r.id AS rule_id, count(*) AS failed_actions
    FROM public.group_rule_evaluations gre
    JOIN public.group_rule_versions rv ON rv.id = gre.rule_version_id
    JOIN public.group_rules r ON r.id = rv.rule_id
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(gre.actions_emitted, '[]'::jsonb)) a
    WHERE gre.group_id = p_group_id
      AND gre.created_at >= p_since
      AND a.value->>'status' = 'failed'
    GROUP BY r.id
    ORDER BY failed_actions DESC
    LIMIT 5
  ) t;

  -- Engine skipped breakdown (from group_events.rule.engine_skipped)
  SELECT COALESCE(jsonb_object_agg(reason, cnt) FILTER (WHERE reason IS NOT NULL), '{}'::jsonb)
  INTO v_engine_skipped_breakdown
  FROM (
    SELECT COALESCE(payload->>'reason','other') AS reason, count(*) AS cnt
    FROM public.group_events
    WHERE group_id = p_group_id
      AND event_type = 'rule.engine_skipped'
      AND created_at >= p_since
    GROUP BY 1
  ) t;

  RETURN jsonb_build_object(
    'group_id', p_group_id,
    'since', p_since,
    'engine_active', COALESCE(v_engine_active, true),
    'total_evaluations', v_total_evaluations,
    'matched_count', v_matched_count,
    'unmatched_count', v_unmatched_count,
    'emitted_actions_count', v_emitted_actions,
    'failed_actions_count', v_failed_actions,
    'evaluations_by_trigger', v_evaluations_by_trigger,
    'actions_by_consequence_kind', v_actions_by_consequence,
    'top_failing_rules', v_top_failing_rules,
    'engine_skipped_breakdown', v_engine_skipped_breakdown
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rule_evaluation_summary(uuid, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rule_evaluation_summary(uuid, timestamptz) TO authenticated, service_role;

COMMIT;
