-- 20260527030000 — group_rules Foundation (Primitiva 4).
--
-- Primitiva 4 answers "¿qué está permitido, esperado o prohibido en
-- este grupo?". Foundation ships only the simple-text path:
--
--   - group_rules               = stable rule identity (existing).
--   - group_rule_versions       = append-only versions
--                                 (execution_mode='text' here).
--
-- Doctrinal constraint: never create a parallel "simple_rules" table.
-- Compose on top of the canonical primitives that already exist
-- (00001 schema). The engine path (execution_mode='engine') stays
-- intact for later slices; this RPC just creates text rules and the
-- read helper filters to text so the iOS surface doesn't accidentally
-- render engine bodies.
--
-- The schema-level CHECK constraints already enforce:
--   - rule_type ∈ ('norm','requirement','prohibition','process','principle')
--   - severity ∈ [0, 5]
--   - execution_mode ∈ ('text','engine')
--   - status ∈ ('draft','active','deprecated','archived')
-- We re-validate at the RPC boundary so callers get our canonical
-- error strings (rule title required / rule body required / invalid
-- rule type / invalid rule severity) instead of raw CHECK violations.
--
-- archive_rule(p_rule_id, p_reason) ALREADY EXISTS and does exactly
-- what we need (assert_permission('rules.archive') + close current
-- version + emit rule.archived event). Reused as-is.

-- ===========================================================================
-- 1. RPC: group_rules_active
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.group_rules_active(p_group_id uuid)
RETURNS TABLE (
  rule_id            uuid,
  current_version_id uuid,
  group_id           uuid,
  title              text,
  body               text,
  rule_type          text,
  severity           integer,
  execution_mode     text,
  status             text,
  created_by         uuid,
  effective_from     timestamptz,
  created_at         timestamptz,
  updated_at         timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
#variable_conflict use_column
DECLARE
  v_uid uuid := auth.uid();
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

  RETURN QUERY
  SELECT
    gr.id                AS rule_id,
    gr.current_version_id AS current_version_id,
    gr.group_id          AS group_id,
    gr.title             AS title,
    grv.body             AS body,
    gr.rule_type         AS rule_type,
    gr.severity          AS severity,
    grv.execution_mode   AS execution_mode,
    gr.status            AS status,
    gr.created_by        AS created_by,
    grv.effective_from   AS effective_from,
    gr.created_at        AS created_at,
    gr.updated_at        AS updated_at
  FROM public.group_rules gr
  JOIN public.group_rule_versions grv
    ON grv.id = gr.current_version_id
  WHERE gr.group_id = p_group_id
    AND gr.status   = 'active'
    AND grv.execution_mode = 'text'
    AND grv.effective_until IS NULL
  ORDER BY
    gr.severity DESC,
    grv.effective_from DESC NULLS LAST,
    gr.created_at DESC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_rules_active(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_rules_active(uuid) TO authenticated;

COMMENT ON FUNCTION public.group_rules_active(uuid) IS
  'Primitiva 4 Foundation (mig 20260527030000): active text rules for a group. Joins group_rules × group_rule_versions on current_version_id, filters execution_mode=text. Caller must be an active member.';

-- ===========================================================================
-- 2. RPC: create_text_rule
-- ===========================================================================
-- Wraps propose_rule + publish_rule_version into a single transaction
-- so Foundation founders only need one permission (`rules.create`)
-- and one call. The two existing RPCs still exist for fuller flows
-- that need to propose-then-debate-then-publish separately.

CREATE OR REPLACE FUNCTION public.create_text_rule(
  p_group_id  uuid,
  p_title     text,
  p_body      text,
  p_rule_type text DEFAULT 'norm',
  p_severity  integer DEFAULT 1
)
RETURNS TABLE (
  rule_id    uuid,
  version_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_title     text;
  v_body      text;
  v_type      text;
  v_severity  integer;
  v_rule_id   uuid;
  v_version_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  v_title := NULLIF(btrim(coalesce(p_title, '')), '');
  IF v_title IS NULL THEN
    RAISE EXCEPTION 'rule title required' USING errcode = '22023';
  END IF;

  v_body := NULLIF(btrim(coalesce(p_body, '')), '');
  IF v_body IS NULL THEN
    RAISE EXCEPTION 'rule body required' USING errcode = '22023';
  END IF;

  v_type := COALESCE(NULLIF(btrim(coalesce(p_rule_type, '')), ''), 'norm');
  IF v_type NOT IN ('norm','requirement','prohibition','process','principle') THEN
    RAISE EXCEPTION 'invalid rule type' USING errcode = '22023';
  END IF;

  v_severity := COALESCE(p_severity, 1);
  IF v_severity < 0 OR v_severity > 5 THEN
    RAISE EXCEPTION 'invalid rule severity' USING errcode = '22023';
  END IF;

  -- Permission gate. Foundation collapses propose+publish into one
  -- step so we only require the create permission (the alternative
  -- — requiring both rules.create and rules.publish — would force
  -- every Foundation user to hold an admin permission set).
  PERFORM public.assert_permission(p_group_id, 'rules.create');

  -- Insert the stable rule identity row in 'active' state (skipping
  -- the 'draft' intermediate that propose_rule uses, since we publish
  -- in the same transaction).
  INSERT INTO public.group_rules (
    group_id, title, rule_type, severity, status, created_by
  ) VALUES (
    p_group_id, v_title, v_type, v_severity, 'active', v_uid
  )
  RETURNING id INTO v_rule_id;

  -- Insert v1 of the version with execution_mode='text'.
  INSERT INTO public.group_rule_versions (
    rule_id, version, execution_mode, body, effective_from, published_by
  ) VALUES (
    v_rule_id, 1, 'text', v_body, now(), v_uid
  )
  RETURNING id INTO v_version_id;

  UPDATE public.group_rules
     SET current_version_id = v_version_id,
         updated_at         = now()
   WHERE id = v_rule_id;

  PERFORM public.record_system_event(
    p_group_id, 'rule.created', 'rule', v_rule_id,
    'Regla creada',
    jsonb_build_object(
      'rule_type',      v_type,
      'severity',       v_severity,
      'execution_mode', 'text'
    )
  );

  rule_id    := v_rule_id;
  version_id := v_version_id;
  RETURN NEXT;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_text_rule(uuid, text, text, text, integer) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.create_text_rule(uuid, text, text, text, integer) TO authenticated;

COMMENT ON FUNCTION public.create_text_rule(uuid, text, text, text, integer) IS
  'Primitiva 4 Foundation (mig 20260527030000): one-shot create + publish of a text-mode rule. Inserts group_rules (status=active) + group_rule_versions (version=1, execution_mode=text). Requires permission rules.create. Raises: rule title/body required, invalid rule type/severity. archive_rule(rule_id) handles the inverse.';
