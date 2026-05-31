-- V2-G2 sub-slice 8 — Expose default DecisionMethod (8) + LegitimacySource (10)
-- on `groups.decision_rules`. `default_style` becomes a legacy shadow column
-- derived from `default_method`; iOS writes via the new params.
--
-- Backfill existing rows (only 1 today: default_style=majority) and rewrite
-- both RPCs to accept/return the canonical pair.

-- 1. Backfill existing jsonb rows so reads after deploy are coherent.
UPDATE public.groups
   SET decision_rules = decision_rules
     || jsonb_build_object(
          'default_method',
          CASE COALESCE(decision_rules->>'default_style', 'majority')
            WHEN 'admin_only'    THEN 'admin'
            WHEN 'majority'      THEN 'majority'
            WHEN 'supermajority' THEN 'supermajority'
            WHEN 'unanimity'     THEN 'consensus'
            WHEN 'consensus'     THEN 'consent'
            ELSE 'majority'
          END,
          'default_legitimacy_source',
          CASE COALESCE(decision_rules->>'default_style', 'majority')
            WHEN 'admin_only'    THEN 'founder'
            WHEN 'majority'      THEN 'majority'
            WHEN 'supermajority' THEN 'supermajority'
            WHEN 'unanimity'     THEN 'unanimity'
            WHEN 'consensus'     THEN 'committee'
            ELSE 'majority'
          END
        )
 WHERE decision_rules IS NOT NULL
   AND decision_rules <> '{}'::jsonb
   AND NOT (decision_rules ? 'default_method');

-- 2. Rewrite `set_decision_rules` to accept method + legitimacy in addition
--    to the legacy style. iOS now passes method + legitimacy as truth; the
--    legacy style is derived from method on write so existing readers keep
--    working until the next cleanup.
CREATE OR REPLACE FUNCTION public.set_decision_rules(
  p_group_id                   uuid,
  p_default_style              text,
  p_quorum_min                 integer DEFAULT NULL,
  p_notes                      text    DEFAULT NULL,
  p_default_method             text    DEFAULT NULL,
  p_default_legitimacy_source  text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid        uuid := auth.uid();
  v_style      text;
  v_method     text;
  v_legitimacy text;
  v_notes      text;
  v_rules      jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  -- Method: prefer the new param; derive from style when absent so legacy
  -- callers (none today, but the param survives a release) still work.
  v_method := COALESCE(NULLIF(btrim(p_default_method), ''), NULL);
  IF v_method IS NULL THEN
    v_style := COALESCE(NULLIF(btrim(p_default_style), ''), '');
    v_method := CASE v_style
      WHEN 'admin_only'    THEN 'admin'
      WHEN 'majority'      THEN 'majority'
      WHEN 'supermajority' THEN 'supermajority'
      WHEN 'unanimity'     THEN 'consensus'
      WHEN 'consensus'     THEN 'consent'
      ELSE ''
    END;
  END IF;
  IF v_method NOT IN (
    'admin', 'majority', 'supermajority', 'consensus', 'consent',
    'ranked_choice', 'weighted', 'veto'
  ) THEN
    RAISE EXCEPTION 'invalid decision method: %', v_method USING errcode = '22023';
  END IF;

  -- Style: derive forward from method so the legacy column stays coherent.
  v_style := CASE v_method
    WHEN 'admin'         THEN 'admin_only'
    WHEN 'majority'      THEN 'majority'
    WHEN 'supermajority' THEN 'supermajority'
    WHEN 'consensus'     THEN 'unanimity'
    WHEN 'consent'       THEN 'consensus'
    WHEN 'ranked_choice' THEN 'majority'
    WHEN 'weighted'      THEN 'majority'
    WHEN 'veto'          THEN 'consensus'
  END;

  -- Legitimacy: explicit param wins; otherwise the canonical matrix.
  v_legitimacy := COALESCE(NULLIF(btrim(p_default_legitimacy_source), ''), NULL);
  IF v_legitimacy IS NULL THEN
    v_legitimacy := CASE v_method
      WHEN 'admin'         THEN 'founder'
      WHEN 'majority'      THEN 'majority'
      WHEN 'supermajority' THEN 'supermajority'
      WHEN 'consensus'     THEN 'unanimity'
      WHEN 'consent'       THEN 'committee'
      WHEN 'ranked_choice' THEN 'election'
      WHEN 'weighted'      THEN 'expert'
      WHEN 'veto'          THEN 'committee'
    END;
  END IF;
  IF v_legitimacy NOT IN (
    'founder', 'election', 'majority', 'supermajority', 'committee',
    'unanimity', 'expert', 'external_contract', 'tradition', 'emergency'
  ) THEN
    RAISE EXCEPTION 'invalid legitimacy source: %', v_legitimacy USING errcode = '22023';
  END IF;

  IF p_quorum_min IS NOT NULL AND p_quorum_min < 1 THEN
    RAISE EXCEPTION 'quorum_min must be >= 1' USING errcode = '22023';
  END IF;

  v_notes := NULLIF(btrim(COALESCE(p_notes, '')), '');

  PERFORM public.assert_permission(p_group_id, 'group.update');

  v_rules := jsonb_strip_nulls(jsonb_build_object(
    'default_style',             v_style,
    'default_method',            v_method,
    'default_legitimacy_source', v_legitimacy,
    'quorum_min',                p_quorum_min,
    'notes',                     v_notes
  ));

  UPDATE public.groups
     SET decision_rules = v_rules,
         updated_at     = now()
   WHERE id = p_group_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'group not found: %', p_group_id USING errcode = 'P0002';
  END IF;

  PERFORM public.record_system_event(
    p_group_id, 'decision_rules.set', 'group', p_group_id,
    'Reglas de decisión actualizadas',
    jsonb_build_object(
      'default_style',             v_style,
      'default_method',            v_method,
      'default_legitimacy_source', v_legitimacy,
      'quorum_min',                p_quorum_min,
      'has_notes',                 v_notes IS NOT NULL
    )
  );

  RETURN jsonb_build_object(
    'group_id',                  p_group_id,
    'default_style',             v_style,
    'default_method',            v_method,
    'default_legitimacy_source', v_legitimacy,
    'quorum_min',                p_quorum_min,
    'notes',                     v_notes,
    'is_default',                false
  );
END;
$function$;

-- 3. Rewrite `group_decision_rules` to return the canonical pair. When the
--    jsonb lacks the new keys (older rows, post-backfill should be empty),
--    derive from style. When style is also missing, fall back to majority.
CREATE OR REPLACE FUNCTION public.group_decision_rules(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid        uuid := auth.uid();
  v_raw        jsonb;
  v_style      text;
  v_method     text;
  v_legitimacy text;
  v_quorum     int;
  v_notes      text;
  v_empty      boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.group_memberships gm
     WHERE gm.group_id = p_group_id
       AND gm.user_id  = v_uid
       AND gm.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING errcode = '42501';
  END IF;

  SELECT COALESCE(g.decision_rules, '{}'::jsonb)
    INTO v_raw
    FROM public.groups g
   WHERE g.id = p_group_id;

  IF v_raw IS NULL THEN
    RAISE EXCEPTION 'group not found: %', p_group_id USING errcode = 'P0002';
  END IF;

  v_empty  := (v_raw = '{}'::jsonb);
  v_style  := COALESCE(NULLIF(v_raw->>'default_style', ''), 'majority');
  v_notes  := NULLIF(v_raw->>'notes', '');

  v_method := NULLIF(v_raw->>'default_method', '');
  IF v_method IS NULL THEN
    v_method := CASE v_style
      WHEN 'admin_only'    THEN 'admin'
      WHEN 'majority'      THEN 'majority'
      WHEN 'supermajority' THEN 'supermajority'
      WHEN 'unanimity'     THEN 'consensus'
      WHEN 'consensus'     THEN 'consent'
      ELSE 'majority'
    END;
  END IF;

  v_legitimacy := NULLIF(v_raw->>'default_legitimacy_source', '');
  IF v_legitimacy IS NULL THEN
    v_legitimacy := CASE v_method
      WHEN 'admin'         THEN 'founder'
      WHEN 'majority'      THEN 'majority'
      WHEN 'supermajority' THEN 'supermajority'
      WHEN 'consensus'     THEN 'unanimity'
      WHEN 'consent'       THEN 'committee'
      WHEN 'ranked_choice' THEN 'election'
      WHEN 'weighted'      THEN 'expert'
      WHEN 'veto'          THEN 'committee'
      ELSE 'majority'
    END;
  END IF;

  BEGIN
    v_quorum := NULLIF(v_raw->>'quorum_min', '')::int;
  EXCEPTION WHEN others THEN
    v_quorum := NULL;
  END;

  RETURN jsonb_build_object(
    'group_id',                  p_group_id,
    'default_style',             v_style,
    'default_method',            v_method,
    'default_legitimacy_source', v_legitimacy,
    'quorum_min',                v_quorum,
    'notes',                     v_notes,
    'is_default',                v_empty
  );
END;
$function$;
