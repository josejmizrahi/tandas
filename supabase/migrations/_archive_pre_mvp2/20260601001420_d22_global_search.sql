-- D.22: Search MVP — one unified RPC across 4 entities (members, resources,
-- decisions, rules) for the currently-active group. V1 scope is intentionally
-- narrow: ILIKE substring on tiny tenant-filtered subsets. No indexes (tables
-- are < 200 rows total today). No fuzzy / accent-insensitive / ranking.
--
-- Permission gate: caller must be active member of p_group_id (else 42501).
-- All four CTEs include WHERE group_id = p_group_id explicitly, in addition
-- to RLS which is bypassed under SECURITY DEFINER. Defense in depth against
-- cross-tenant leakage.

CREATE OR REPLACE FUNCTION public.global_search(
  p_group_id uuid,
  p_query text,
  p_limit int DEFAULT 25
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid       uuid := auth.uid();
  v_q         text;
  v_pattern   text;
  v_limit     int;
  v_results   jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  IF p_group_id IS NULL THEN
    RAISE EXCEPTION 'p_group_id is required' USING errcode = '22023';
  END IF;

  -- Membership gate. Mirror is_group_member but inline so we get a hard 42501
  -- on mismatch instead of an empty result that hides RLS misconfiguration.
  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
    WHERE gm.group_id = p_group_id
      AND gm.user_id  = v_uid
      AND gm.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING errcode = '42501';
  END IF;

  v_q := COALESCE(trim(p_query), '');
  -- Min 2 chars. Below that, return empty array (don't expensive-scan).
  IF length(v_q) < 2 THEN
    RETURN '[]'::jsonb;
  END IF;

  v_pattern := '%' || v_q || '%';
  v_limit   := LEAST(GREATEST(COALESCE(p_limit, 25), 1), 50);

  WITH member_hits AS (
    SELECT
      'member'::text AS entity_type,
      gm.id          AS entity_id,
      gm.group_id,
      COALESCE(p.display_name, p.username, 'Sin nombre')::text AS title,
      p.username::text AS subtitle,
      gm.joined_at   AS sort_at
    FROM public.group_memberships gm
    JOIN public.profiles p ON p.id = gm.user_id
    WHERE gm.group_id = p_group_id
      AND gm.status   = 'active'
      AND (
        p.display_name ILIKE v_pattern
        OR p.username   ILIKE v_pattern
      )
  ),
  resource_hits AS (
    SELECT
      'resource'::text AS entity_type,
      gr.id            AS entity_id,
      gr.group_id,
      gr.name::text    AS title,
      gr.resource_type::text AS subtitle,
      gr.created_at    AS sort_at
    FROM public.group_resources gr
    WHERE gr.group_id     = p_group_id
      AND gr.archived_at IS NULL
      AND (
        gr.name        ILIKE v_pattern
        OR gr.description ILIKE v_pattern
      )
  ),
  decision_hits AS (
    SELECT
      'decision'::text AS entity_type,
      gd.id            AS entity_id,
      gd.group_id,
      gd.title::text   AS title,
      gd.status::text  AS subtitle,
      gd.created_at    AS sort_at
    FROM public.group_decisions gd
    WHERE gd.group_id = p_group_id
      AND (
        gd.title ILIKE v_pattern
        OR gd.body  ILIKE v_pattern
      )
  ),
  rule_hits AS (
    SELECT
      'rule'::text  AS entity_type,
      gr2.id        AS entity_id,
      gr2.group_id,
      gr2.title::text AS title,
      gr2.rule_type::text AS subtitle,
      gr2.created_at  AS sort_at
    FROM public.group_rules gr2
    WHERE gr2.group_id = p_group_id
      AND gr2.status   = 'active'
      AND (
        gr2.title ILIKE v_pattern
        OR gr2.body  ILIKE v_pattern
      )
  ),
  all_hits AS (
    SELECT * FROM member_hits
    UNION ALL SELECT * FROM resource_hits
    UNION ALL SELECT * FROM decision_hits
    UNION ALL SELECT * FROM rule_hits
  ),
  ranked AS (
    SELECT entity_type, entity_id, group_id, title, subtitle, sort_at,
      -- Stable section order: members → resources → decisions → rules
      CASE entity_type
        WHEN 'member'   THEN 1
        WHEN 'resource' THEN 2
        WHEN 'decision' THEN 3
        WHEN 'rule'     THEN 4
        ELSE 99
      END AS section_order
    FROM all_hits
    ORDER BY section_order ASC, sort_at DESC NULLS LAST
    LIMIT v_limit
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'entity_type', entity_type,
      'entity_id',   entity_id,
      'group_id',    group_id,
      'title',       title,
      'subtitle',    subtitle
    )
    ORDER BY section_order ASC, sort_at DESC NULLS LAST
  ), '[]'::jsonb)
  INTO v_results
  FROM ranked;

  RETURN v_results;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.global_search(uuid, text, int) TO authenticated;
