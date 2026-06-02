-- D.22 upgrade: two real-user gaps found while testing the iPhone JJ sandbox.
--
-- 1. ILIKE is accent-sensitive — typing "tardia" missed "Multa por llegada
--    tardía". For a Spanish-speaking founder this is a daily-friction bug.
--    Install the `unaccent` extension and compare both sides unaccented.
--
-- 2. Search excluded non-active members. Looking for a banned member to
--    reinstate (the primary D.20.1 entry point!) returned nothing. Now
--    include all "lifecycle" states (active, paused, suspended, removed,
--    banned), label the subtitle with the status so the user sees why.
--    Still exclude 'invited'/'requested'/'left' for V1 to keep the list
--    focused; those can be reached via Personas + Inbox respectively.

CREATE EXTENSION IF NOT EXISTS unaccent;

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
  IF length(v_q) < 2 THEN
    RETURN '[]'::jsonb;
  END IF;

  -- Unaccent both sides so "tardia" matches "tardía" and "lopez" matches "López".
  v_pattern := '%' || public.unaccent(v_q) || '%';
  v_limit   := LEAST(GREATEST(COALESCE(p_limit, 25), 1), 50);

  WITH member_hits AS (
    SELECT
      'member'::text AS entity_type,
      gm.id          AS entity_id,
      gm.group_id,
      COALESCE(p.display_name, p.username, 'Sin nombre')::text AS title,
      -- For non-active members, prefix the username (or 'sin perfil') with status
      -- so the user understands why this person is in the list.
      CASE WHEN gm.status = 'active'
           THEN p.username::text
           ELSE upper(gm.status) || ' · ' || COALESCE(p.username, '')
      END AS subtitle,
      gm.joined_at AS sort_at
    FROM public.group_memberships gm
    JOIN public.profiles p ON p.id = gm.user_id
    WHERE gm.group_id = p_group_id
      AND gm.status IN ('active','paused','suspended','removed','banned')
      AND (
        public.unaccent(p.display_name) ILIKE v_pattern
        OR public.unaccent(p.username)   ILIKE v_pattern
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
        public.unaccent(gr.name)        ILIKE v_pattern
        OR public.unaccent(gr.description) ILIKE v_pattern
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
        public.unaccent(gd.title) ILIKE v_pattern
        OR public.unaccent(gd.body)  ILIKE v_pattern
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
    LEFT JOIN public.group_rule_versions grv ON grv.id = gr2.current_version_id
    WHERE gr2.group_id = p_group_id
      AND gr2.status   = 'active'
      AND (
        public.unaccent(gr2.title) ILIKE v_pattern
        OR public.unaccent(grv.body)  ILIKE v_pattern
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
