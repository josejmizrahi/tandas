-- D.18 drift: `list_decisions_history` was authored before D.18 introduced
-- the `executed` status (distinct from `passed`). Once execute_decision
-- runs, the row's status becomes `executed` and the history RPC stops
-- returning it — a "limbo" state where the decision is neither in the
-- open list nor in history. Symptom found while testing the iPhone JJ
-- sandbox: only 2 of 3 seeded decisions showed up.

CREATE OR REPLACE FUNCTION public.list_decisions_history(p_group_id uuid, p_limit integer DEFAULT 50)
 RETURNS TABLE(decision_id uuid, group_id uuid, title text, body text, decision_type text, method text, legitimacy_source text, status text, threshold_pct numeric, quorum_pct numeric, reference_kind text, reference_id uuid, opens_at timestamp with time zone, closes_at timestamp with time zone, decided_at timestamp with time zone, created_at timestamp with time zone, created_by uuid, created_by_display_name text, option_count integer, vote_count integer, yes_count numeric, no_count numeric, abstain_count numeric, block_count numeric, result jsonb, my_vote_value text, my_vote_option_id uuid)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
#variable_conflict use_column
DECLARE
  v_uid       uuid := auth.uid();
  v_my_member uuid;
  v_limit     int  := least(greatest(coalesce(p_limit, 50), 1), 200);
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

  SELECT gm.id INTO v_my_member
    FROM public.group_memberships gm
   WHERE gm.group_id = p_group_id
     AND gm.user_id  = v_uid
     AND gm.status   = 'active'
   LIMIT 1;

  RETURN QUERY
  WITH current_votes AS (
    SELECT DISTINCT ON (gv.decision_id, gv.voter_membership_id) gv.*
    FROM public.group_votes gv
    WHERE gv.group_id = p_group_id
    ORDER BY gv.decision_id, gv.voter_membership_id, gv.seq DESC
  ),
  tallies AS (
    SELECT
      cv.decision_id,
      count(*)                                                     AS vote_count,
      coalesce(sum(cv.weight) FILTER (WHERE cv.vote_value = 'yes'),     0) AS yes_count,
      coalesce(sum(cv.weight) FILTER (WHERE cv.vote_value = 'no'),      0) AS no_count,
      coalesce(sum(cv.weight) FILTER (WHERE cv.vote_value = 'abstain'), 0) AS abstain_count,
      coalesce(sum(cv.weight) FILTER (WHERE cv.vote_value = 'block'),   0) AS block_count
    FROM current_votes cv
    GROUP BY cv.decision_id
  ),
  options AS (
    SELECT decision_id, count(*) AS option_count
    FROM public.group_decision_options
    GROUP BY decision_id
  )
  SELECT
    d.id, d.group_id, d.title, d.body, d.decision_type, d.method,
    d.legitimacy_source, d.status, d.threshold_pct, d.quorum_pct,
    d.reference_kind, d.reference_id, d.opens_at, d.closes_at,
    d.decided_at, d.created_at, d.created_by,
    NULLIF(p_cb.display_name, '')                AS created_by_display_name,
    coalesce(o.option_count, 0)::int             AS option_count,
    coalesce(t.vote_count, 0)::int               AS vote_count,
    coalesce(t.yes_count, 0)                     AS yes_count,
    coalesce(t.no_count, 0)                      AS no_count,
    coalesce(t.abstain_count, 0)                 AS abstain_count,
    coalesce(t.block_count, 0)                   AS block_count,
    d.result                                     AS result,
    mv.vote_value                                AS my_vote_value,
    mv.option_id                                 AS my_vote_option_id
  FROM public.group_decisions d
  LEFT JOIN public.profiles p_cb ON p_cb.id = d.created_by
  LEFT JOIN tallies          t   ON t.decision_id = d.id
  LEFT JOIN options          o   ON o.decision_id = d.id
  LEFT JOIN current_votes    mv  ON mv.decision_id = d.id
                                 AND mv.voter_membership_id = v_my_member
  WHERE d.group_id = p_group_id
    AND d.status IN ('passed','rejected','cancelled','executed')
  ORDER BY coalesce(d.decided_at, d.created_at) DESC
  LIMIT v_limit;
END;
$function$;
