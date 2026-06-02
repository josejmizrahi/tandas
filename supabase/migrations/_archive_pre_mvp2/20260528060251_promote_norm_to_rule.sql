-- 20260528010000 — promote_norm_to_rule (V2-G6).
CREATE OR REPLACE FUNCTION public.promote_norm_to_rule(
  p_norm_id   uuid,
  p_rule_type text DEFAULT 'norm',
  p_severity  integer DEFAULT 1
)
RETURNS TABLE (
  rule_id    uuid,
  version_id uuid,
  norm_id    uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid        uuid := auth.uid();
  v_group_id   uuid;
  v_norm_title text;
  v_norm_body  text;
  v_norm_status text;
  v_type       text;
  v_severity   integer;
  v_rule_id    uuid;
  v_version_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT n.group_id, n.title, n.body, n.status
    INTO v_group_id, v_norm_title, v_norm_body, v_norm_status
    FROM public.group_cultural_norms n
   WHERE n.id = p_norm_id
   FOR UPDATE;

  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'cultural norm not found' USING errcode = 'P0002';
  END IF;

  IF v_norm_status = 'retired' THEN
    RAISE EXCEPTION 'cultural norm already retired' USING errcode = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = v_group_id
       AND gm.user_id  = v_uid
       AND gm.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', v_group_id
      USING errcode = '42501';
  END IF;

  v_type := COALESCE(NULLIF(btrim(coalesce(p_rule_type, '')), ''), 'norm');
  IF v_type NOT IN ('norm','requirement','prohibition','process','principle') THEN
    RAISE EXCEPTION 'invalid rule type' USING errcode = '22023';
  END IF;

  v_severity := COALESCE(p_severity, 1);
  IF v_severity < 0 OR v_severity > 5 THEN
    RAISE EXCEPTION 'invalid rule severity' USING errcode = '22023';
  END IF;

  v_norm_body := NULLIF(btrim(coalesce(v_norm_body, '')), '');
  IF v_norm_body IS NULL THEN
    v_norm_body := v_norm_title;
  END IF;

  PERFORM public.assert_permission(v_group_id, 'rules.create');

  INSERT INTO public.group_rules (
    group_id, title, rule_type, severity, status, created_by
  ) VALUES (
    v_group_id, v_norm_title, v_type, v_severity, 'active', v_uid
  )
  RETURNING id INTO v_rule_id;

  INSERT INTO public.group_rule_versions (
    rule_id, version, execution_mode, body, effective_from, published_by
  ) VALUES (
    v_rule_id, 1, 'text', v_norm_body, now(), v_uid
  )
  RETURNING id INTO v_version_id;

  UPDATE public.group_rules
     SET current_version_id = v_version_id,
         updated_at         = now()
   WHERE id = v_rule_id;

  UPDATE public.group_cultural_norms
     SET status     = 'retired',
         updated_at = now()
   WHERE id = p_norm_id;

  PERFORM public.record_system_event(
    v_group_id, 'rule.created', 'rule', v_rule_id,
    'Regla creada (promoción de norma)',
    jsonb_build_object(
      'rule_type',       v_type,
      'severity',        v_severity,
      'execution_mode',  'text',
      'source',          'cultural_norm_promotion',
      'source_norm_id',  p_norm_id
    )
  );

  PERFORM public.record_system_event(
    v_group_id, 'cultural_norm.promoted_to_rule',
    'cultural_norm', p_norm_id,
    'Norma cultural promovida a regla',
    jsonb_build_object(
      'rule_id',   v_rule_id,
      'rule_type', v_type,
      'severity',  v_severity
    )
  );

  rule_id    := v_rule_id;
  version_id := v_version_id;
  norm_id    := p_norm_id;
  RETURN NEXT;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.promote_norm_to_rule(uuid, text, integer) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.promote_norm_to_rule(uuid, text, integer) TO authenticated;

COMMENT ON FUNCTION public.promote_norm_to_rule(uuid, text, integer) IS
  'V2-G6 (mig 20260528010000): atomic norm→rule promotion. Reads norm, creates active group_rules + v1 group_rule_versions (execution_mode=text), retires the norm, emits rule.created + cultural_norm.promoted_to_rule. Permission: rules.create. Raises: norm not found, norm already retired, invalid rule type/severity. Body falls back to title when norm body is empty.';
