-- 20260527160000 — Decisions/Voting Foundation (Primitiva 16, C1).
--
-- Write surface (start_vote / cast_vote / finalize_vote) already lives
-- in the canonical schema. This migration only adds the missing read
-- side so iOS can stay typed: an "active" list, a "history" list,
-- and a fat detail RPC that pre-joins options + tally + the caller's
-- current vote.
--
-- group_votes is append-only — "current vote per voter" is the row
-- with the largest `seq` (see `current_votes_for_decision` for the
-- DISTINCT ON pattern). Tally is computed from that current view.

-- ===========================================================================
-- 1. READ: list_decisions_active(p_group_id)
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.list_decisions_active(p_group_id uuid)
RETURNS TABLE (
  decision_id              uuid,
  group_id                 uuid,
  title                    text,
  body                     text,
  decision_type            text,
  method                   text,
  legitimacy_source        text,
  status                   text,
  threshold_pct            numeric,
  quorum_pct               numeric,
  reference_kind           text,
  reference_id             uuid,
  opens_at                 timestamptz,
  closes_at                timestamptz,
  decided_at               timestamptz,
  created_at               timestamptz,
  created_by               uuid,
  created_by_display_name  text,
  option_count             integer,
  vote_count               integer,
  yes_count                numeric,
  no_count                 numeric,
  abstain_count            numeric,
  block_count              numeric,
  result                   jsonb,
  my_vote_value            text,
  my_vote_option_id        uuid
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
#variable_conflict use_column
DECLARE
  v_uid       uuid := auth.uid();
  v_my_member uuid;
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
    d.id                                            AS decision_id,
    d.group_id                                      AS group_id,
    d.title                                         AS title,
    d.body                                          AS body,
    d.decision_type                                 AS decision_type,
    d.method                                        AS method,
    d.legitimacy_source                             AS legitimacy_source,
    d.status                                        AS status,
    d.threshold_pct                                 AS threshold_pct,
    d.quorum_pct                                    AS quorum_pct,
    d.reference_kind                                AS reference_kind,
    d.reference_id                                  AS reference_id,
    d.opens_at                                      AS opens_at,
    d.closes_at                                     AS closes_at,
    d.decided_at                                    AS decided_at,
    d.created_at                                    AS created_at,
    d.created_by                                    AS created_by,
    NULLIF(p_cb.display_name, '')                   AS created_by_display_name,
    coalesce(o.option_count, 0)::int                AS option_count,
    coalesce(t.vote_count, 0)::int                  AS vote_count,
    coalesce(t.yes_count, 0)                        AS yes_count,
    coalesce(t.no_count, 0)                         AS no_count,
    coalesce(t.abstain_count, 0)                    AS abstain_count,
    coalesce(t.block_count, 0)                      AS block_count,
    d.result                                        AS result,
    mv.vote_value                                   AS my_vote_value,
    mv.option_id                                    AS my_vote_option_id
  FROM public.group_decisions d
  LEFT JOIN public.profiles      p_cb ON p_cb.id      = d.created_by
  LEFT JOIN tallies              t    ON t.decision_id = d.id
  LEFT JOIN options              o    ON o.decision_id = d.id
  LEFT JOIN current_votes        mv   ON mv.decision_id = d.id
                                      AND mv.voter_membership_id = v_my_member
  WHERE d.group_id = p_group_id
    AND d.status   = 'open'
  ORDER BY coalesce(d.closes_at, d.created_at) ASC, d.created_at DESC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.list_decisions_active(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.list_decisions_active(uuid) TO authenticated;
COMMENT ON FUNCTION public.list_decisions_active(uuid) IS
  'Primitiva 16 (mig 20260527160000): open decisions for a group, with tally + caller current vote pre-joined. Active-member gate.';

-- ===========================================================================
-- 2. READ: list_decisions_history(p_group_id, p_limit)
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.list_decisions_history(
  p_group_id uuid,
  p_limit    int DEFAULT 50
)
RETURNS TABLE (
  decision_id              uuid,
  group_id                 uuid,
  title                    text,
  body                     text,
  decision_type            text,
  method                   text,
  legitimacy_source        text,
  status                   text,
  threshold_pct            numeric,
  quorum_pct               numeric,
  reference_kind           text,
  reference_id             uuid,
  opens_at                 timestamptz,
  closes_at                timestamptz,
  decided_at               timestamptz,
  created_at               timestamptz,
  created_by               uuid,
  created_by_display_name  text,
  option_count             integer,
  vote_count               integer,
  yes_count                numeric,
  no_count                 numeric,
  abstain_count            numeric,
  block_count              numeric,
  result                   jsonb,
  my_vote_value            text,
  my_vote_option_id        uuid
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
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
    AND d.status IN ('passed','rejected','cancelled')
  ORDER BY coalesce(d.decided_at, d.created_at) DESC
  LIMIT v_limit;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.list_decisions_history(uuid, int) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.list_decisions_history(uuid, int) TO authenticated;
COMMENT ON FUNCTION public.list_decisions_history(uuid, int) IS
  'Primitiva 16 (mig 20260527160000): closed decisions (passed/rejected/cancelled) ordered by decided_at DESC, capped to 200. Active-member gate.';

-- ===========================================================================
-- 3. READ: decision_detail(p_decision_id)
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.decision_detail(p_decision_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
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
    'options',                 v_options,
    'tally',                   v_tally,
    'option_tally',            v_per_opt,
    'my_vote',                 v_my_vote
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.decision_detail(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.decision_detail(uuid) TO authenticated;
COMMENT ON FUNCTION public.decision_detail(uuid) IS
  'Primitiva 16 (mig 20260527160000): single-decision detail jsonb — options + tally + caller current vote. Active-member gate.';
