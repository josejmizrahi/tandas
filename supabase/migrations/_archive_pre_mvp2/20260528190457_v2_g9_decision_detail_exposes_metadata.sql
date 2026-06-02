-- V2-G9 — decision_detail now returns `metadata` so iOS can read
-- weight_strategy (and any future per-decision jsonb knob) without a
-- second hop.
CREATE OR REPLACE FUNCTION public.decision_detail(p_decision_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid       uuid := auth.uid();
  v_decision  public.group_decisions%rowtype;
  v_my_member uuid;
  v_options   jsonb;
  v_tally     jsonb;
  v_my_vote   jsonb;
  v_per_opt   jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT * INTO v_decision FROM public.group_decisions WHERE id = p_decision_id;
  IF v_decision.id IS NULL THEN
    RAISE EXCEPTION 'decision not found' USING errcode = 'P0002';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = v_decision.group_id
       AND gm.user_id  = v_uid
       AND gm.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', v_decision.group_id
      USING errcode = '42501';
  END IF;

  SELECT gm.id INTO v_my_member
    FROM public.group_memberships gm
   WHERE gm.group_id = v_decision.group_id
     AND gm.user_id  = v_uid
     AND gm.status   = 'active'
   LIMIT 1;

  WITH current_votes AS (
    SELECT DISTINCT ON (voter_membership_id) *
    FROM public.group_votes
    WHERE decision_id = p_decision_id
    ORDER BY voter_membership_id, seq DESC
  )
  SELECT jsonb_build_object(
    'vote_count',    coalesce(count(*),0),
    'yes_count',     coalesce(sum(weight) FILTER (WHERE vote_value='yes'),     0),
    'no_count',      coalesce(sum(weight) FILTER (WHERE vote_value='no'),      0),
    'abstain_count', coalesce(sum(weight) FILTER (WHERE vote_value='abstain'), 0),
    'block_count',   coalesce(sum(weight) FILTER (WHERE vote_value='block'),   0)
  ) INTO v_tally
  FROM current_votes;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id',         o.id,
    'label',      o.label,
    'body',       o.body,
    'sort_order', o.sort_order
  ) ORDER BY o.sort_order, o.created_at), '[]'::jsonb)
  INTO v_options
  FROM public.group_decision_options o
  WHERE o.decision_id = p_decision_id;

  WITH current_votes AS (
    SELECT DISTINCT ON (voter_membership_id) *
    FROM public.group_votes
    WHERE decision_id = p_decision_id
    ORDER BY voter_membership_id, seq DESC
  )
  SELECT coalesce(jsonb_object_agg(option_id::text, cnt), '{}'::jsonb)
  INTO v_per_opt
  FROM (
    SELECT option_id, count(*)::int AS cnt
    FROM current_votes
    WHERE option_id IS NOT NULL
    GROUP BY option_id
  ) s;

  SELECT to_jsonb(cv) INTO v_my_vote
  FROM (
    SELECT vote_value, option_id, reason, cast_at
    FROM public.group_votes
    WHERE decision_id = p_decision_id
      AND voter_membership_id = v_my_member
    ORDER BY seq DESC
    LIMIT 1
  ) cv;

  RETURN jsonb_build_object(
    'decision_id',             v_decision.id,
    'group_id',                v_decision.group_id,
    'title',                   v_decision.title,
    'body',                    v_decision.body,
    'decision_type',           v_decision.decision_type,
    'method',                  v_decision.method,
    'legitimacy_source',       v_decision.legitimacy_source,
    'status',                  v_decision.status,
    'threshold_pct',           v_decision.threshold_pct,
    'quorum_pct',              v_decision.quorum_pct,
    'reference_kind',          v_decision.reference_kind,
    'reference_id',            v_decision.reference_id,
    'opens_at',                v_decision.opens_at,
    'closes_at',               v_decision.closes_at,
    'decided_at',              v_decision.decided_at,
    'created_at',              v_decision.created_at,
    'created_by',              v_decision.created_by,
    'created_by_display_name', (SELECT NULLIF(display_name,'') FROM public.profiles WHERE id = v_decision.created_by),
    'result',                  v_decision.result,
    'metadata',                v_decision.metadata,
    'options',                 v_options,
    'tally',                   v_tally,
    'option_tally',            v_per_opt,
    'my_vote',                 v_my_vote
  );
END;
$function$;
